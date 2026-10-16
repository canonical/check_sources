#!/usr/bin/env bats
# The generic probe against the stub: verdicts, labels, and the redirect
# destination reporting that the OCI probe later inherited.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "a 200 answer is reachable" {
  row="$(csv_row --source "${STUB}/g200" --include '/g200')"
  [[ "$row" == *",OK,200,"* ]]
}

@test "a 404 at the root is reachable for a generic source" {
  row="$(csv_row --source "${STUB}/g404" --include '/g404')"
  [[ "$row" == *",OK,404,"* ]]
}

@test "a redirect reports the destination and the count" {
  row="$(csv_row --source "${STUB}/gredir" --include '/gredir')"
  [[ "$row" == *",OK,200,"* ]]
  IFS=, read -r _ _ _ _ redirects final <<<"$row"
  [ "$redirects" -eq 1 ]
  [[ "$final" == *"/g200" ]]
}

@test "a dead port reports REFUSED" {
  row="$(csv_row --source "http://127.0.0.1:9/" --include '127\.0\.0\.1:9/')"
  [[ "$row" == *",FAILED,REFUSED,"* ]]
}

@test "selection filters work on the full URL" {
  run "$SCRIPT" --format csv \
    --source "${STUB}/g200" --source "${STUB}/g404" \
    --include "${STUB##http://}" --exclude '/g404'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/g200"* ]]
  [[ "$output" != *"/g404"* ]]
}
