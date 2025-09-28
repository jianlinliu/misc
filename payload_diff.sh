#!/bin/bash
trap 'rm -f "$OLD_TMP" "$NEW_TMP" "$TEMP_ENTRIES" "$TEMP_GIT_CHANGELOG" "$norm_oc" "$norm_git"' EXIT

if [ $# -lt 2 ]; then
    echo "Usage: $(basename $0) <from> <to> <base_url>"
    echo "It is better to export GITHUB_TOKEN as env var, or else probably hit github rate limit issue"
    exit 1
fi

from="$1"
to="$2"

to_tag=""
repo_with_registry="registry.ci.openshift.org/ocp/release"
if [[ "$to" == *:* ]]; then
    to_tag="${to#*:}"
    repo_with_registry="${to%:*}"
else
    to_tag="$to"
fi
if [[ "$from" == *:* ]]; then
    from_tag="${from#*:}"
else
    from_tag="$from"
fi
if [[ -n "$3" ]]; then
    repo_with_registry="$3"
fi

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function extract_sort() {
  jq '.references.spec.tags |
map({
  name: .name,
  commit_id: .annotations."io.openshift.build.commit.id",
  source_location: .annotations."io.openshift.build.source-location"
}) |
map(select(.source_location != null and .commit_id != null)) |
map(.source_location |= gsub("^\\s+|\\s+$"; "")) |
group_by(.source_location) |
map(
  .[0].source_location as $loc |
  . as $items |
  $items |
  group_by(.commit_id) |
  map(
    {
      commit_id: .[0].commit_id,
      names: (map(.name) | join(", "))
    }
  ) |
  { ($loc): . }
) |
add
' "$1" > "$2"
}

get_repo_path() {
  local url="$1"
  echo "$url" | sed -E 's|https://github.com/([^/]+/[^/]+).*|\1|' | xargs
}

fetch_pr_commits_and_cache() {
  local t_repo_path="$1"
  local pr_num="$2"
  local calling_commit="${3:-unknown}"
  local title="${4:-}"

  local pr_key="${t_repo_path}#$pr_num"

  if [[ -v SEEN_PR_FETCHED["$pr_key"] ]]; then
    return 0
  fi

  local pr_api="https://api.github.com/repos/$t_repo_path/pulls/$pr_num"
  local headers=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  headers+=(-H "Accept: application/vnd.github.v3+json")

  local http_status
  http_status=$(api_call "GET" "$pr_api" "${headers[@]}")
  
  if [[ -z "$http_status" ]] || [[ "$http_status" -ne 200 ]]; then
    echo "⚠️  Failed to fetch PR #$pr_num (from merge message), will try /commits/{sha}/pulls fallback" >&2
    echo "    🧩 Commit: $calling_commit | HTTP $http_status | Repo: $t_repo_path | URL: $pr_api" >&2
    PR_FETCH_FAILED["$pr_num"]="$t_repo_path"
    SEEN_PR_FETCHED["$pr_key"]=1
    return 1
  fi

  if [[ -n "${title}" ]]; then
    PR_TITLE_CACHE["$pr_num"]="$title"
  else
    title=$(cat "$GITHUB_RESPONSE_BODY" | jq -r '.title // "PR #'$pr_num'"')
    PR_TITLE_CACHE["$pr_num"]="$title"
  fi

  local merge_sha=$(cat "$GITHUB_RESPONSE_BODY" | jq -r '.merge_commit_sha // empty')
  if [[ -n "$merge_sha" ]]; then
    COMMIT_TO_PR["$merge_sha"]="$pr_num"
    echo "🔖 Marked merge commit $merge_sha → PR #$pr_num" >&2
  fi

  local commits_api="https://api.github.com/repos/$t_repo_path/pulls/$pr_num/commits"
  local commit_response_status
  commit_response_status=$(api_call "GET" "$commits_api" "${headers[@]}" 2>/dev/null)

  if [[ -n "$commit_response_status" ]] && [[ "$commit_response_status" -eq 200 ]]; then
    local first_sha=$(cat "$GITHUB_RESPONSE_BODY" | jq -r '.[0].sha // empty')
    if [[ -n "$first_sha" ]]; then
      local first_subject=$(cat "$GITHUB_RESPONSE_BODY" | jq -r '.[0].commit.message' | head -n1)
      PR_FIRST_COMMIT_SUBJECT["$pr_num"]="$first_subject"
    fi

    while read sha; do
      sha=$(echo "$sha" | xargs)
      COMMIT_TO_PR["$sha"]="$pr_num"
      echo "🔖 Marked commit $sha → PR #$pr_num" >&2
    done < <(cat "$GITHUB_RESPONSE_BODY" | jq -r '.[].sha')
  else
    echo "⚠️  Warning: Failed to fetch or parse commits for PR #$pr_num (triggered by $calling_commit)" >&2
  fi

  SEEN_PR_FETCHED["$pr_key"]=1
  return 0
}

escape_brackets() {
  local text="$1"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  echo "$text"
}

output_pr_line() {
  local pr_num="$1"
  local dummy_title="$2"
  local t_repo_path="$3"

  if [[ "$pr_num" == "commit" ]]; then
    if [[ -v SEEN_COMMITS["$dummy_title"] ]]; then
      return
    fi
    SEEN_COMMITS["$dummy_title"]=1
    echo "    - (commit) $dummy_title" >> "$git_release_diff_output"
    return
  fi

  if [[ -v SEEN_PR_OUTPUT["$pr_num"] ]]; then
    return
  fi
  SEEN_PR_OUTPUT["$pr_num"]=1

  local source_title="${PR_TITLE_CACHE[$pr_num]:-}"

  if [[ -z "$source_title" ]]; then
    local first_subject="${PR_FIRST_COMMIT_SUBJECT[$pr_num]:-}"
    if [[ -n "$first_subject" ]]; then
      source_title="$first_subject"
      echo "🔍 PR #$pr_num: using first commit subject for Jira detection" >&2
    fi
  fi

  
  local temp=""
  local jira_ids=()
  local links=()
  local jira_links=""
  local prefix=""
  local suffix=""
  local enhanced_title="$source_title"

  if [[ "$source_title" =~ ^[[:space:]]*([A-Z]+-[0-9]+[[:space:],]*)+[-:][[:space:]]* ]]; then
    prefix="${source_title%%:*}"
    prefix=$(echo "$prefix" | xargs)

    temp="$prefix"
    while [[ "$temp" =~ ([A-Z]+-[0-9]+) ]]; do
      local jira_id="${BASH_REMATCH[1]}"
      jira_ids+=("$jira_id")
      temp="${temp#*$jira_id}"
      [[ -z "$temp" ]] && break
    done

    if (( ${#jira_ids[@]} > 1 )); then
      IFS=$'\n' read -d '' -r -a jira_ids < <(
        printf '%s\n' "${jira_ids[@]}" | sort -V
      )
    fi

    for jira_id in "${jira_ids[@]}"; do
      links+=("[$jira_id](https://issues.redhat.com/browse/$jira_id)")
    done

    if (( ${#links[@]} > 0 )); then
      jira_links="${links[0]}"
      for ((i=1; i<${#links[@]}; i++)); do
        jira_links+=", ${links[i]}"
      done
    fi
  fi

  if [[ -n "$jira_links" ]]; then
    if [[ "$source_title" == *:* ]]; then
      prefix="${source_title%%:*}"
      suffix="${source_title#*:}"
      trimmed_suffix="${suffix#"${suffix%%[![:space:]]*}"}"
      enhanced_title="$jira_links: $trimmed_suffix"
    fi
  fi

  if [[ -z "$enhanced_title" ]]; then
    enhanced_title="PR #$pr_num"
  fi

  local output="* ${enhanced_title} [#${pr_num}](https://github.com/$t_repo_path/pull/${pr_num})"

  local safe_output
  safe_output=$(escape_brackets "$output")

  #local jira_id=""
  #local link=""
  #local prefix=""
  #if [[ "$source_title" =~ ^[[:space:]]*([A-Z]+-[0-9]+[[:space:],]*)+[-:][[:space:]]* ]]; then
  #  prefix="${BASH_REMATCH[0]}"
  #fi
  #
  # 用正则循环提取每一个 Jira ID
  #while [[ "$prefix" =~ ([A-Z]+-[0-9]+) ]]; do
  #  jira_id="${BASH_REMATCH[1]}"
  #  link="[$jira_id](https://issues.redhat.com/browse/$jira_id)"
  #  source_title="${source_title/$jira_id/$link}"
  #  prefix="${prefix/$jira_id/}"
  #done
  #
  #local output="* $source_title [#${pr_num}](https://github.com/$t_repo_path/pull/${pr_num})"

  echo "$safe_output" >> "$git_release_diff_output"
}

api_call() {
  local method="$1"
  local url="$2"
  local headers=("${@:3}")

  echo "🌐 API: $method $url" >&2

  > "$GITHUB_RESPONSE_BODY"
  curl -s -L -f -w "%{http_code}" "${headers[@]}" "$url" -o "$GITHUB_RESPONSE_BODY"
}

####################################
############### Main ###############
####################################
changelog_dir="/tmp/git-${to_tag}"
oc_release_diff_output="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_oc_original"
oc_release_diff_output_1="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_oc"

#rm -rf "${changelog_dir}"
mkdir -p "${changelog_dir}"

pushd "${changelog_dir}"
run_command "oc adm release info --changelog=. ${repo_with_registry}:${from_tag} ${repo_with_registry}:${to_tag} > '${oc_release_diff_output}'"
sed -n '/^###.*\[.*\].*github.com/,$p' "$oc_release_diff_output" > "$oc_release_diff_output_1"
sed -i -e "/And [0-9]* elided commits/d" -e "/\[Full changelog\]/d" "$oc_release_diff_output_1"

run_command "oc adm release info ${repo_with_registry}:${from_tag} -o json > ${from_tag}.json"
run_command "oc adm release info ${repo_with_registry}:${to_tag} -o json > ${to_tag}.json"
extract_sort ${from_tag}.json ${from_tag}-commit.json
extract_sort ${to_tag}.json ${to_tag}-commit.json

git_repo_base="github.com/openshift"
git_release_diff_output="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_git"
>"${git_release_diff_output}"
OLD_TMP=$(mktemp)
NEW_TMP=$(mktemp)
GITHUB_RESPONSE_BODY=$(mktemp)
TEMP_ENTRIES=$(mktemp)
TEMP_GIT_CHANGELOG=$(mktemp)

jq -r 'to_entries[] | .key as $url | .value[] | "\($url) \(.commit_id) \(.names)"' "${from_tag}-commit.json" > "$OLD_TMP"
jq -r 'to_entries[] | .key as $url | .value[] | "\($url) \(.commit_id) \(.names)"' "${to_tag}-commit.json" > "$NEW_TMP"

declare -A OLD_COMMIT_NAMES NEW_COMMIT_NAMES
declare -A OLD_NAMES NEW_NAMES
declare -A URL_MAP_OLD URL_MAP_NEW
declare -A SEEN_PR_FETCHED
declare -A SEEN_PR_OUTPUT
declare -A SEEN_COMMITS
declare -A COMMIT_TO_PR
declare -A PR_TITLE_CACHE
declare -A PR_FIRST_COMMIT_SUBJECT
declare -A PR_FETCH_FAILED

safe_key() {
  echo "$1" | sed 's|[^a-zA-Z0-9._-]|_|g' | xargs
}
while read -r url commit names; do
  [[ -z "$url" || -z "$commit" ]] && continue
  clean_url=$(echo "$url" | xargs)
  key=$(safe_key "$clean_url")
  OLD_COMMIT_NAMES["$key"]="$commit"
  OLD_NAMES["$key"]="$names"
  URL_MAP_OLD["$key"]="$clean_url"
done < "$OLD_TMP"

while read -r url commit names; do
  [[ -z "$url" || -z "$commit" ]] && continue
  clean_url=$(echo "$url" | xargs)
  key=$(safe_key "$clean_url")
  NEW_COMMIT_NAMES["$key"]="$commit"
  NEW_NAMES["$key"]="$names"
  URL_MAP_NEW["$key"]="$clean_url"
done < "$NEW_TMP"

for key in "${!NEW_COMMIT_NAMES[@]}"; do
  new_commit="${NEW_COMMIT_NAMES[$key]}"
  new_names="${NEW_NAMES[$key]}"
  old_commit="${OLD_COMMIT_NAMES[$key]}"
  old_names="${OLD_NAMES[$key]:-}"
  url="${URL_MAP_NEW[$key]}"
  clean_names=$(echo "$new_names" | xargs)
  printf '%s\t%s\t%s\t%s\n' "$clean_names" "$url" "$old_commit" "$new_commit"
done | sort -k1,1 > "$TEMP_ENTRIES"

while IFS=$'\t' read -r names url old_commit new_commit; do
  if [[ -z "$old_commit" ]]; then
    echo "🆕 New repository: $url"
    echo "🆕 New repository: $url (commit: $new_commit)"
    continue
  fi

  if [[ "$old_commit" == "$new_commit" ]]; then
    echo "✅ No change: $url"
    continue
  fi

  repo_path=""
  repo_path=$(get_repo_path "$url")
  if [[ -z "$repo_path" ]]; then
    echo "❌ Invalid URL: $url" >&2
    continue
  fi

  repo_name=$(basename "$url" .git)
  repo_dir="$git_repo_base/$repo_name"

  echo "🔍 Processing $url"
  echo "   Images: $names"
  echo "   Commit: $old_commit..$new_commit"

  if [[ ! -d "$repo_dir" ]]; then
    echo "⚠️  $repo_dir does not exist"
    continue
  fi

  (
    cd "$repo_dir" || exit 1

    if ! git rev-parse "$old_commit" >/dev/null 2>&1; then
      echo "⚠️  Old commit $old_commit not found in $url"
      echo "⚠️  Old commit not found: $url ($old_commit)"
      exit 1
    fi

    if ! git rev-parse "$new_commit" >/dev/null 2>&1; then
      echo "⚠️  New commit $new_commit not found in $url"
      echo "⚠️  New commit not found: $url ($new_commit)"
      exit 1
    fi

    echo "### [$names]($url/tree/$new_commit)" | tee -a "$git_release_diff_output"
    echo "" >> "$git_release_diff_output"
    echo "Commit range: $old_commit..$new_commit"
    echo "----------------------------------------"
    #git log --date=short --format='%h %ad %an %s' --first-parent "$old_commit".."$new_commit" --oneline --graph --date=short >> "$git_release_diff_output"
    git log "$old_commit".."$new_commit" --format='%H|%s' > "$TEMP_GIT_CHANGELOG" 2>/dev/null || true

    # Stage-1: scan all the commits, mapping them to PR
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r commit subject <<< "$line"

      commit=${commit%%[^a-fA-F0-9]*}
      if [[ ! "$commit" =~ ^[a-f0-9]{7,40}$ ]]; then
        continue
      fi

      if [[ -v COMMIT_TO_PR["$commit"] ]]; then
        echo "⏭️  Skip commit $commit (belongs to PR #${COMMIT_TO_PR[$commit]})" >&2
        continue
      fi

      pr_num=""
      from_merge=false
      # Method-1: matching "Merge pull request #123", "Merge #123" or "(#123)" from the commit message
      if [[ "$subject" =~ ^Merge(\ pull\ request)?\ \#([0-9]+) ]]; then
        pr_num="${BASH_REMATCH[2]}"
        from_merge=true
        pr_title=""
      elif [[ "$subject" =~ \([^\)]*\#([0-9]+)[^\)]*\)$ ]]; then
        pr_num="${BASH_REMATCH[1]}"
        from_merge=true
        pr_title="$subject"
      fi

      if [[ "$from_merge" == "true" ]] && ! fetch_pr_commits_and_cache "$repo_path" "$pr_num" "$commit" "$pr_title"; then
          echo "🔁 PR #$pr_num not found in current repo, will try /commits/{sha}/pulls fallback for $commit" >&2
      fi

      # Method-2: query github api, to get PR number from the commit id
      # if method-1 get passed, skip it, if failed, enter this block
      if [[ -z "$pr_num" ]] || ( [[ "$from_merge" == "true" ]] && [[ -v PR_FETCH_FAILED["$pr_num"] ]] ); then
        commit_api="https://api.github.com/repos/$repo_path/commits/$commit/pulls"
        headers=()
        [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
        headers+=(-H "Accept: application/vnd.github.groot-preview+json")

        response_status=""
        response_status=$(api_call "GET" "$commit_api" "${headers[@]}")

        if [[ "$response_status" -eq 200 ]] && cat "$GITHUB_RESPONSE_BODY" | jq -e 'length > 0' >/dev/null 2>&1; then
          pr_num=$(cat "$GITHUB_RESPONSE_BODY" | jq -r '.[0].number')
          if [[ -n "$pr_num" ]]; then
            COMMIT_TO_PR["$commit"]="$pr_num"
            echo "🔖 Marked commit $commit → PR #$pr_num" >&2
            fetch_pr_commits_and_cache "$repo_path" "$pr_num" "$commit"
          else
            echo "WWWWWWarning: Fail to get pull request number"
          fi
        else
          echo "EEEEEorr:  Failed to request $commit_api" >&2
        fi
      fi
    done < "$TEMP_GIT_CHANGELOG"

    # Stage-2: ouput every gotten PR
    for pr_num in "${!PR_TITLE_CACHE[@]}"; do
      if [[ -v SEEN_PR_OUTPUT["printed_$pr_num"] ]]; then
        continue
      fi
      SEEN_PRS["printed_$pr_num"]=1
      output_pr_line "$pr_num" "${PR_TITLE_CACHE[$pr_num]}" "$repo_path"
    done

    # Stage-3: output all the left commits not covered by PR
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r commit subject <<< "$line"

      commit=${commit%%[^a-fA-F0-9]*}
      if [[ ! "$commit" =~ ^[a-f0-9]{7,40}$ ]]; then
        continue
      fi

      if [[ -v COMMIT_TO_PR["$commit"] ]]; then
        echo "⏭️  Skip commit $commit (belongs to PR #${COMMIT_TO_PR[$commit]})" >&2
        continue
      fi

      short_id="${commit:0:7}"
      short_msg=$(echo "$subject" | cut -c1-80)
      output_pr_line "commit" "$short_id: $short_msg" "$repo_path"

    done < "$TEMP_GIT_CHANGELOG"
  )
  echo "" >> "$git_release_diff_output"
  echo "" >> "$git_release_diff_output"
done < "$TEMP_ENTRIES"
popd

normalize_changelog() {
  local file="$1"

  awk '
    BEGIN { pr_lines = "" }
    /^### / {
      # 先输出上一个仓库的排序后 PR 行
      if (pr_lines != "") {
        n = split(pr_lines, arr, "\n")
        asort(arr)
        for (i = 1; i <= n; i++) {
          print arr[i]
        }
        pr_lines = ""
      }
      gsub(/tree\/[a-f0-9]+  /, "tree/&", $0)
      gsub(/pull\/[0-9]+  /, "pull/&", $0)
      gsub(/browse\/[A-Z]+-[0-9]+  /, "browse/&", $0)
      gsub(/  +/, " ", $0)  # 多个空格变一个
      print $0
      next
    }
    /^\* / {
      line = $0
      gsub(/  +/, " ", line)
      gsub(/ $/, "", line)
      pr_lines = pr_lines line "\n"
      next
    }
    /^$/ { next }
    {
      print $0
    }
    END {
      if (pr_lines != "") {
        n = split(pr_lines, arr, "\n")
        asort(arr)
        for (i = 1; i <= n; i++) {
          if (arr[i] != "") {
            print arr[i]
          }
        }
      }
    }
  ' "$file"
}

echo "🔄 Normalizing and comparing changelogs..."

norm_oc=$(mktemp)
norm_git=$(mktemp)

normalize_changelog "$oc_release_diff_output_1" > "$norm_oc"
normalize_changelog "$git_release_diff_output" > "$norm_git"

echo "Data is saved in ${changelog_dir}"
echo "payload diff output from oc is saved in $oc_release_diff_output_1"
echo "payload diff output from git is saved in $git_release_diff_output"
run_command "sdiff '$norm_oc' '$norm_git' -w 190"
