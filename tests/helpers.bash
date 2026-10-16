# Shared setup for the bats suite. Each .bats file that needs the stub calls
# start_stub from its setup_file and stop_stub from teardown_file; the server
# binds port 0, so parallel runs and busy machines never collide on a port.

SCRIPT="${BATS_TEST_DIRNAME}/../check_sources.sh"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

start_stub() {
  STUB_LOG="${BATS_FILE_TMPDIR}/stub.log"
  : >"$STUB_LOG"
  python3 "${FIXTURES}/stubserver.py" "${BATS_FILE_TMPDIR}/stub.port" "$STUB_LOG" &
  echo "$!" >"${BATS_FILE_TMPDIR}/stub.pid"
  _wait_for_port_file "${BATS_FILE_TMPDIR}/stub.port"
  STUB="http://127.0.0.1:$(cat "${BATS_FILE_TMPDIR}/stub.port")"
  export STUB STUB_LOG
}

stop_stub() {
  kill "$(cat "${BATS_FILE_TMPDIR}/stub.pid")" 2>/dev/null || true
}

start_proxy() {
  PROXY_LOG="${BATS_FILE_TMPDIR}/proxy.log"
  : >"$PROXY_LOG"
  python3 "${FIXTURES}/proxy.py" "${BATS_FILE_TMPDIR}/proxy.port" "$PROXY_LOG" &
  echo "$!" >"${BATS_FILE_TMPDIR}/proxy.pid"
  _wait_for_port_file "${BATS_FILE_TMPDIR}/proxy.port"
  PROXY="http://127.0.0.1:$(cat "${BATS_FILE_TMPDIR}/proxy.port")"
  export PROXY PROXY_LOG
}

stop_proxy() {
  kill "$(cat "${BATS_FILE_TMPDIR}/proxy.pid")" 2>/dev/null || true
}

_wait_for_port_file() {
  local _i
  for _i in $(seq 1 50); do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  echo "stub server did not come up" >&2
  return 1
}

# The CSV record for the one matching source, quotes stripped:
# URL,Status,Code,ResponseTime,Redirects,FinalURL
csv_row() {
  "$SCRIPT" --format csv "$@" 2>/dev/null | tail -1 | tr -d '"'
}
