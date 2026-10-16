#!/usr/bin/env bash
#       _               _
#   ___| |__   ___  ___| | __    ___  ___  _   _ _ __ ___ ___  ___
#  / __| '_ \ / _ \/ __| |/ /   / __|/ _ \| | | | '__/ __/ _ \/ __|
# | (__| | | |  __/ (__|   <    \__ \ (_) | |_| | | | (_|  __/\__ \
#  \___|_| |_|\___|\___|_|\_\___|___/\___/ \__,_|_|  \___\___||___/
#                          |_____|
#
# Checks Canonical package repositories and any third party resources required
# by infrastructure deployment
#
# Usage:
#   check_sources.sh [OPTIONS] [proxy URL]
#
# Depends on:
#  curl, timeout (coreutils)
#

###############################################################################
# Strict Mode
###############################################################################

# Treat unset variables and parameters other than the special parameters ‘@’ or
# ‘*’ as an error when performing parameter expansion. An 'unbound variable'
# error message will be written to the standard error, and a non-interactive
# shell will exit.
#
# Short form: set -u
set -o nounset

# Short form: set -e
set -o errexit

# Allow the above trap be inherited by all functions in the script.
#
# Short form: set -E
set -o errtrace

# Return value of a pipeline is the value of the last (rightmost) command to
# exit with a non-zero status, or zero if all commands in the pipeline exit
# successfully.
set -o pipefail

# Set $IFS to only newline and tab.
#
IFS=$'\n\t'

###############################################################################
# Environment
###############################################################################

# Program basename
_ME=$(basename "${0}")

# Version
_VERSION="3.1.0"

# Colors. Cleared by _disable_colors when the output is not a terminal, when
# the NO_COLOR environment variable is set, or when --no-color is given.
_GREEN='\033[0;32m'
_RED='\033[0;31m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_RESET='\033[0m'

# Default settings
_TIMEOUT=10
_RETRIES=2
_PARALLEL=false
_VERBOSE=false
_OUTPUT_FORMAT="text"
_MAX_REDIRS=10
_LOG_FILE=""
_USER_AGENT="check_sources/${_VERSION}"
_PROXY_URL=""

# Shown in place of an elapsed time that could not be measured, which happens
# when date does not support nanosecond output.
_UNMEASURED="N/A"

# Set by --user-agent. A profile supplies its own User-Agent, so the override
# has to be distinguishable from the default rather than merely non-empty.
_USER_AGENT_SET=false

# Release codename substituted for {codename} in a profiled source path.
# Taken from --release, otherwise from /etc/os-release.
_RELEASE=""

# Version reported in the apt profile's User-Agent, resolved from the local
# apt by _resolve_apt_version. Used when the local system has no apt, which
# happens when the check runs from a jump box that is not Ubuntu.
_APT_VERSION_DEFAULT="2.8.3"
_APT_VERSION="$_APT_VERSION_DEFAULT"

# Per-run scratch directory for response bodies, created by _main and removed
# by its EXIT trap. Background subshells do not inherit that trap, so the
# directory survives until every probe has finished.
_TMPDIR=""

# Extra sources given with --source or --sources-file, appended to _SOURCES
declare -a _EXTRA_SOURCES=()
# Regular expressions given with --include and --exclude, matched against
# the full URL
declare -a _INCLUDE_PATTERNS=()
declare -a _EXCLUDE_PATTERNS=()
# Final list of sources to check, built by _select_sources. Each entry is
# "url|profile", with {codename} already substituted.
declare -a _URLS=()
# Sources left out because their path needs a release codename and none was
# available. Reported once, and counted as neither success nor failure.
declare -a _SKIPPED=()

# Width of the URL column in text output, computed from the selected sources
# by _select_sources. A profiled source carries an index path, so the widest
# URL in a run is not known until the list is built. Capped so that one long
# custom source cannot push the status off the far side of the terminal.
declare -i _URL_WIDTH=50
declare -i _URL_WIDTH_MAX=72

# Results tracking
declare -a _RESULTS=()
declare -i _SUCCESS_COUNT=0
declare -i _FAILURE_COUNT=0
# When set, _record_result appends to this file instead of updating the
# globals above. Used by parallel mode, where checks run in subshells that
# cannot modify the parent's variables.
_RESULT_FILE=""

# Probe profiles. A profile decides what request a source gets and what
# counts as reachable, so that a source is probed the way the application
# that will consume it probes it. A network that classifies traffic by
# request fingerprint then treats the probe as it treats that application.
#
# Fields:
#   method      HTTP method
#   user_agent  User-Agent, empty to use the script default
#   headers     Extra request headers, one per line, empty for none
#   ok_codes    Status codes that count as reachable
#   assert      Literal prefix the response body must start with, empty for
#               no body check. A profile with an assertion downloads the
#               whole body, because a transfer that is reset partway through
#               is exactly the failure this check exists to catch.
#
# Accepted profile names, used to validate --source and --sources-file.
# These are the profiles _profile_field knows, which is what _add_source
# actually validates against, so the two can never disagree.
#
# "oci" is in the list but carries no rows in _profile_field: its probe is a
# sequence of requests, not one curl invocation, so it is dispatched by name
# in _check_single_source instead. The name list is what _add_source
# validates against, which is what lets such a profile exist.
readonly _PROFILES="generic apt oci"

_profile_field() {
  local profile="$1"
  local field="$2"

  case "${profile}.${field}" in
    generic.method)     echo "HEAD" ;;
    generic.user_agent) echo "" ;;
    generic.headers)    echo "" ;;
    # A HEAD on a host root: 400, 404 and 405 are how several of the hosts
    # below answer it, and 401 and 429 come from the origin as well. 403,
    # 407 and 5xx are left out, because they are what a filtering proxy
    # returns when it blocks a URL, which is what this script detects.
    generic.ok_codes)   echo '^(2[0-9][0-9]|3[0-9][0-9]|400|401|404|405|429)$' ;;
    generic.assert)     echo "" ;;

    apt.method)         echo "GET" ;;
    # The literal apt sends. "Debian" is part of it because Ubuntu ships
    # apt with the identifier its upstream compiles in, so this is what a
    # traffic classifier sees from an Ubuntu host, not a reference to
    # another distribution. The version comes from the local apt.
    apt.user_agent)     echo "Debian APT-HTTP/1.3 (${_APT_VERSION})" ;;
    apt.headers)        printf '%s\n%s\n%s\n' "Accept: text/*" "Cache-Control: max-age=0" "Connection: keep-alive" ;;
    # A repository index either arrives or it does not. Unlike a host root,
    # there is no status other than success that means the source is usable.
    apt.ok_codes)       echo '^2[0-9][0-9]$' ;;
    apt.assert)         echo "-----BEGIN PGP SIGNED MESSAGE-----" ;;

    # oci.* is intentionally absent: _check_oci_source does not consult
    # _profile_field, it builds its own requests (manifest, token, ranged
    # blob GET). _split_source and _add_source only need to recognize the
    # name, handled by _PROFILES and the "oci" case in _check_single_source.

    *) return 1 ;;
  esac
}

