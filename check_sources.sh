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
_VERSION="2.1.0"

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
_LOG_FILE=""
_USER_AGENT="check_sources/${_VERSION}"
_PROXY_URL=""

# Extra sources given with --source or --sources-file, appended to _SOURCES
declare -a _EXTRA_SOURCES=()
# Regular expressions given with --include and --exclude, matched against
# the full URL
declare -a _INCLUDE_PATTERNS=()
declare -a _EXCLUDE_PATTERNS=()
# Final list of URLs to check, built by _select_sources
declare -a _URLS=()

# Results tracking
declare -a _RESULTS=()
declare -i _SUCCESS_COUNT=0
declare -i _FAILURE_COUNT=0
# When set, _record_result appends to this file instead of updating the
# globals above. Used by parallel mode, where checks run in subshells that
# cannot modify the parent's variables.
_RESULT_FILE=""

# Sources to check, one URL per line. A host that must be reachable over
# both protocols is listed twice, side by side. The protocol sections in the
# report are derived from the URL scheme, in the order listed here.
readonly _SOURCES=(
  # Ubuntu archives and cloud images
  http://ubuntu-cloud.archive.canonical.com
  http://nova.cloud.archive.ubuntu.com
  http://nova.clouds.archive.ubuntu.com
  http://cloud-images.ubuntu.com
  https://cloud-images.ubuntu.com
  http://keyserver.ubuntu.com
  https://keyserver.ubuntu.com
  https://contracts.canonical.com
  http://archive.ubuntu.com
  http://security.ubuntu.com
  http://usn.ubuntu.com
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
  # Juju and Charmhub
  http://jujucharms.com
  https://jujucharms.com
  http://jaas.ai
  https://jaas.ai
  http://charmhub.io
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

_print_status() {
  local status="$1"
  local code="$2"
  local url="$3"
  local response_time="${4:-N/A}"

  case "$_OUTPUT_FORMAT" in
  "json")
    printf '{"url":"%s","status":"%s","code":"%s","response_time":"%s"}\n' \
      "$url" "$status" "$code" "$response_time"
    ;;
  "csv")
    printf '"%s","%s","%s","%s"\n' "$url" "$status" "$code" "$response_time"
    ;;
  *)
    # Emit the whole line in a single write. In parallel mode several
    # processes print at once, and separate writes for the URL and
    # the status would interleave across lines.
    if [[ "$status" == "OK" ]]; then
      printf "%-50s ${_GREEN}%s${_RESET}\n" "$url" "[$code] OK (${response_time}s)"
    else
      printf "%-50s ${_RED}%s${_RESET}\n" "$url" "[$code] FAILED"
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

# Validate and add one user supplied source URL
_add_source() {
  local url="$1"
  local origin="$2"

  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    _print_color "$_RED" "ERROR: Invalid source URL in $origin: $url"
    _print_color "$_YELLOW" "Expected format: http://host or https://host"
    exit 2
  fi

  _EXTRA_SOURCES+=("$url")
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
_select_sources() {
  local url pattern keep

  for url in "${_SOURCES[@]}" ${_EXTRA_SOURCES[@]+"${_EXTRA_SOURCES[@]}"}; do
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

    if [[ "$keep" == "true" ]]; then
      _URLS+=("$url")
    fi
  done

  if [[ ${#_URLS[@]} -eq 0 ]]; then
    _print_color "$_RED" "ERROR: No sources left to check after applying --include/--exclude"
    exit 2
  fi

  _log "Selected ${#_URLS[@]} sources to check"
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
_curl_error_label() {
  case "$1" in
    28|124) echo "TIMEOUT" ;;
    6)      echo "DNS" ;;
    7)      echo "REFUSED" ;;
    35|60)  echo "TLS" ;;
    *)      echo "ERR$1" ;;
  esac
}

