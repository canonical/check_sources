#!/usr/bin/env bats
# Live checks against the real registries, for release verification. Gated
# behind CHECK_SOURCES_LIVE=1 so the default run and CI stay offline: these
# five depend on external services and must never turn CI red for a reason
# no commit caused.

load helpers

@test "the five built-in registries answer 206 with one redirect each" {
  [ "${CHECK_SOURCES_LIVE:-0}" = "1" ] || skip "set CHECK_SOURCES_LIVE=1 to run live tests"
  run "$SCRIPT" --parallel --format csv \
    --include 'ecr|docker\.io|ghcr\.io|registry\.k8s\.io|quay\.io'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '"OK","206"')" -eq 5 ]
}

@test "the full built-in list runs and reports every source" {
  [ "${CHECK_SOURCES_LIVE:-0}" = "1" ] || skip "set CHECK_SOURCES_LIVE=1 to run live tests"
  run "$SCRIPT" --parallel --format csv
  [ "$(echo "$output" | tail -n +2 | wc -l)" -eq 47 ]
}
