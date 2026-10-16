#!/usr/bin/env bats
# The apt profile: the oldest profile, the one the capability was built
# around, and the only one with a body assertion. A repository index either
# arrives as a PGP signed document or the source is not usable by apt, no
# matter what status code came with it.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "a PGP-opening index reports OK" {
  row="$(csv_row --release stub \
    --source "${STUB}/aptok/dists/{codename}/InRelease|apt" --include '/aptok/')"
  [[ "$row" == *",OK,200,"* ]]
  # The report names the resolved index path, codename substituted.
  [[ "$row" == *"/aptok/dists/stub/InRelease"* ]]
}

@test "a block page served with 200 reports NOBODY" {
  row="$(csv_row --release stub \
    --source "${STUB}/aptblock/dists/{codename}/InRelease|apt" --include '/aptblock/')"
  [[ "$row" == *",FAILED,NOBODY,"* ]]
}

@test "a missing index reports NOINDEX, not a network label" {
  row="$(csv_row --release stub \
    --source "${STUB}/apt404/dists/{codename}/InRelease|apt" --include '/apt404/')"
  [[ "$row" == *",FAILED,NOINDEX,"* ]]
}

@test "the request carries APT's fingerprint" {
  : >"$STUB_LOG"
  csv_row --release stub \
    --source "${STUB}/aptok/dists/{codename}/InRelease|apt" --include '/aptok/' >/dev/null
  grep -q ' Debian APT-HTTP/1.3' "$STUB_LOG"
  ! grep -q ' check_sources/' "$STUB_LOG"
}

@test "--user-agent overrides the apt fingerprint, as documented" {
  : >"$STUB_LOG"
  csv_row --release stub --user-agent 'MyOrg/1.0' \
    --source "${STUB}/aptok/dists/{codename}/InRelease|apt" --include '/aptok/' >/dev/null
  grep -q ' MyOrg/1.0' "$STUB_LOG"
  ! grep -q ' Debian APT-HTTP' "$STUB_LOG"
}
