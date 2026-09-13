#!/usr/bin/env bash
#
# Golden-file test runner for the Trac wiki->pandoc reader.
#
# 1) For every file in tests/reader_cases/*.trac, this script reads it with the
#    tracwiki.lua reader, converts to pandoc Markdown, and diffs the output
#    against the committed <name>.expected golden file.
#
# 2) Round-trip idempotence: every writer golden in tests/cases/*.expected is
#    run through trac -> trac. The result must be a fixed point (re-processing
#    the output once more must not change it).
#
# Usage:
#   tests/run_reader_tests.sh     run all tests
#   tests/run_reader_tests.sh -u  regenerate golden files from current output
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reader="$script_dir/../tracwiki.lua"
cases_dir="$script_dir/reader_cases"
writer_cases_dir="$script_dir/cases"
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

failures=0

trac_cases=( "$cases_dir"/*.trac )
if [ "${#trac_cases[@]}" -eq 0 ]; then
  echo "error: no reader test cases found in $cases_dir" >&2
  exit 1
fi

for case_file in "${trac_cases[@]}"; do
  [ -f "$case_file" ] || continue
  base="${case_file%.trac}"
  expected="$base.expected"
  reader_flavor="$reader"
  if [[ "$base" == *camelcase* ]]; then
    reader_flavor="$reader+camelcase"
  fi
  pandoc --from="$reader_flavor" --to=markdown "$case_file" > "$tmpdir/out.txt"

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

# trac -> trac must be a fixed point: re-processing the output must not
# change it. Doing this directly on Pandoc's markdown round-trip of the
# reader cases would only exercise the writer; instead we feed the writer's
# own golden output back into the reader.
if [ "$update" = "0" ]; then
  for golden in "$writer_cases_dir"/*.expected; do
    [ -f "$golden" ] || continue
    out1=$(pandoc --from="$reader" --to="$reader" "$golden" 2>&1)
    out2=$(printf '%s' "$out1" | pandoc --from="$reader" --to="$reader" 2>&1)
    if [ "$out1" != "$out2" ]; then
      echo "FAIL idempotence ($(basename "$golden"))"
      diff <(printf '%s' "$out1") <(printf '%s' "$out2") || true
      failures=$((failures + 1))
    fi
  done
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi

if [ "$update" = "1" ]; then
  echo "reader golden files updated"
else
  echo "all reader tests passed"
fi