# Decompose an OCI reference URL into registry, repository and tag, printed
# tab separated. The reference is the standard form an operator already
# types, "scheme://registry/repository:tag", which keeps an OCI source inside
# the two-field "url|profile" grammar instead of needing a third field.
#
# The registry is everything up to the third slash, the tag is what follows
# the last colon in the remainder, and the repository is what is left, so a
# nested path keeps all of its segments. Returns non-zero when the reference
# carries no tag, which _add_source turns into an invalid-argument exit.
_split_oci_ref() {
  local url="$1"
  local scheme rest registry repository tag

  scheme="${url%%://*}"
  rest="${url#*://}"
  registry="${rest%%/*}"
  rest="${rest#*/}"

  # No path at all, or no tag on it.
  if [[ "$rest" == "$registry" ]] || [[ "$rest" != *:* ]]; then
    return 1
  fi

  tag="${rest##*:}"
  repository="${rest%:*}"

  if [[ -z "$repository" ]] || [[ -z "$tag" ]]; then
    return 1
  fi

  printf '%s\t%s\t%s\n' "${scheme}://${registry}" "$repository" "$tag"
}

# Split a "url|profile" entry. Prints the URL and the profile separated by a
# tab; an entry without a '|' resolves to the generic profile.
_split_source() {
  local entry="$1"

  if [[ "$entry" == *"|"* ]]; then
    printf '%s\t%s\n' "${entry%%|*}" "${entry##*|}"
  else
    printf '%s\t%s\n' "$entry" "generic"
  fi
}

# Sources to check, one entry per line. A host that must be reachable over
# both protocols is listed twice, side by side. The protocol sections in the
# report are derived from the URL scheme, in the order listed here.
#
# An entry may name a probe profile by appending "|<profile>". Without one it
# is probed generically, so adding a plain host is still one line per
# protocol. A profiled entry carries its own path, because archive layouts
# differ; {codename} in that path is replaced with the release codename.
readonly _SOURCES=(
  # Ubuntu archives and cloud images
  # The cloud archive is left generic: its index path needs an OpenStack
  # release segment as well as a codename, so there is no repository-wide
  # path to probe.
  http://ubuntu-cloud.archive.canonical.com
  "http://nova.cloud.archive.ubuntu.com/ubuntu/dists/{codename}/InRelease|apt"
  "http://nova.clouds.archive.ubuntu.com/ubuntu/dists/{codename}/InRelease|apt"
  http://cloud-images.ubuntu.com
  https://cloud-images.ubuntu.com
  http://keyserver.ubuntu.com
  https://keyserver.ubuntu.com
  https://contracts.canonical.com
  "http://archive.ubuntu.com/ubuntu/dists/{codename}/InRelease|apt"
  "http://security.ubuntu.com/ubuntu/dists/{codename}-security/InRelease|apt"
  https://usn.ubuntu.com
  # Launchpad
  http://launchpad.net
  https://launchpad.net
  http://api.launchpad.net
  https://api.launchpad.net
  http://ppa.launchpad.net
  https://ppa.launchpad.net
  http://ppa.launchpadcontent.net
  https://ppa.launchpadcontent.net
  # Juju and Charmhub. These web frontends answer on HTTPS only: their
  # addresses do not accept a connection on port 80 at all, while
  # api.charmhub.io, on a different address set, does. So no http:// entry
  # for jujucharms.com, jaas.ai or charmhub.io, and none for usn.ubuntu.com
  # above, which shares those addresses. Listing one would report a failure
  # on every healthy network for a path no client takes.
  https://jujucharms.com
  https://jaas.ai
  https://charmhub.io
  http://api.charmhub.io
  https://api.charmhub.io
  # Canonical services
  https://entropy.ubuntu.com
  http://streams.canonical.com
  https://streams.canonical.com
  https://public.apps.ubuntu.com
  https://login.ubuntu.com
  http://images.maas.io
  https://images.maas.io
  https://api.snapcraft.io
  https://landscape.canonical.com
  https://livepatch.canonical.com
  https://dashboard.snapcraft.io
  # Third party
  http://packages.elastic.co
  https://packages.elastic.co
  http://artifacts.elastic.co
  https://artifacts.elastic.co
  http://packages.elasticsearch.org
  https://packages.elasticsearch.org
  https://registry.jujucharms.com
  # Container registries a deployment pulls from, not only the ones
  # Canonical publishes to: a blocked registry.k8s.io stops a cluster as
  # surely as a blocked archive. Written as OCI references so they stay
  # inside the "url|profile" grammar.
  #
  # registry.jujucharms.com is deliberately absent: its token endpoint
  # requires credentials, so there is no anonymous probe to make. It is
  # checked as a generic source above.
  "https://public.ecr.aws/ubuntu/ubuntu:24.04|oci"
  "https://registry-1.docker.io/ubuntu/nginx:latest|oci"
  "https://rocks.canonical.com/cdk/pause:3.9|oci"
  "https://registry.k8s.io/pause:3.10|oci"
  "https://quay.io/ceph/ceph:v19|oci"
)

###############################################################################
# Utility Functions
###############################################################################

# Print colored output
_print_color() {
  local color="$1"
  local message="$2"
  printf "${color}%s${_RESET}\n" "$message"
}

# Log function
_log() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [[ -n "$_LOG_FILE" ]]; then
    echo "[$timestamp] $message" >>"$_LOG_FILE"
  fi

  if [[ "$_VERBOSE" == "true" ]]; then
    echo "[$timestamp] $message"
  fi
}

# Turn off colored output
_disable_colors() {
  _GREEN=""
  _RED=""
  _YELLOW=""
  _BLUE=""
  _RESET=""
}

# Disable colors when they would end up in a pipe or a file, or when the
# user asked for plain output through the NO_COLOR convention.
_setup_colors() {
  if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    _disable_colors
  fi
}

# Check if command exists
_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Validate dependencies
_check_dependencies() {
  local missing_deps=()

  for dep in curl timeout; do
    if ! _command_exists "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    _print_color "$_RED" "ERROR: Missing required dependencies: ${missing_deps[*]}"
    _print_color "$_YELLOW" "Please install the missing dependencies and try again."
    exit 1
  fi
}

