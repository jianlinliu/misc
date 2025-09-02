#!/bin/bash
trap 'rm -f "$OLD_TMP" "$NEW_TMP" "$TEMP_ENTRIES"' EXIT

if [ $# -lt 2 ]; then
    echo "Usage: $(basename $0) <from> <to> <base_url>"
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


changelog_dir="/tmp/git-${to_tag}"
oc_release_diff_output="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_oc_original"
oc_release_diff_output_1="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_oc"

#rm -rf "${changelog_dir}"
mkdir -p "${changelog_dir}"

pushd "${changelog_dir}"
tmp_file=
run_command "oc adm release info --changelog=. ${repo_with_registry}:${from_tag} ${repo_with_registry}:${to_tag} | tee '${oc_release_diff_output}'"
sed -n '/^###.*\[.*\].*github.com/,$p' "$oc_release_diff_output" > "$oc_release_diff_output_1"

run_command "oc adm release info ${repo_with_registry}:${from_tag} -o json > ${from_tag}.json"
run_command "oc adm release info ${repo_with_registry}:${to_tag} -o json > ${to_tag}.json"

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
      names: (map(.name) | join("#"))
    }
  ) |
  { ($loc): . }
) |
add
' "$1" > "$2"
}

extract_sort ${from_tag}.json ${from_tag}-commit.json
extract_sort ${to_tag}.json ${to_tag}-commit.json
git_repo_base="github.com/openshift"
git_release_diff_output="${changelog_dir}/payload_${to_tag}_diff_${from_tag}_git"
>"${git_release_diff_output}"
OLD_TMP=$(mktemp)
NEW_TMP=$(mktemp)

jq -r 'to_entries[] | .key as $url | .value[] | "\($url) \(.commit_id) \(.names)"' "${from_tag}-commit.json" > "$OLD_TMP"
jq -r 'to_entries[] | .key as $url | .value[] | "\($url) \(.commit_id) \(.names)"' "${to_tag}-commit.json" > "$NEW_TMP"

declare -A OLD_COMMIT_NAMES NEW_COMMIT_NAMES
declare -A OLD_NAMES NEW_NAMES
declare -A URL_MAP_OLD URL_MAP_NEW
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

TEMP_ENTRIES=$(mktemp)
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

  repo_name=$(basename "$url" .git)
  repo_dir="$git_repo_base/$repo_name"

  echo "🔍 Processing $url"
  echo "   Images: $names"
  echo "   Commit: $old_commit → $new_commit"

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
    echo -e "\n" >> "$git_release_diff_output"
    echo "Commit range: $old_commit → $new_commit"
    echo "----------------------------------------"
    git log --date=short --format='%h %ad %an %s' --first-parent "$old_commit".."$new_commit" --oneline --graph --date=short >> "$git_release_diff_output"
    echo -e "\n\n" >> "$git_release_diff_output"
  )
done < "$TEMP_ENTRIES"
popd


echo "Data is saved in ${changelog_dir}"
echo "payload diff output from oc is saved in $oc_release_diff_output_1"
echo "payload diff output from git is saved in $git_release_diff_output"
run_command "sdiff '$oc_release_diff_output_1' '$git_release_diff_output' -w 190"
