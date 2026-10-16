#!/usr/bin/env bats
# The probe must behave identically when grep is BusyBox's, which has no
# PCRE. The documented dependencies are curl, coreutils and Bash, so a grep
# capability beyond POSIX plus -E is a dependency the script may not have.

load helpers

setup_file() {
  start_stub
}

teardown_file() {
  stop_stub
}

@test "the oci flow passes with BusyBox grep on PATH" {
  command -v busybox >/dev/null || skip "busybox not installed"
  local bdir="${BATS_TEST_TMPDIR}/bbox"
  mkdir -p "$bdir"
  printf '#!/bin/sh\nexec busybox grep "$@"\n' >"${bdir}/grep"
  chmod +x "${bdir}/grep"
  row="$(PATH="${bdir}:$PATH" "$SCRIPT" --format csv \
    --source "${STUB}/ok/x/y:1|oci" --include '/ok/' 2>/dev/null | tail -1 | tr -d '"')"
  [[ "$row" == *",OK,206,"* ]]
}