# Validate proxy URL
_validate_proxy() {
  local proxy="$1"
  if [[ ! "$proxy" =~ ^https?://[^/]+:[0-9]+/?$ ]]; then
    _print_color "$_RED" "ERROR: Invalid proxy URL format: $proxy"
    _print_color "$_YELLOW" "Expected format: http://host:port or https://host:port"
    exit 1
  fi
}

###############################################################################
# Output Functions
###############################################################################

# Render elapsed nanoseconds as seconds. Both renderers divide integers and put
# the decimal point in the format string, so neither is affected by the locale's
# decimal separator the way a %f conversion would be. Anything that is not a
# number, which is the unmeasured marker, passes through untouched.

# Full precision, for the machine-readable formats.
_format_elapsed_full() {
  local ns="$1"

  if [[ ! "$ns" =~ ^[0-9]+$ ]]; then
    echo "$ns"
    return 0
  fi

  printf '%d.%09d\n' $((ns / 1000000000)) $((ns % 1000000000))
}

# Three decimals, for the text report. Millisecond resolution is the useful
# granularity here, and a fixed width keeps the field after it in one column.
_format_elapsed_short() {
  local ns="$1"

  if [[ ! "$ns" =~ ^[0-9]+$ ]]; then
    echo "$ns"
    return 0
  fi

  printf '%d.%03d\n' $((ns / 1000000000)) $(((ns / 1000000) % 1000))
}

_print_status() {
  local status="$1"
  local code="$2"
  local url="$3"
  local elapsed_ns="${4:-$_UNMEASURED}"
  local final_url="${5:-$url}"
  local redirect_count="${6:-0}"

  # The machine-readable formats always carry the destination, so that their
  # schema does not change from source to source. The text format only
  # mentions it when the request actually moved somewhere else.
  local redirect_note=""
  if [[ "$redirect_count" -gt 0 ]] && [[ "$final_url" != "$url" ]]; then
    redirect_note=" -> $final_url"
  fi

  # One measurement, two renderings: the records keep the precision a consumer
  # may want, the report keeps a width a reader can scan.
  local response_time
  if [[ "$_OUTPUT_FORMAT" == "text" ]]; then
    response_time=$(_format_elapsed_short "$elapsed_ns")
  else
    response_time=$(_format_elapsed_full "$elapsed_ns")
  fi

  # The text report writes the time as "(1.234s)". An unmeasured marker takes
  # no unit, or the line would read "(N/As)".
  local time_note="(${response_time}s)"
  if [[ "$response_time" == "$_UNMEASURED" ]]; then
    time_note="($response_time)"
  fi

  case "$_OUTPUT_FORMAT" in
  "json")
    printf '{"url":"%s","status":"%s","code":"%s","response_time":"%s","redirects":"%s","final_url":"%s"}\n' \
      "$url" "$status" "$code" "$response_time" "$redirect_count" "$final_url"
    ;;
  "csv")
    printf '"%s","%s","%s","%s","%s","%s"\n' \
      "$url" "$status" "$code" "$response_time" "$redirect_count" "$final_url"
    ;;
  "yaml")
    # One flow mapping per line, not a block mapping. Bash writes printf
    # output one line at a time, so in parallel mode a multi-line record
    # would interleave with the records of the other subshells.
    printf -- '- {url: "%s", status: "%s", code: "%s", response_time: "%s", redirects: "%s", final_url: "%s"}\n' \
      "$url" "$status" "$code" "$response_time" "$redirect_count" "$final_url"
    ;;
  *)
    # Emit the whole line in a single write. In parallel mode several
    # processes print at once, and separate writes for the URL and
    # the status would interleave across lines.
    if [[ "$status" == "OK" ]]; then
      printf "%-${_URL_WIDTH}s ${_GREEN}%s${_RESET}%s\n" "$url" "[$code] OK $time_note" "$redirect_note"
    else
      printf "%-${_URL_WIDTH}s ${_RED}%s${_RESET}%s\n" "$url" "[$code] FAILED" "$redirect_note"
    fi
    ;;
  esac
}

_print_summary() {
  local total=$((_SUCCESS_COUNT + _FAILURE_COUNT))

  if [[ "$_OUTPUT_FORMAT" == "text" ]]; then
    echo
    _print_color "$_BLUE" "=== SUMMARY ==="
    echo "Total sources checked: $total"
    _print_color "$_GREEN" "Successful: $_SUCCESS_COUNT"
    _print_color "$_RED" "Failed: $_FAILURE_COUNT"

    if [[ $_FAILURE_COUNT -gt 0 ]]; then
      echo
      _print_color "$_YELLOW" "Failed sources:"
      for result in "${_RESULTS[@]}"; do
        if [[ "$result" == *"FAILED"* ]]; then
          echo "  $result"
        fi
      done
    fi
  fi
}

###############################################################################
# Source Selection
###############################################################################

# Validate and add one user supplied source. Accepts the same "url|profile"
# syntax as the built-in list, so an internal mirror can be probed with an
# application profile without editing this file.
_add_source() {
  local entry="$1"
  local origin="$2"
  local url profile

  IFS=$'\t' read -r url profile < <(_split_source "$entry")

  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    _print_color "$_RED" "ERROR: Invalid source URL in $origin: $url"
    _print_color "$_YELLOW" "Expected format: http://host or https://host"
    exit 2
  fi

  # Validate against the name list rather than _profile_field, because a
  # profile may carry its own code path instead of field rows. _PROFILES is
  # the single answer to "is this a profile", and the dispatch in
  # _check_single_source is the single answer to "what does it do".
  if [[ " $_PROFILES " != *" $profile "* ]]; then
    _print_color "$_RED" "ERROR: Unknown probe profile in $origin: $profile"
    _print_color "$_YELLOW" "Expected one of: $_PROFILES"
    exit 2
  fi

  # An oci source has to name a tag, or there is nothing to resolve. Caught
  # here so it fails like every other bad argument, before any probe runs.
  if [[ "$profile" == "oci" ]] && ! _split_oci_ref "$url" >/dev/null; then
    _print_color "$_RED" "ERROR: Invalid OCI reference in $origin: $url"
    _print_color "$_YELLOW" "Expected format: scheme://registry/repository:tag"
    exit 2
  fi

  _EXTRA_SOURCES+=("${url}|${profile}")
}

# Read sources from a file: one URL per line, blank lines and everything
# after a '#' are ignored.
_load_sources_file() {
  local file="$1"
  local origin="file $1"
  local line

  if [[ ! -r "$file" ]]; then
    _print_color "$_RED" "ERROR: Cannot read sources file: $file"
    exit 2
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip comments and surrounding whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -n "$line" ]]; then
      _add_source "$line" "$origin"
    fi
  done <"$file"
}

# Validate a regular expression given to --include or --exclude
_validate_pattern() {
  local pattern="$1"
  local option="$2"
  local rc=0

  # [[ =~ ]] returns 2 when the expression itself is invalid. The group
  # keeps errexit from aborting on the expected non-match.
  { [[ "" =~ $pattern ]] 2>/dev/null; rc=$?; } || true
  if [[ $rc -eq 2 ]]; then
    _print_color "$_RED" "ERROR: $option requires a valid regular expression: $pattern"
    exit 2
  fi
}