_check_single_source() {
  local url="$1"

  _log "Checking: $url"

  # Measure response time
  local start_time
  start_time=$(date +%s.%N)

  # Perform the check with retries
  local attempt=1
  local status_code=""

  while [[ $attempt -le $_RETRIES ]]; do
    if [[ $attempt -gt 1 ]]; then
      _log "Retry attempt $attempt for $url"
      sleep 1
    fi

    # Build curl command with optional proxy
    local curl_cmd=(
      curl
      -s -m "$_TIMEOUT" -o /dev/null
      -w "%{http_code}"
      -I --insecure
      -A "$_USER_AGENT"
      --connect-timeout 5
    )

    # Add proxy if set
    if [[ -n "$_PROXY_URL" ]]; then
      curl_cmd+=(--proxy "$_PROXY_URL")
    fi

    curl_cmd+=("$url")

    # curl prints "000" as the HTTP code whenever no response arrived, so
    # its exit status is what tells the failure modes apart.
    local curl_exit=0
    status_code=$(timeout "$_TIMEOUT" "${curl_cmd[@]}" 2>/dev/null) || curl_exit=$?

    if [[ $curl_exit -eq 0 ]] && [[ "$status_code" =~ ^[0-9]+$ ]] && [[ "$status_code" != "000" ]]; then
      break
    fi

    status_code=$(_curl_error_label "$curl_exit")

    ((attempt++))
  done

  local end_time response_time
  end_time=$(date +%s.%N)
  response_time=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")

  # Determine if successful
  if [[ "$status_code" =~ ^(2[0-9][0-9]|3[0-9][0-9]|400|404|405)$ ]]; then
    _print_status "OK" "$status_code" "$url" "$response_time"
    _record_result "OK" "$url" "$status_code"
    return 0
  else
    _print_status "FAILED" "$status_code" "$url" "$response_time"
    _record_result "FAILED" "$url" "$status_code"
    return 1
  fi
}

_check_sources_parallel() {
  local urls=("$@")

  local pids=()

  # Background jobs run in subshells and cannot update the parent's
  # counters, so each one appends to a shared file that is read back
  # once every job has finished.
  _RESULT_FILE=$(mktemp)

  for url in "${urls[@]}"; do
    _check_single_source "$url" &
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
    -t, --timeout SECONDS   Set timeout for each check (default: $_TIMEOUT)
    -r, --retries COUNT     Set number of retries for failed checks (default: $_RETRIES)
    -p, --parallel          Run checks in parallel (faster but less readable)
    -f, --format FORMAT     Output format: text, json, csv (default: text)
    -l, --log FILE          Log detailed output to file
    -u, --user-agent STRING Set custom User-Agent (default: $_USER_AGENT)
    -s, --source URL        Add a source to check (repeatable)
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
  cat <<HEREDOC

EXIT CODES:
    0    All sources accessible
    1    Some sources failed or error occurred
    2    Invalid arguments or missing dependencies

FAILURE LABELS:
    Shown in the code column when no HTTP response arrived:
    TIMEOUT  No response within the timeout
    DNS      Hostname could not be resolved
    REFUSED  Connection refused or could not be established
    TLS      TLS handshake or certificate error
    ERR<n>   Any other curl failure, <n> is the curl exit code

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
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^(text|json|csv)$ ]]; then
        _OUTPUT_FORMAT="$2"
        shift 2
      else
        _print_color "$_RED" "ERROR: --format must be one of: text, json, csv"
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
    -u | --user-agent)
      if [[ -n "${2:-}" ]]; then
        _USER_AGENT="$2"
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

  # Parse command line options
  _parse_options "$@"

  # Initialize log file
  if [[ -n "$_LOG_FILE" ]]; then
    _log "Starting check_sources.sh version $_VERSION"
    _log "Options: timeout=$_TIMEOUT, retries=$_RETRIES, parallel=$_PARALLEL, format=$_OUTPUT_FORMAT"
  fi

  # Build the final list of sources
  _select_sources

  # Print CSV header if needed
  if [[ "$_OUTPUT_FORMAT" == "csv" ]]; then
    echo "URL,Status,Code,ResponseTime"
  fi

  # Run the checks
  _check_protocol "http"
  _check_protocol "https"

  # Print summary
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
