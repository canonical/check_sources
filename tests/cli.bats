#!/usr/bin/env bats
# Exit codes and option handling: the documented contract is 0 for all
# reachable, 1 for a run in which sources failed, 2 for a run that could not
# start. A wrapper tells "network problem" from "invocation problem" by this.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "--help exits 0 and shows the option reference" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAILURE LABELS"* ]]
}

@test "--version exits 0 and reports the version" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"version"* ]]
}

@test "unknown option exits 2" {
  run "$SCRIPT" --no-such-option
  [ "$status" -eq 2 ]
}

@test "malformed proxy exits 2" {
  run "$SCRIPT" http://hostwithoutport
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid proxy URL"* ]]
}

@test "missing dependency exits 2" {
  # A PATH holding everything except curl: the dependency check must fire
  # and exit 2 before anything is probed. cp -s builds the whole symlink
  # farm in one process; a per-file ln loop cost a minute by itself.
  local nodir="${BATS_TEST_TMPDIR}/nocurl"
  mkdir -p "$nodir"
  cp -s /usr/bin/* /bin/* "$nodir/" 2>/dev/null || true
  rm -f "${nodir}/curl"
  run env PATH="$nodir" bash "$SCRIPT" --include x
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing required dependencies"* ]]
}

@test "a clean run exits 0" {
  run "$SCRIPT" --source "${STUB}/g200" --include '/g200'
  [ "$status" -eq 0 ]
}

@test "a run with a failed source exits 1" {
  run "$SCRIPT" --source "http://127.0.0.1:9/" --include '127\.0\.0\.1:9/'
  [ "$status" -eq 1 ]
}

@test "empty source selection exits 2" {
  run "$SCRIPT" --include 'matches-nothing-at-all'
  [ "$status" -eq 2 ]
}

@test "failure label lists stay in sync across help, README and the code" {
  run "${BATS_TEST_DIRNAME}/check_label_sync.sh"
  [ "$status" -eq 0 ]
}
