#!/usr/bin/env bats
# The OCI probe against the consolidated stub. Every test here is a behavior
# that was once proven by hand against a live registry and then re-verified
# against this stub, including the one regression the suite exists to keep
# dead: a -w format change that broke the authenticated manifest parse and
# reported MANIFEST200 on every registry that uses the token flow.

load helpers

setup_file() {
  start_stub
  start_proxy
}

teardown_file() {
  stop_stub
  stop_proxy
}

@test "token flow succeeds end to end (MANIFEST200 stays dead)" {
  row="$(csv_row --source "${STUB}/ok/x/y:1|oci" --include '/ok/')"
  [[ "$row" == *",OK,206,"* ]]
  [[ "$row" != *"MANIFEST200"* ]]
}

@test "multi-arch index takes the architecture hop and still pulls the blob" {
  row="$(csv_row --source "${STUB}/anon/x/y:1|oci" --include '/anon/')"
  [[ "$row" == *",OK,206,"* ]]
}

@test "a challenge without scope gets the synthesized repository scope" {
  row="$(csv_row --source "${STUB}/noscope/x/y:1|oci" --include '/noscope/')"
  [[ "$row" == *",OK,206,"* ]]
}

@test "a scope with a space and an ampersand arrives intact" {
  row="$(csv_row --source "${STUB}/hostile/x/y:1|oci" --include '/hostile/')"
  [[ "$row" == *",OK,206,"* ]]
}

@test "a rate limit is a single pass, not a retry" {
  : >"$STUB_LOG"
  row="$(csv_row --source "${STUB}/ratelimit/x/y:1|oci" --include '/ratelimit/')"
  [[ "$row" == *",FAILED,RATELIMIT,"* ]]
  [ "$(grep -c '/ratelimit/' "$STUB_LOG")" -eq 1 ]
}

@test "a stalled token endpoint is bounded and reports NOTOKEN" {
  row="$(csv_row --timeout 3 --source "${STUB}/stall/x/y:1|oci" --include '/stall/')"
  [[ "$row" == *",FAILED,NOTOKEN,"* ]]
}

@test "a blob failure after a redirect names the delivery host" {
  row="$(csv_row --source "${STUB}/redirdead/x/y:1|oci" --include '/redirdead/')"
  [[ "$row" == *",FAILED,REFUSED,"* ]]
  IFS=, read -r _ _ _ _ redirects final <<<"$row"
  [ "$redirects" -eq 1 ]
  [[ "$final" == "http://127.0.0.1:9/"* ]]
}

@test "every request carries containerd's User-Agent" {
  : >"$STUB_LOG"
  csv_row --source "${STUB}/ok/x/y:1|oci" --include '/ok/' >/dev/null
  [ "$(grep -c ' containerd/' "$STUB_LOG")" -ge 3 ]
  ! grep -q ' check_sources/' "$STUB_LOG"
}

@test "--user-agent overrides every request of the probe" {
  : >"$STUB_LOG"
  csv_row --user-agent 'MyOrg/1.0' --source "${STUB}/ok/x/y:1|oci" --include '/ok/' >/dev/null
  [ "$(grep -c ' MyOrg/1.0' "$STUB_LOG")" -ge 3 ]
  ! grep -q ' containerd/' "$STUB_LOG"
}

@test "every request of a token-flow probe traverses the proxy" {
  : >"$STUB_LOG"
  : >"$PROXY_LOG"
  row="$(csv_row --source "${STUB}/ok/x/y:1|oci" --include '/ok/' "$PROXY")"
  [[ "$row" == *",OK,206,"* ]]
  # Whatever reached the origin must appear in the proxy's log too; a line
  # count mismatch means a request went direct, which is how the token leak
  # was found.
  [ "$(wc -l <"$STUB_LOG")" -eq "$(wc -l <"$PROXY_LOG")" ]
  grep -q '/token' "$PROXY_LOG"
}
