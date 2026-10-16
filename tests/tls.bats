#!/usr/bin/env bats
# TLS verification, offline. CURL_CA_BUNDLE points at a CA minted for this
# run, so trust, expiry and name mismatch are independently controllable and
# every CERT* label is produced on demand, with no badssl.com and no network.

load helpers

setup_file() {
  mint_certs
}

teardown_file() {
  stop_tls_stubs
}

_probe() {
  # $1: cert name; the rest: extra script arguments.
  local name="$1"
  shift
  start_tls_stub "$name"
  CURL_CA_BUNDLE="${CERTS}/ca.pem" "$SCRIPT" --format csv \
    --source "$TLS_URL" --include "${TLS_URL##https://}" "$@" 2>/dev/null |
    tail -1 | tr -d '"'
}

@test "a leaf signed by the trusted CA verifies and reports OK" {
  row="$(_probe good)"
  [[ "$row" == *",OK,200,"* ]]
}

@test "an expired certificate from a trusted issuer reports CERTEXPIRED" {
  row="$(_probe expired)"
  [[ "$row" == *",FAILED,CERTEXPIRED,"* ]]
}

@test "a certificate for another name reports CERTNAME" {
  row="$(_probe wrongname)"
  [[ "$row" == *",FAILED,CERTNAME,"* ]]
}

@test "a self-signed certificate reports CERTUNTRUSTED" {
  row="$(_probe selfsigned)"
  [[ "$row" == *",FAILED,CERTUNTRUSTED,"* ]]
}

@test "--insecure turns a rejected certificate into its underlying verdict" {
  row="$(_probe expired --insecure)"
  [[ "$row" == *",OK,200,"* ]]
}

@test "a bad certificate behind a dead proxy reports the network label" {
  row="$(_probe selfsigned http://127.0.0.1:9)"
  [[ "$row" == *",FAILED,REFUSED,"* ]]
}

@test "transport failure then certificate rejection reports the certificate" {
  # The sequence observed in the field: a retryable transport failure on
  # attempt one, the certificate on attempt two. The label must be the
  # certificate's, not the transport's.
  start_tls_stub wrongname --close-first
  row="$(CURL_CA_BUNDLE="${CERTS}/ca.pem" "$SCRIPT" --format csv \
    --source "$TLS_URL" --include "${TLS_URL##https://}" 2>/dev/null |
    tail -1 | tr -d '"')"
  [[ "$row" == *",FAILED,CERTNAME,"* ]]
}
