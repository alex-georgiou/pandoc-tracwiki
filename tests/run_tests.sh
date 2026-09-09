#!/usr/bin/env bash
#
# Golden-file test runner for the pandoc->Trac wiki writer.
#
# For every file in tests/cases/ (Markdown or pandoc-native JSON), this script
# runs the local pandoc binary with the tracwiki.lua writer and diffs the
# output against the committed <name>.expected golden file.
#
# Usage:
#   tests/run_tests.sh          run all tests
#   tests/run_tests.sh -u       regenerate golden files from current output
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
writer="$script_dir/../tracwiki.lua"
cases_dir="$script_dir/cases"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if ! command -v pandoc >/dev/null 2>&1; then
  echo "error: pandoc not found on PATH" >&2
  exit 1
fi

update=0
if [ "${1:-}" = "-u" ]; then
  update=1
fi

cases=( "$cases_dir"/* )
if [ "${#cases[@]}" -eq 0 ]; then
  echo "error: no test cases found in $cases_dir" >&2
  exit 1
fi

failures=0
for case_file in "${cases[@]}"; do
  [ -f "$case_file" ] || continue
  case "$case_file" in
    *.json) from=json ;;
    *.md)   from=markdown ;;
    *)      continue ;;
  esac

  base="${case_file%.*}"
  expected="$base.expected"
  pandoc --from="$from" --to="$writer" "$case_file" > "$tmpdir/out.txt"

  if [ "$update" = "1" ]; then
    cp "$tmpdir/out.txt" "$expected"
    echo "UPDATED $(basename "$base")"
    continue
  fi

  if diff -u "$expected" "$tmpdir/out.txt" > "$tmpdir/diff.txt"; then
    echo "PASS $(basename "$base")"
  else
    echo "FAIL $(basename "$base")"
    cat "$tmpdir/diff.txt"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi

if [ "$update" = "1" ]; then
  echo "golden files updated"
else
  echo "all tests passed"
fi