#!/usr/bin/env bats
# The machine-readable formats carry the same documented fields for the same
# probe, and the records agree with each other.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "json record carries the documented fields" {
  run "$SCRIPT" --format json --source "${STUB}/gredir" --include '/gredir'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read().strip().splitlines()[-1])
assert set(d) == {"url", "status", "code", "response_time", "redirects", "final_url"}, d
assert d["status"] == "OK" and d["code"] == "200" and d["redirects"] == "1", d
'
}

@test "csv record carries the header and the same verdict" {
  run "$SCRIPT" --format csv --source "${STUB}/gredir" --include '/gredir'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "URL,Status,Code,ResponseTime,Redirects,FinalURL" ]]
  [[ "${lines[1]}" == *'"OK","200"'* ]]
}

@test "yaml record is one flow mapping with the same verdict" {
  run "$SCRIPT" --format yaml --source "${STUB}/gredir" --include '/gredir'
  [ "$status" -eq 0 ]
  [[ "$output" == *'status: "OK"'* ]]
  [[ "$output" == *'redirects: "1"'* ]]
}

@test "an oci record claims the real redirect count, not zero" {
  run "$SCRIPT" --format json --source "${STUB}/redirdead/x/y:1|oci" --include '/redirdead/'
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read().strip().splitlines()[-1])
assert d["redirects"] == "1", d
assert "127.0.0.1:9" in d["final_url"], d
'
}
