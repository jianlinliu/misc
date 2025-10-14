#!/bin/bash

set -euo pipefail

# This scripts searches the directories passed as arguments for known failure causes from a set of symptom inputs.
# This is currently experimental and subject to change.

function xmlescape() {
  echo -n "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# Global variables for tracking test statistics
JUNIT_TESTS_FILE=""
JUNIT_TESTS_CASE_FILE=""
JUNIT_TESTS_TOTAL=0
JUNIT_FAILURES=0
JUNIT_SKIPPED=0
JUNIT_SUITE_NAME=""
JUNIT_START_TIME=0
JUNIT_USER_PROVIDED_FILE=0

function init_junit() {
  local suite_name="${1:-Test Suite}"
  local user_file="${2:-}"

  if [[ -n "${user_file}" ]]; then
    JUNIT_TESTS_FILE="${user_file}"
    JUNIT_USER_PROVIDED_FILE=1
  else
    JUNIT_TESTS_FILE=$(mktemp -t junit-XXXX)
    JUNIT_USER_PROVIDED_FILE=0
  fi

  JUNIT_TESTS_CASE_FILE=$(mktemp -t junit-case-XXXX) 
  JUNIT_TESTS_TOTAL=0
  JUNIT_FAILURES=0
  JUNIT_SKIPPED=0
  JUNIT_SUITE_NAME="${suite_name}"
  JUNIT_START_TIME=$(date +%s)
}

function generate_junit_xml() {
  if [[ -z "$JUNIT_TESTS_FILE" ]]; then
    echo "Error: JUnit not initialized. Call init_junit first." >&2
    return 1
  fi
  
  local end_time=$(date +%s)
  local duration=$((end_time - JUNIT_START_TIME))
 
  cat <<EOF > "${JUNIT_TESTS_FILE}"
<testsuite name="$(xmlescape "${JUNIT_SUITE_NAME}")" tests="${JUNIT_TESTS_TOTAL}" failures="${JUNIT_FAILURES}" skipped="${JUNIT_SKIPPED}" time="${duration}">
$(cat "${JUNIT_TESTS_CASE_FILE}")
</testsuite>
EOF
 cat "${JUNIT_TESTS_FILE}"
 
  if [[ ${JUNIT_USER_PROVIDED_FILE} -eq 0 ]]; then
    rm -f "${JUNIT_TESTS_FILE}"
  else
    echo "Writing JUnit report to ${JUNIT_TESTS_FILE}"
  fi
 
  # Cleanup
  rm -f "${JUNIT_TESTS_CASE_FILE}"
  JUNIT_TESTS_FILE=""
  JUNIT_TESTS_CASE_FILE=""
  JUNIT_TESTS_TOTAL=0
  JUNIT_FAILURES=0
  JUNIT_SKIPPED=0
  JUNIT_SUITE_NAME=""
  JUNIT_START_TIME=0
  JUNIT_USER_PROVIDED_FILE=0
}

function add_testcase() {
  local test_name="$1"
  local test_result="$2"  # "success", "failure", or "skipped"
  local message="$3"  # For "failure": failure message, for "skipped": skip reason
  
  if [[ -z "$JUNIT_TESTS_CASE_FILE" ]]; then
    echo "Error: JUnit not initialized. Call init_junit first." >&2
    return 1
  fi
  
  JUNIT_TESTS_TOTAL=$((JUNIT_TESTS_TOTAL + 1))
  
  case "${test_result}" in
    "success")
      echo "  <testcase name=\"$(xmlescape "${test_name}")\"></testcase>" >> "${JUNIT_TESTS_CASE_FILE}"
      ;;
    "failure")
      JUNIT_FAILURES=$((JUNIT_FAILURES + 1))
      echo "  <testcase name=\"$(xmlescape "${test_name}")\"><failure>$(xmlescape "${message}")\</failure></testcase>" >> "${JUNIT_TESTS_CASE_FILE}"
      ;;
    "skipped")
      JUNIT_SKIPPED=$((JUNIT_SKIPPED + 1))
      if [[ -n "${message}" ]]; then
        echo "  <testcase name=\"$(xmlescape "${test_name}")\"><skipped>$(xmlescape "${message}")\</skipped></testcase>" >> "${JUNIT_TESTS_CASE_FILE}"
      else
        echo "  <testcase name=\"$(xmlescape "${test_name}")\"><skipped/></testcase>" >> "${JUNIT_TESTS_CASE_FILE}"
      fi
      ;;
    *)
      echo "Error: Unknown test result '${test_result}' for test '${test_name}'. Must be 'success', 'failure', or 'skipped'." >&2
      return 1
      ;;
  esac
}

# Initialize JUnit system with suite name
init_junit "Symptom Detection" "/tmp/test.xml"

input=$(mktemp -t search-XXXX)

# Hardcoded list of detection for now. In the future this would be generated elsewhere.
#==Undiagnosed panic detected in pod=pods/*=Observed a panic
#==Undiagnosed panic detected in journal=nodes/*/journal*=Observed a panic
#=segfault=Bug 1812261: iptables is segfaulting=nodes/*/journal*=kernel: .+: segfault .+ libnftnl
#segfault==Node process segfaulted=nodes/*/journal*=kernel: .+: segfault
#==Infrastructure - quota exceeded or hit rate limit=pods/*=Throttling: Rate exceeded|The maximum number of [A-Za-z ]* has been reached|Quota .* exceeded|LimitExceeded.*exceed quota
cat <<EOF > ${input}
#==Infrastructure - quota exceeded or hit rate limit=test.log=Throttling: Rate exceeded|The maximum number of [A-Za-z ]* has been reached|Quota .* exceeded|LimitExceeded.*exceed quota
EOF

declare -A covered

while IFS= read -r line; do
    id=$(echo -n "${line}" | cut -f 1 -d =)
    covers=$(echo -n "${line}" | cut -f 2 -d =)
    if [[ -n "${id}" && -n "${covered[${id}]-}" ]]; then
      add_testcase "${prefix}" "skipped" "Already covered by ${covers}"
      continue
    fi

    prefix=$(echo -n "${line}" | cut -f 3 -d =)
    files=$(echo -n "${line}" | cut -f 4 -d =)
    search=$(echo -n "${line}" | cut -f 5- -d =)

    # Check if files exist
    if ! ls ${files} >/dev/null 2>&1; then
      add_testcase "${prefix}" "skipped" "Required files not found: ${files}"
      continue
    fi

    out=$(zgrep -E "${search}" ${files} 2>/dev/null || true) # ignore failures but log them to stderr
    if [[ -z "${out}" ]]; then
      add_testcase "${prefix}" "success"
      continue
    fi
    echo "Detected: ${prefix}" 1>&2

    if [[ -n "${covers}" ]]; then
      covered[${covers}]="1"
    fi
    add_testcase "${prefix}" "failure" "${out}"
done < "${input}"

generate_junit_xml
