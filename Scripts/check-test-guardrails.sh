#!/usr/bin/env bash

# Lexical contract: banned tokens are rejected wherever they appear, including comments and string literals.

set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Checking test guardrails..."

tests_path="Tests"

if [[ ! -d "$tests_path" ]]; then
  echo "ERROR: Test source directory is missing: $tests_path" >&2
  exit 2
fi

if ! swift_file_count="$(
  /usr/bin/find "$tests_path" -type f -name '*.swift' -print \
    | /usr/bin/awk 'END { print NR }'
)"; then
  echo "ERROR: Could not count Swift test sources in $tests_path." >&2
  exit 2
fi

if [[ "$swift_file_count" -eq 0 ]]; then
  echo "ERROR: No Swift test sources found in $tests_path." >&2
  exit 2
fi

guardrail_status=0

scan_rule() {
  local pattern="$1"
  local violation_message="$2"
  local scan_status

  if /usr/bin/grep -REn --include='*.swift' -- "$pattern" "$tests_path"; then
    echo "ERROR: $violation_message" >&2
    if [[ "$guardrail_status" -lt 1 ]]; then
      guardrail_status=1
    fi
  else
    scan_status=$?
    if [[ "$scan_status" -ne 1 ]]; then
      echo "ERROR: Test-source scan failed (status $scan_status)." >&2
      guardrail_status=2
    fi
  fi

  return 0
}

unicode_identifier_bytes="$(printf '\200-\377')"
identifier_characters="[:alnum:]_${unicode_identifier_bytes}"
lowercase_identifier_characters="[:lower:]${unicode_identifier_bytes}"
name_prefix="(^|[^${identifier_characters}])"
name_suffix="($|[^${identifier_characters}])"
nonmember_prefix="(^[[:space:]]*|[^.[:space:]${identifier_characters}][[:space:]]*|[${identifier_characters}][[:space:]]+)"
wait_pattern="${name_prefix}"'Task[[:space:]]*[.][[:space:]]*sleep'"${name_suffix}"
wait_pattern+="|${name_prefix}"'Thread[[:space:]]*[.][[:space:]]*sleep'"${name_suffix}"
wait_pattern+="|${nonmember_prefix}"'(sleep|usleep|nanosleep)[[:space:]]*[(]'
wait_pattern+="|${nonmember_prefix}"'(Foundation|Darwin)[[:space:]]*[.][[:space:]]*(sleep|usleep|nanosleep)[[:space:]]*[(]'
wait_pattern+='|[.][[:space:]]*asyncAfter'"${name_suffix}"
wait_pattern+="|${name_prefix}"'RunLoop[[:space:]]*[.][[:space:]]*current[[:space:]]*[.][[:space:]]*run'"${name_suffix}"
wait_pattern+="|${name_prefix}XCTWaiter${name_suffix}"
wait_pattern+="|${name_prefix}"'expectation[[:space:]]*[(]'
import_pattern="(^|[^${identifier_characters}])import[[:space:]]+([[:alnum:]_]+[[:space:]]+)?XCTest($|[^${identifier_characters}])"
test_name_pattern="(^|[^${identifier_characters}])func[[:space:]]+\`?test($|[^${lowercase_identifier_characters}])"

scan_rule "$wait_pattern" "Found time-based waits in test sources."
scan_rule "$import_pattern" "Found XCTest import in test sources."
scan_rule "$test_name_pattern" "Found XCTest-style test function name in test sources."

if [[ "$guardrail_status" -eq 0 ]]; then
  echo "Test guardrails passed."
fi

exit "$guardrail_status"