# Build _URLS from the built-in and extra sources, applying the include and
# exclude patterns. A URL is kept when it matches at least one include
# pattern (or none were given) and matches no exclude pattern.
# Resolve the version the apt profile reports. apt prints the same version it
# compiles into its User-Agent, so asking the local binary keeps the probe
# faithful to the apt that will consume the source. A host without apt keeps
# the default.
_resolve_apt_version() {
  local reported=""

  if _command_exists apt-get; then
    # "apt 2.8.3 (amd64)"
    reported=$(apt-get --version 2>/dev/null | head -1 | awk '{print $2}') || reported=""
  fi

  if [[ "$reported" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    _APT_VERSION="$reported"
    _log "apt version from the local apt: $_APT_VERSION"
  else
    _log "No local apt, using default version: $_APT_VERSION"
  fi
}

# Resolve the release codename substituted into a profiled source path.
# --release wins; otherwise the local system is asked. Leaving it empty is
# not an error: it only means the sources that need one are skipped.
_resolve_codename() {
  if [[ -n "$_RELEASE" ]]; then
    _log "Release codename from --release: $_RELEASE"
    return 0
  fi

  if [[ -r /etc/os-release ]]; then
    # Read in a subshell so the sourced file cannot clobber a global here.
    # shellcheck source=/dev/null
    _RELEASE=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || _RELEASE=""
  fi

  if [[ -n "$_RELEASE" ]]; then
    _log "Release codename from /etc/os-release: $_RELEASE"
  else
    _log "No release codename available"
  fi
}

_select_sources() {
  local entry url profile pattern keep

  _resolve_codename

  for entry in "${_SOURCES[@]}" ${_EXTRA_SOURCES[@]+"${_EXTRA_SOURCES[@]}"}; do
    IFS=$'\t' read -r url profile < <(_split_source "$entry")
    keep=true

    if [[ ${#_INCLUDE_PATTERNS[@]} -gt 0 ]]; then
      keep=false
      for pattern in "${_INCLUDE_PATTERNS[@]}"; do
        if [[ "$url" =~ $pattern ]]; then
          keep=true
          break
        fi
      done
    fi

    if [[ "$keep" == "true" ]]; then
      for pattern in ${_EXCLUDE_PATTERNS[@]+"${_EXCLUDE_PATTERNS[@]}"}; do
        if [[ "$url" =~ $pattern ]]; then
          keep=false
          break
        fi
      done
    fi

    if [[ "$keep" != "true" ]]; then
      continue
    fi

    # A path that still needs a codename cannot be probed against a guessed
    # value: a wrong codename gives a 404 that looks like a missing index.
    if [[ "$url" == *"{codename}"* ]]; then
      if [[ -z "$_RELEASE" ]]; then
        _SKIPPED+=("$url")
        continue
      fi
      url="${url//\{codename\}/$_RELEASE}"
    fi

    _URLS+=("${url}|${profile}")
  done

  if [[ ${#_URLS[@]} -eq 0 ]]; then
    if [[ ${#_SKIPPED[@]} -gt 0 ]]; then
      _print_color "$_RED" "ERROR: Every selected source needs a release codename"
      _print_color "$_YELLOW" "Pass --release CODENAME, for example --release noble"
      exit 2
    fi
    _print_color "$_RED" "ERROR: No sources left to check after applying --include/--exclude"
    exit 2
  fi

  # Size the URL column to the run. Both protocol sections share it, so the
  # whole report lines up rather than each section lining up with itself.
  local entry_url widest=0
  for entry in "${_URLS[@]}"; do
    entry_url="${entry%%|*}"
    if [[ ${#entry_url} -gt $widest ]]; then
      widest=${#entry_url}
    fi
  done

  if [[ $widest -gt $_URL_WIDTH_MAX ]]; then
    widest=$_URL_WIDTH_MAX
  fi
  _URL_WIDTH=$widest

  _log "Selected ${#_URLS[@]} sources to check"
}

# Report the sources left out for want of a codename. Text format only, like
# the section headers and the summary: the record formats carry one line per
# checked source and a skipped source was never checked.
_print_skipped() {
  if [[ ${#_SKIPPED[@]} -eq 0 ]] || [[ "$_OUTPUT_FORMAT" != "text" ]]; then
    return 0
  fi

  echo
  _print_color "$_YELLOW" "Skipped, no release codename available (pass --release CODENAME):"
  local url
  for url in "${_SKIPPED[@]}"; do
    echo "  $url"
  done
}

###############################################################################
# Core Functions
###############################################################################

_set_proxy() {
  local proxy="$1"
  _validate_proxy "$proxy"
  _PROXY_URL="$proxy"
  _log "Proxy set to: $proxy"
}

# Record one check outcome. Writes to _RESULT_FILE when running as a
# background job, otherwise updates the in-process counters directly.
_record_result() {
  local status="$1"
  local url="$2"
  local code="$3"

  if [[ -n "$_RESULT_FILE" ]]; then
    printf '%s\t%s\t%s\n' "$status" "$url" "$code" >>"$_RESULT_FILE"
    return 0
  fi

  _RESULTS+=("$url: $status [$code]")
  if [[ "$status" == "OK" ]]; then
    _SUCCESS_COUNT=$((_SUCCESS_COUNT + 1))
  else
    _FAILURE_COUNT=$((_FAILURE_COUNT + 1))
  fi
}

# Map a curl (or timeout) exit status to a short label for the report.
#
# These are the labels for the case where no response arrived. A profiled
# probe adds two more, NOINDEX and NOBODY, set in _check_single_source for a
# response that arrived but is not usable. All of them are documented in the
# FAILURE LABELS block of _print_help and in the README table; the three
# lists have to stay in step.
_curl_error_label() {
  case "$1" in
    28|124) echo "TIMEOUT" ;;
    6)      echo "DNS" ;;
    7)      echo "REFUSED" ;;
    35|60)  echo "TLS" ;;
    47)     echo "REDIRS" ;;
    *)      echo "ERR$1" ;;
  esac
}

_check_single_source() {
  local entry="$1"
  local url profile

  IFS=$'\t' read -r url profile < <(_split_source "$entry")

  # A profile with its own code path is dispatched here, at the one point
  # that already has a single source and knows its profile. Routing earlier
  # would mean splitting the URL list and running two loops, and would take
  # parallel mode, the result file and the retry loop with it.
  if [[ "$profile" == "oci" ]]; then
    local oci_registry oci_repository oci_tag
    IFS=$'\t' read -r oci_registry oci_repository oci_tag < <(_split_oci_ref "$url")
    _check_oci_source "$oci_registry" "$oci_repository" "$oci_tag" "$url"
    return $?
  fi

  local method user_agent extra_headers ok_codes assert
  if ! method=$(_profile_field "$profile" method); then
    # A name in _PROFILES with neither field rows nor a branch above would
    # otherwise probe nothing and report success. Fail loudly instead.
    _print_color "$_RED" "ERROR: Profile has no probe definition: $profile"
    exit 2
  fi
  user_agent=$(_profile_field "$profile" user_agent)
  extra_headers=$(_profile_field "$profile" headers)
  ok_codes=$(_profile_field "$profile" ok_codes)
  assert=$(_profile_field "$profile" assert)

  # An explicit --user-agent wins over the profile, so that an operator can
  # reproduce one fingerprint by hand. It can therefore defeat the
  # fingerprint a profile depends on, which --help says.
  if [[ "$_USER_AGENT_SET" == "true" ]] || [[ -z "$user_agent" ]]; then
    user_agent="$_USER_AGENT"
  fi

  # A profile that asserts on the body needs somewhere to put it. The file
  # lives in the per-run directory removed by the EXIT trap in _main, so a
  # probe killed mid-transfer leaves nothing behind.
  local body_target="/dev/null"
  if [[ -n "$assert" ]]; then
    body_target=$(mktemp "${_TMPDIR}/body.XXXXXX")
  fi

  _log "Checking: $url (profile: $profile)"

  # Measure response time
  local start_time
  start_time=$(date +%s%N)

  # Perform the check with retries
  local attempt=1
  local status_code=""
  local redirect_count=0
  local final_url="$url"
  local first_line=""

  while [[ $attempt -le $_RETRIES ]]; do
    if [[ $attempt -gt 1 ]]; then
      _log "Retry attempt $attempt for $url"
      sleep 1
    fi

    # Build curl command with optional proxy. Redirects are followed so that
    # the code being judged is the one of the destination: a 3xx on its own
    # only proves that something answered, and on a filtered network that
    # something is often a portal redirecting to a login or block page.
    local curl_cmd=(
      curl
      -s -m "$_TIMEOUT" -o "$body_target"
      -w '%{http_code}\t%{num_redirects}\t%{url_effective}'
      --insecure -L --max-redirs "$_MAX_REDIRS"
      -A "$user_agent"
      --connect-timeout 5
    )

    # HEAD is the generic probe. A profile asking for anything else wants the
    # response body, so the method is set rather than -I.
    if [[ "$method" == "HEAD" ]]; then
      curl_cmd+=(-I)
    else
      curl_cmd+=(-X "$method")
    fi

    # Headers the consuming application sends. Traffic classifiers key on
    # these as much as on the User-Agent.
    local header
    while IFS= read -r header; do
      [[ -n "$header" ]] && curl_cmd+=(-H "$header")
    done <<<"$extra_headers"

    # Add proxy if set
    if [[ -n "$_PROXY_URL" ]]; then
      curl_cmd+=(--proxy "$_PROXY_URL")
    fi

    curl_cmd+=("$url")

    # curl prints "000" as the HTTP code whenever no response arrived, so
    # its exit status is what tells the failure modes apart.
    local curl_exit=0 curl_out=""
    curl_out=$(timeout "$_TIMEOUT" "${curl_cmd[@]}" 2>/dev/null) || curl_exit=$?

    # The three -w fields are tab separated, and the global IFS already splits
    # on tabs, so it is set explicitly here only to keep newlines out of it.
    status_code=""
    redirect_count=0
    final_url="$url"
    IFS=$'\t' read -r status_code redirect_count final_url <<<"$curl_out" || true
    : "${status_code:=}" "${redirect_count:=0}" "${final_url:=$url}"

    if [[ $curl_exit -eq 0 ]] && [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" != "000" ]]; then
      break
    fi

    status_code=$(_curl_error_label "$curl_exit")
    redirect_count=0
    final_url="$url"

    ((attempt++))
  done

  # Elapsed time as integer nanoseconds. date returns them directly with %s%N,
  # so the subtraction is Bash arithmetic and needs no float tool. Both stamps
  # are checked first: a BusyBox date ignores %N and returns the literal
  # characters, which would make the arithmetic fail under errexit.
  local end_time elapsed_ns
  end_time=$(date +%s%N)
  if [[ "$start_time" =~ ^[0-9]+$ ]] && [[ "$end_time" =~ ^[0-9]+$ ]]; then
    elapsed_ns=$((end_time - start_time))
  else
    elapsed_ns="$_UNMEASURED"
  fi

  # Judge the result against the profile. Which codes mean "the origin
  # answered" depends on what was asked for: see the ok_codes comments in
  # _profile_field.
  local verdict="FAILED"
  if [[ "$status_code" =~ $ok_codes ]]; then
    verdict="OK"
  elif [[ -n "$assert" ]] && [[ "$status_code" =~ ^4[0-9][0-9]$ ]]; then
    # A clean client error on an index path is a wrong path or a wrong
    # codename, not a filtered network. Saying so keeps an operator from
    # hunting a firewall rule that does not exist.
    status_code="NOINDEX"
  fi

  # The status code only says something answered. For a profile that knows
  # what the answer should look like, the body is the real test: a block page
  # served with 200, or a transfer reset partway through, both fail here.
  if [[ "$verdict" == "OK" ]] && [[ -n "$assert" ]]; then
    if ! IFS= read -r first_line <"$body_target" 2>/dev/null ||
      [[ "$first_line" != "$assert"* ]]; then
      verdict="FAILED"
      status_code="NOBODY"
    fi
  fi

  [[ "$body_target" != "/dev/null" ]] && rm -f "$body_target"

  if [[ "$verdict" == "OK" ]]; then
    _print_status "OK" "$status_code" "$url" "$elapsed_ns" "$final_url" "$redirect_count"
    _record_result "OK" "$url" "$status_code"
    return 0
  else
    _print_status "FAILED" "$status_code" "$url" "$elapsed_ns" "$final_url" "$redirect_count"
    _record_result "FAILED" "$url" "$status_code"
    return 1
  fi
}

# Pull the manifest digest and size for one OCI source without downloading
# the blob. Needed because the failure this profile chases is a reset
# partway through the blob transfer, not at the manifest: the manifest GET
# establishes the real CDN path (registry -> regional CDN -> storage
# backend) that the blob request below reuses.
#
# Echoes "digest<TAB>size<TAB>bearer_header" on success, where bearer_header
# is empty unless the registry demanded one (ghcr.io does, registry.k8s.io
# does not). Returns non-zero and echoes a status label instead when the
# manifest itself could not be fetched, so the caller can report that as
# the failure without a second request.
_oci_resolve_blob() {
  local registry="$1" repository="$2" tag="$3"
  local manifest_url="${registry}/v2/${repository}/manifests/${tag}"
  local accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

  local headers_file body_file
  headers_file=$(mktemp "${_TMPDIR}/oci-headers.XXXXXX")
  body_file=$(mktemp "${_TMPDIR}/oci-body.XXXXXX")

  local curl_cmd=(
    curl -s -m "$_TIMEOUT" --connect-timeout 5 --insecure -L --max-redirs "$_MAX_REDIRS"
    -D "$headers_file" -o "$body_file"
    -w '%{http_code}'
    -A "$_USER_AGENT" -H "Accept: ${accept}"
  )
  [[ -n "$_PROXY_URL" ]] && curl_cmd+=(--proxy "$_PROXY_URL")

  local status_code
  status_code=$(timeout "$_TIMEOUT" "${curl_cmd[@]}" "$manifest_url" 2>/dev/null) || {
    local curl_exit=$?
    echo "||$(_curl_error_label "$curl_exit")"
    return 1
  }

  # ghcr.io (and most Docker Hub-style registries) answer an unauthenticated
  # manifest GET with 401 plus a Bearer realm/service/scope to request a
  # pull token from. registry.k8s.io answers anonymously and never hits
  # this. The credential is a short-lived anonymous pull token scoped to
  # one repository, not a secret tied to any account.
  local auth_field=""
  if [[ "$status_code" == "401" ]]; then
    local www_auth realm service scope pull_token
    # No "| head -1" anywhere in this function: head exits after the first
    # line, the producer takes SIGPIPE, and pipefail plus errexit then kill
    # the subshell this runs in. That is invisible here, because a process
    # substitution is not a tested context, so the caller just sees no
    # output. Collect everything and trim in the shell instead.
    www_auth=$(grep -i '^www-authenticate:' "$headers_file" | tr -d '\r') || www_auth=""
    www_auth=${www_auth%%$'\n'*}
    realm=$(echo "$www_auth" | grep -oP 'realm="\K[^"]+') || realm=""
    service=$(echo "$www_auth" | grep -oP 'service="\K[^"]+') || service=""
    scope=$(echo "$www_auth" | grep -oP 'scope="\K[^"]+') || scope=""

    if [[ -z "$realm" ]]; then
      echo "||NOAUTH"
      return 1
    fi

    # Some registries, rocks.canonical.com among them, send a realm and a
    # service but no scope, and then refuse to mint a token for an empty
    # one. The repository was already decomposed from the source URL, so
    # the standard scope an OCI client would send costs nothing to build.
    # A challenge that does carry a scope keeps it, including the ECR one,
    # whose "aws" scope is not repository-shaped.
    if [[ -z "$scope" ]]; then
      scope="repository:${repository}:pull"
    fi

    # Docker's registry returns both "token" and "access_token", the ECR one
    # returns only "token", which is why this needs the first match rather
    # than the only match.
    pull_token=$(curl -s -m "$_TIMEOUT" --connect-timeout 5 \
      -A "$_USER_AGENT" \
      "${realm}?service=${service}&scope=${scope}" 2>/dev/null |
      grep -oP '"(token|access_token)"\s*:\s*"\K[^"]+') || pull_token=""
    pull_token=${pull_token%%$'\n'*}

    if [[ -z "$pull_token" ]]; then
      echo "||NOTOKEN"
      return 1
    fi

    auth_field="Authorization: Bearer ${pull_token}"
    status_code=$(timeout "$_TIMEOUT" "${curl_cmd[@]}" -H "$auth_field" "$manifest_url" 2>/dev/null) || {
      local retry_exit=$?
      echo "||$(_curl_error_label "$retry_exit")"
      return 1
    }
  fi

  # A rate limit is not a blocked path. These registries throttle anonymous
  # pulls, and probes run concurrently, so saying so by name keeps an
  # operator from hunting a firewall rule that does not exist.
  if [[ "$status_code" == "429" ]]; then
    echo "||RATELIMIT"
    return 1
  fi

  if [[ ! "$status_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "||MANIFEST$status_code"
    return 1
  fi

  # A manifest list/index (multi-arch) has no blob of its own: each entry
  # under "manifests" is a manifest reference, not a layer, so the amd64 one
  # has to be picked out and its digest used as if it were the tag. A
  # single-arch manifest already has layers directly and needs no such hop.
  #
  # The scan is a token stream rather than a line scan, because registries
  # differ: the Canonical ones answer with the whole document on one line,
  # while others pretty-print it. grep -o emits one match per line whatever
  # the input looked like, and within an entry the digest always precedes
  # its platform, so the digest held when architecture amd64 appears is that
  # entry's. Attestation entries report architecture "unknown" and are
  # skipped by the same test.
  # Every grep below is guarded: a no-match exits 1, pipefail turns that into
  # a failed assignment, and this function runs inside a process
  # substitution, which is not a tested context, so errexit would kill it
  # here and the caller would see no output at all rather than a label.
  local digest size
  digest=$(grep -oE '"(digest|architecture)"[[:space:]]*:[[:space:]]*"[^"]*"' "$body_file" |
    awk -F'"' '$2 == "digest" { d = $4 } $2 == "architecture" && $4 == "amd64" { print d; exit }') || digest=""

  if [[ -n "$digest" ]]; then
    # That digest names a manifest, not a blob yet: fetch it (same auth,
    # same host) to get to the actual layer digests.
    #
    # Into its own file, and adopted only on success. Writing straight over
    # body_file would replace a good index with an error document whenever
    # this second request failed, and the grep below would then report
    # NOMANIFEST as if the registry had sent something unparseable. The
    # status is a manifest status like any other, so it is reported as one.
    local hop_file hop_status
    hop_file=$(mktemp "${_TMPDIR}/oci-arch.XXXXXX")
    local arch_curl=(curl -s -m "$_TIMEOUT" --connect-timeout 5 --insecure -L --max-redirs "$_MAX_REDIRS"
      -o "$hop_file" -w '%{http_code}' -A "$_USER_AGENT" -H "Accept: ${accept}")
    [[ -n "$auth_field" ]] && arch_curl+=(-H "$auth_field")
    [[ -n "$_PROXY_URL" ]] && arch_curl+=(--proxy "$_PROXY_URL")

    local hop_exit=0
    hop_status=$(timeout "$_TIMEOUT" "${arch_curl[@]}" \
      "${registry}/v2/${repository}/manifests/${digest}" 2>/dev/null) || hop_exit=$?

    # No response at all is a network outcome, not a manifest outcome, so it
    # gets the same label the first manifest request would have given it.
    # Collapsing it into MANIFESTERR named our own step for a timeout that
    # happened on the wire, which is the one thing this report must not do.
    if (( hop_exit != 0 )) || [[ -z "$hop_status" ]]; then
      rm -f "$hop_file"
      echo "||$(_curl_error_label "$hop_exit")"
      return 1
    fi

    if [[ "$hop_status" == "429" ]]; then
      rm -f "$hop_file"
      echo "||RATELIMIT"
      return 1
    fi

    if [[ ! "$hop_status" =~ ^2[0-9][0-9]$ ]]; then
      rm -f "$hop_file"
      echo "||MANIFEST${hop_status}"
      return 1
    fi

    mv -f "$hop_file" "$body_file"
  fi

  # The blob to range-request: the last layer listed (biggest, usually the
  # application layer rather than a thin metadata one) in whichever
  # manifest body is now on disk, single-arch either from the start or
  # after the hop above.
  digest=$(grep -oP '"digest"\s*:\s*"\K[^"]+' "$body_file" | tail -1) || digest=""
  size=$(grep -oP '"size"\s*:\s*\K[0-9]+' "$body_file" | tail -1) || size=""

  if [[ -z "$digest" ]]; then
    echo "||NOMANIFEST"
    return 1
  fi

  echo "${digest}|${size:-0}|${auth_field}"
  return 0
}

# One attempt: resolve the blob, then range-GET it. Prints nothing and
# records nothing, so the caller can discard a transient attempt and try
# again. Echoes "verdict<TAB>code<TAB>url".
_oci_probe_once() {
  local registry="$1" repository="$2" tag="$3"

  local digest size auth_field
  IFS='|' read -r digest size auth_field < <(_oci_resolve_blob "$registry" "$repository" "$tag")

  if [[ -z "$digest" ]]; then
    printf 'FAILED\t%s\t\n' "${auth_field:-MANIFEST}"
    return 0
  fi

  local blob_url="${registry}/v2/${repository}/blobs/${digest}"
  local curl_cmd=(
    curl -s -m "$_TIMEOUT" --connect-timeout 5 --insecure -L --max-redirs "$_MAX_REDIRS"
    -o /dev/null -w '%{http_code}\t%{size_download}'
    -A "$_USER_AGENT" -H "Range: bytes=0-65535"
  )
  [[ -n "$auth_field" ]] && curl_cmd+=(-H "$auth_field")
  [[ -n "$_PROXY_URL" ]] && curl_cmd+=(--proxy "$_PROXY_URL")

  local curl_out status_code bytes
  curl_out=$(timeout "$_TIMEOUT" "${curl_cmd[@]}" "$blob_url" 2>/dev/null) || {
    # Read the status first: every command below, including an assignment,
    # overwrites $? and would turn the real failure into ERR0.
    local curl_exit=$?
    printf 'FAILED\t%s\t%s\n' "$(_curl_error_label "$curl_exit")" "$blob_url"
    return 0
  }

  IFS=$'\t' read -r status_code bytes <<<"$curl_out"

  # 206 is the expected answer to a Range request; some origins ignore the
  # range and send 200 with the whole blob instead, which still proves the
  # path works. Either is fine as long as bytes actually arrived: a reset
  # mid-transfer leaves status_code empty or stalls size_download at 0.
  if [[ "$status_code" =~ ^(200|206)$ ]] && [[ "${bytes:-0}" -gt 0 ]]; then
    printf 'OK\t%s\t%s\n' "$status_code" "$blob_url"
    return 0
  fi

  local fail_code="${status_code:-RESET}"
  if [[ "$status_code" == "429" ]]; then
    fail_code="RATELIMIT"
  fi
  printf 'FAILED\t%s\t%s\n' "$fail_code" "$blob_url"
  return 0
}

# A failure worth a second attempt: one that says the network did not carry
# the request, or that the registry asked us to come back later. A 404 on a
# manifest, a denied token or an unparseable body will answer the same way
# every time, so retrying them only costs the run time.
_oci_retryable() {
  case "$1" in
    TIMEOUT|DNS|REFUSED|TLS|REDIRS|RESET|RATELIMIT|ERR*) return 0 ;;
    MANIFEST5[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# Check one "registry|repository|tag" OCI entry: resolve the manifest, then
# GET the first 64 KiB of the heaviest blob with a Range header. A partial
# GET is enough to cross the registry -> CDN -> storage-backend path a real
# image pull takes without downloading whole layers, and it reproduces the
# failure the oci profile exists for: a reset partway through a blob
# transfer, which a HEAD or a manifest-only GET never triggers.
#
# An OCI probe makes four or five requests where a generic one makes a
# single HEAD, so it is that much likelier to meet one slow moment, and it
# is retried on the same _RETRIES budget for that reason. Without it a
# registry answering in a second per request, which rocks.canonical.com
# does, would report a failure the network never caused.
_check_oci_source() {
  local registry="$1" repository="$2" tag="$3"
  # The source URL as declared, which is already the reference these three
  # were taken from, so the report shows what an operator would retype.
  local label="$4"

  _log "Checking: $label (profile: oci)"

  local start_time end_time elapsed_ns
  start_time=$(date +%s%N)

  local attempt=1 verdict code target
  while [[ $attempt -le $_RETRIES ]]; do
    if [[ $attempt -gt 1 ]]; then
      _log "Retry attempt $attempt for $label"
      sleep 1
    fi

    IFS=$'\t' read -r verdict code target \
      < <(_oci_probe_once "$registry" "$repository" "$tag")

    [[ "$verdict" == "OK" ]] && break
    _oci_retryable "$code" || break

    ((attempt++))
  done

  end_time=$(date +%s%N)
  elapsed_ns=$((end_time - start_time))
  : "${target:=$label}"

  if [[ "$verdict" == "OK" ]]; then
    _print_status "OK" "$code" "$label" "$elapsed_ns" "$target" 0
    _record_result "OK" "$label" "$code"
    return 0
  fi

  _print_status "FAILED" "$code" "$label" "$elapsed_ns" "$target" 0
  _record_result "FAILED" "$label" "$code"
  return 1
}

_check_sources_parallel() {
  local urls=("$@")

  local pids=()

  # Background jobs run in subshells and cannot update the parent's
  # counters, so each one appends to a shared file that is read back
  # once every job has finished.
  _RESULT_FILE=$(mktemp)

  for url in "${urls[@]}"; do
    # The "|| true" matters as much here as in the sequential path, and for
    # a second reason. A failed check returns 1, which must not abort the
    # run; but a bare "&" also leaves errexit armed inside the background
    # subshell, where nothing tests it. Any non-zero in the middle of a
    # probe then kills that subshell before it reports, and the source
    # vanishes from the output instead of being reported as failed.
    { _check_single_source "$url" || true; } &
    pids+=($!)
  done

  # Wait for all background processes. A failed check returns 1, which
  # must not abort the script under errexit.
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  local result_file="$_RESULT_FILE"
  _RESULT_FILE=""

  local status url code
  while IFS=$'\t' read -r status url code; do
    _record_result "$status" "$url" "$code"
  done <"$result_file"

  rm -f "$result_file"
}

_check_sources_sequential() {
  local urls=("$@")

  for url in "${urls[@]}"; do
    # A failed check returns 1; do not let errexit abort the run.
    _check_single_source "$url" || true
  done
}

_check_protocol() {
  local protocol="$1"
  local protocol_upper
  protocol_upper=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')

  # Select the sources whose scheme matches this protocol, keeping their
  # order in _URLS.
  local urls=()
  local url
  for url in "${_URLS[@]}"; do
    if [[ "$url" == "${protocol}://"* ]]; then
      urls+=("$url")
    fi
  done

  if [[ ${#urls[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "$_OUTPUT_FORMAT" == "text" ]]; then
    echo
    _print_color "$_BLUE" "=== Checking $protocol_upper sources ==="
  fi

  if [[ "$_PARALLEL" == "true" ]]; then
    _check_sources_parallel "${urls[@]}"
  else
    _check_sources_sequential "${urls[@]}"
  fi
}

###############################################################################
# Help
###############################################################################

# Print one help example with the comment aligned in a fixed column,
# whatever the length of the script name.
_print_example() {
  local args="$1"
  local comment="$2"
  printf '    %-56s # %s\n' "$_ME${args:+ $args}" "$comment"
}

_print_help() {
  cat <<HEREDOC
      _               _
  ___| |__   ___  ___| | __    ___  ___  _   _ _ __ ___ ___  ___
 / __| '_ \\ / _ \\/ __| |/ /   / __|/ _ \\| | | | '__/ __/ _ \\/ __|
| (__| | | |  __/ (__|   <    \\__ \\ (_) | |_| | | | (_|  __/\\__ \\
 \\___|_| |_|\\___|\\___|_|\\_\\___|___/\\___/ \\__,_|_|  \\___\\___||___/
                         |_____|

Checks access to Canonical package repositories and third-party resources
required by infrastructure deployment.

USAGE:
    $_ME [OPTIONS] [PROXY_URL]

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -V, --verbose           Enable verbose logging
    -t, --timeout SECONDS   Set timeout for each check (default: $_TIMEOUT).
                            A profiled probe downloads a repository index
                            rather than headers only, so it needs more time
                            on a slow link
    -r, --retries COUNT     Set number of retries for failed checks (default: $_RETRIES)
    -p, --parallel          Run checks in parallel (faster but less readable)
    -f, --format FORMAT     Output format: text, json, csv, yaml (default: text)
    -l, --log FILE          Log detailed output to file
    -u, --user-agent STRING Set custom User-Agent (default: $_USER_AGENT).
                            Applies to profiled probes too, so it can defeat
                            the request fingerprint a profile depends on
    -R, --release CODENAME  Release codename substituted for {codename} in a
                            profiled source path (default: VERSION_CODENAME
                            from /etc/os-release). Sources needing one are
                            skipped when neither supplies it
    -s, --source URL        Add a source to check (repeatable). Accepts
                            URL|PROFILE to probe it as that application
    -S, --sources-file FILE Add sources from a file, one URL per line,
                            blank lines and '#' comments are ignored
    -i, --include PATTERN   Only check sources whose URL matches the
                            regular expression (repeatable)
    -x, --exclude PATTERN   Skip sources whose URL matches the regular
                            expression (repeatable)
        --no-color          Disable colored output. Colors are also disabled
                            when NO_COLOR is set or stdout is not a terminal

PROXY_URL:
    HTTP/HTTPS proxy URL in format: http://host:port or https://host:port

EXAMPLES:
HEREDOC
  _print_example "" "Basic check"
  _print_example "--verbose --timeout 15" "Verbose with longer timeout"
  _print_example "--parallel --format json" "Parallel execution with JSON output"
  _print_example "--log /tmp/check.log http://proxy:8080" "With logging and proxy"
  _print_example "--include elastic --exclude '^http:'" "Only https Elastic sources"
  _print_example "--sources-file my-sources.txt" "Also check custom sources"
  _print_example "--release noble" "Probe the archives as APT on noble"
  _print_example "--source 'http://mirror/ubuntu/dists/{codename}/InRelease|apt'" "Probe a mirror as APT"
  cat <<HEREDOC

EXIT CODES:
    0    All sources accessible
    1    Some sources failed or error occurred
    2    Invalid arguments or missing dependencies

FAILURE LABELS:
    Shown in the code column instead of an HTTP status code:
    TIMEOUT  No response within the timeout
    DNS      Hostname could not be resolved
    REFUSED  Connection refused or could not be established
    TLS      TLS handshake or certificate error
    REDIRS   More than $_MAX_REDIRS redirects, or a redirect loop
    NOINDEX  Profiled probe only: the index path answered with a client
             error, so the path or the --release codename is wrong rather
             than the network being filtered
    NOBODY   Profiled probe only: the response arrived but is not what the
             application expects, such as a block page served with 200
    ERR<n>   Any other curl failure, <n> is the curl exit code

    oci profile only, shown in place of the usual codes:
    MANIFEST<n> The registry answered the manifest request with status <n>
                instead of a 2xx (and it was not an auth challenge)
    NOAUTH      Registry demanded a token but sent no usable realm in
                WWW-Authenticate
    NOTOKEN     Token endpoint did not return a usable token
    NOMANIFEST  Manifest arrived but had no parseable blob digest
    RATELIMIT   The registry throttled the request, at the manifest or the
                blob step. Not a blocked path: the registry answered and
                said to slow down
    RESET       Blob request completed but returned no bytes, which is
                what a mid-transfer reset through a filtering proxy looks
                like from curl's side

PROBE PROFILES:
    A source is probed the way the application that consumes it probes it,
    so that a network classifying traffic by request fingerprint treats the
    probe as it treats that application. A generic HTTP request can succeed
    where the real application is blocked.

    generic  HEAD on the host root, judged by the status code. The default
    apt      GET of the repository index with APT's User-Agent and headers,
             reachable only when a complete PGP signed document arrives
    oci      Manifest fetch (with an anonymous pull token, which the
             registries demand) followed by a ranged GET on a blob. The
             source is written as an OCI reference,
             scheme://registry/repository:tag, so --source can point at an
             internal registry. It covers the CDN edge this run's source
             address was routed to, not every edge a real pull might hit

HEREDOC
}

_print_version() {
  echo "$_ME version $_VERSION"
}

###############################################################################
# Option Parsing
###############################################################################

_parse_options() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      _print_help
      exit 0
      ;;
    -v | --version)
      _print_version
      exit 0
      ;;
    -V | --verbose)
      _VERBOSE=true
      shift
      ;;
    -t | --timeout)
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        _TIMEOUT="$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --timeout requires a numeric argument"
        exit 2
      fi
      ;;
    -r | --retries)
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        _RETRIES="$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --retries requires a numeric argument"
        exit 2
      fi
      ;;
    -p | --parallel)
      _PARALLEL=true
      shift
      ;;
    -f | --format)
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^(text|json|csv|yaml)$ ]]; then
        _OUTPUT_FORMAT="$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --format must be one of: text, json, csv, yaml"
        exit 2
      fi
      ;;
    -l | --log)
      if [[ -n "${2:-}" ]]; then
        _LOG_FILE="$2"
        # Create log file directory if it doesn't exist
        mkdir -p "$(dirname "$_LOG_FILE")"
        shift 2
      else
        _print_color "$_RED" "ERROR: --log requires a file path argument"
        exit 2
      fi
      ;;
    -R | --release)
      if [[ -n "${2:-}" ]]; then
        _RELEASE="$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --release requires a codename argument"
        exit 2
      fi
      ;;
    -u | --user-agent)
      if [[ -n "${2:-}" ]]; then
        _USER_AGENT="$2"
        _USER_AGENT_SET=true
        shift 2
      else
        _print_color "$_RED" "ERROR: --user-agent requires a string argument"
        exit 2
      fi
      ;;
    -s | --source)
      if [[ -n "${2:-}" ]]; then
        _add_source "$2" "--source"
        shift 2
      else
        _print_color "$_RED" "ERROR: --source requires a URL argument"
        exit 2
      fi
      ;;
    -S | --sources-file)
      if [[ -n "${2:-}" ]]; then
        _load_sources_file "$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --sources-file requires a file path argument"
        exit 2
      fi
      ;;
    -i | --include)
      if [[ -n "${2:-}" ]]; then
        _validate_pattern "$2" "--include"
        _INCLUDE_PATTERNS+=("$2")
        shift 2
      else
        _print_color "$_RED" "ERROR: --include requires a pattern argument"
        exit 2
      fi
      ;;
    -x | --exclude)
      if [[ -n "${2:-}" ]]; then
        _validate_pattern "$2" "--exclude"
        _EXCLUDE_PATTERNS+=("$2")
        shift 2
      else
        _print_color "$_RED" "ERROR: --exclude requires a pattern argument"
        exit 2
      fi
      ;;
    --no-color)
      _disable_colors
      shift
      ;;
    http://* | https://*)
      _set_proxy "$1"
      shift
      ;;
    *)
      _print_color "$_RED" "ERROR: Unknown option: $1"
      _print_help
      exit 2
      ;;
    esac
  done
}

###############################################################################
# Main
###############################################################################

_main() {
  # Colors first, so every message below honors the terminal and NO_COLOR
  _setup_colors

  # Check dependencies first
  _check_dependencies

  # Scratch space for response bodies. Background probes do not inherit this
  # trap, so the directory outlives them and is removed once here.
  _TMPDIR=$(mktemp -d)
  trap 'rm -rf "$_TMPDIR"' EXIT

  # Parse command line options
  _parse_options "$@"

  # Initialize log file
  if [[ -n "$_LOG_FILE" ]]; then
    _log "Starting check_sources.sh version $_VERSION"
    _log "Options: timeout=$_TIMEOUT, retries=$_RETRIES, parallel=$_PARALLEL, format=$_OUTPUT_FORMAT"
  fi

  # Build the final list of sources
  _select_sources

  # Resolve once here rather than per probe, so that the parallel subshells
  # inherit the value instead of each asking the local apt for it.
  _resolve_apt_version

  # Print CSV header if needed
  if [[ "$_OUTPUT_FORMAT" == "csv" ]]; then
    echo "URL,Status,Code,ResponseTime,Redirects,FinalURL"
  fi

  # Run the checks
  _check_protocol "http"
  _check_protocol "https"

  # Print summary
  _print_skipped
  _print_summary

  # Exit with appropriate code
  if [[ $_FAILURE_COUNT -gt 0 ]]; then
    exit 1
  else
    exit 0
  fi
}

# Call main function with all arguments
_main "$@"
