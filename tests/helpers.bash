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

# Mint a throwaway CA and the four leaf certificates the TLS tests need:
# trusted, expired but trusted, wrong name, and self-signed. Minted at test
# time rather than checked in, because a committed certificate expires and
# starts failing CI on a date no commit caused. Each case isolates one
# defect: the expired leaf is signed by the trusted CA, so expiry is the
# only failure present, and so on.
mint_certs() {
  CERTS="${BATS_FILE_TMPDIR}/certs"
  mkdir -p "$CERTS"
  local subj="/CN=stub" san="subjectAltName=IP:127.0.0.1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=stub-ca" \
    -keyout "$CERTS/ca.key" -out "$CERTS/ca.pem" 2>/dev/null
  local name
  for name in good expired wrongname; do
    openssl req -newkey rsa:2048 -nodes -subj "$subj" \
      -addext "$([ "$name" = wrongname ] && echo 'subjectAltName=DNS:somewhere.else' || echo "$san")" \
      -keyout "$CERTS/$name.key" -out "$CERTS/$name.csr" 2>/dev/null
    if [ "$name" = expired ]; then
      # x509 -req only grew -not_before/-not_after in OpenSSL 3.4, and the
      # CI runner carries 3.0, which this failed on at its first outing.
      # openssl ca has taken -startdate/-enddate since long before 3.0, at
      # the cost of a one-shot CA database.
      : >"$CERTS/index.txt"
      echo 01 >"$CERTS/serial"
      printf '%s\n' '[ca]' 'default_ca = stub' '[stub]' \
        "database = $CERTS/index.txt" "serial = $CERTS/serial" \
        "new_certs_dir = $CERTS" "certificate = $CERTS/ca.pem" \
        "private_key = $CERTS/ca.key" 'default_md = sha256' \
        'policy = pol' 'copy_extensions = copy' 'email_in_dn = no' \
        'unique_subject = no' '[pol]' 'commonName = supplied' \
        >"$CERTS/ca.cnf"
      openssl ca -config "$CERTS/ca.cnf" -batch -notext \
        -startdate 20240101000000Z -enddate 20240102000000Z \
        -in "$CERTS/$name.csr" -out "$CERTS/$name.pem" 2>/dev/null
    else
      openssl x509 -req -in "$CERTS/$name.csr" -CA "$CERTS/ca.pem" \
        -CAkey "$CERTS/ca.key" -CAcreateserial -days 1 -copy_extensions copy \
        -out "$CERTS/$name.pem" 2>/dev/null
    fi
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "$subj" \
    -addext "$san" -keyout "$CERTS/selfsigned.key" \
    -out "$CERTS/selfsigned.pem" 2>/dev/null
  export CERTS
}

# One HTTPS listener per certificate: $1 cert basename, $2.. extra tlsstub
# flags. Exports TLS_URL for the test and records the pid for teardown.
start_tls_stub() {
  local name="$1"; shift
  local portfile="${BATS_FILE_TMPDIR}/tls-${name}-$$.port"
  # stdout and stderr detached: this is launched inside command
  # substitutions, which wait for every writer of the captured stdout, so an
  # inherited descriptor would hang the test until the server dies.
  python3 "${FIXTURES}/tlsstub.py" "$portfile" \
    "${CERTS}/${name}.pem" "${CERTS}/${name}.key" "$@" >/dev/null 2>&1 &
  echo "$!" >>"${BATS_FILE_TMPDIR}/tls.pids"
  _wait_for_port_file "$portfile"
  TLS_URL="https://127.0.0.1:$(cat "$portfile")"
  export TLS_URL
}

stop_tls_stubs() {
  [[ -f "${BATS_FILE_TMPDIR}/tls.pids" ]] || return 0
  while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done <"${BATS_FILE_TMPDIR}/tls.pids"
}

# The CSV record for the one matching source, quotes stripped:
# URL,Status,Code,ResponseTime,Redirects,FinalURL
csv_row() {
  "$SCRIPT" --format csv "$@" 2>/dev/null | tail -1 | tr -d '"'
}
