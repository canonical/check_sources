#!/usr/bin/env bats
# Parallel mode: same verdicts as sequential, no source vanishes, and the
# fan-out stays under the concurrency bound.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "parallel reports the same count and verdicts as sequential" {
  local args=(--format csv
    --source "${STUB}/g200" --source "${STUB}/g404"
    --source "http://127.0.0.1:9/" --source "${STUB}/ok/x/y:1|oci"
    --include "${STUB##http://}|127\\.0\\.0\\.1:9/")
  seq_rows="$("$SCRIPT" "${args[@]}" 2>/dev/null | tail -n +2 | cut -d, -f1-3 | sort)"
  par_rows="$("$SCRIPT" --parallel "${args[@]}" 2>/dev/null | tail -n +2 | cut -d, -f1-3 | sort)"
  [ -n "$seq_rows" ]
  [ "$seq_rows" = "$par_rows" ]
  [ "$(echo "$seq_rows" | wc -l)" -eq 4 ]
}

@test "a failing source does not vanish from a parallel run" {
  run "$SCRIPT" --parallel --format csv \
    --source "http://127.0.0.1:9/" --source "${STUB}/g200" \
    --include "${STUB##http://}|127\\.0\\.0\\.1:9/"
  [ "$status" -eq 1 ]
  [[ "$output" == *'127.0.0.1:9/","FAILED"'* ]]
  [[ "$output" == *'/g200","OK"'* ]]
}

@test "a large list never exceeds the concurrency bound" {
  local list="${BATS_TEST_TMPDIR}/many.txt"
  local i
  for i in $(seq 1 150); do
    echo "${STUB}/gslow/${i}" >>"$list"
  done
  run "$SCRIPT" --parallel --format csv --sources-file "$list" --include '/gslow/'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '"OK"')" -eq 150 ]
  peak="$(curl -s "${STUB}/peak")"
  [ "$peak" -le 64 ]
  # And the bound is actually exercised, not trivially satisfied.
  [ "$peak" -ge 32 ]
}
