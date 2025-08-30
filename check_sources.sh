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
_VERSION="2.0.0"

# Colors
readonly _GREEN='\033[0;32m'
readonly _RED='\033[0;31m'
readonly _YELLOW='\033[0;33m'
readonly _BLUE='\033[0;34m'
readonly _RESET='\033[0m'

# Default settings
_TIMEOUT=10
_RETRIES=2
_PARALLEL=false
_VERBOSE=false
_OUTPUT_FORMAT="text"
_LOG_FILE=""
_USER_AGENT="check_sources/${_VERSION}"

# Results tracking
declare -a _RESULTS=()
declare -i _SUCCESS_COUNT=0
declare -i _FAILURE_COUNT=0

# List of HTTP sources
readonly _HTTP_SOURCES=(
    ubuntu-cloud.archive.canonical.com
    nova.cloud.archive.ubuntu.com
    nova.clouds.archive.ubuntu.com
    cloud-images.ubuntu.com
    keyserver.ubuntu.com
    archive.ubuntu.com
    security.ubuntu.com
    usn.ubuntu.com
    launchpad.net
    api.launchpad.net
    ppa.launchpad.net
    ppa.launchpadcontent.net
    jujucharms.com
    jaas.ai
    charmhub.io
    api.charmhub.io
    streams.canonical.com
    images.maas.io
    packages.elastic.co
    artifacts.elastic.co
    packages.elasticsearch.org
)

# List of HTTPS sources
readonly _HTTPS_SOURCES=(
    cloud-images.ubuntu.com
    keyserver.ubuntu.com
    contracts.canonical.com
    usn.ubuntu.com
    launchpad.net
    api.launchpad.net
    ppa.launchpad.net
    ppa.launchpadcontent.net
    jujucharms.com
    jaas.ai
    charmhub.io
    api.charmhub.io
    entropy.ubuntu.com
    streams.canonical.com
    public.apps.ubuntu.com
    login.ubuntu.com
    images.maas.io
    api.snapcraft.io
    landscape.canonical.com
    livepatch.canonical.com
    dashboard.snapcraft.io
    packages.elastic.co
    artifacts.elastic.co
    packages.elasticsearch.org
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
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ -n "$_LOG_FILE" ]]; then
        echo "[$timestamp] $message" >> "$_LOG_FILE"
    fi
    
    if [[ "$_VERBOSE" == "true" ]]; then
        _print_color "$_BLUE" "[$timestamp] $message"
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
            if [[ "$status" == "OK" ]]; then
                printf "%-50s " "$url"
                _print_color "$_GREEN" "[$code] OK (${response_time}s)"
            else
                printf "%-50s " "$url"
                _print_color "$_RED" "[$code] FAILED"
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
            if [[ "$status" == "OK" ]]; then
                printf "%-50s " "$url"
                _print_color "$_GREEN" "[$code] OK (${response_time}s)"
            else
                printf "%-50s " "$url"
                _print_color "$_RED" "[$code] FAILED"
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
# Core Functions
###############################################################################

_set_proxy() {
    local proxy="$1"
    _validate_proxy "$proxy"
    export http_proxy="$proxy"
    export https_proxy="$proxy"
    _log "Proxy set to: $proxy"
}

_check_single_source() {
    local protocol="$1"
    local source="$2"
    local url="${protocol}://${source}"
    
    _log "Checking: $url"
    
    # Measure response time
    local start_time=$(date +%s.%N)
    
    # Perform the check with retries
    local attempt=1
    local status_code=""
    
    while [[ $attempt -le $_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            _log "Retry attempt $attempt for $url"
            sleep 1
        fi
        
        status_code=$(timeout "$_TIMEOUT" curl \
            -s -m "$_TIMEOUT" -o /dev/null \
            -w "%{http_code}" \
            -I --insecure \
            -A "$_USER_AGENT" \
            --connect-timeout 5 \
            "$url" 2>/dev/null || echo "TIMEOUT")
        
        if [[ "$status_code" != "TIMEOUT" ]] && [[ "$status_code" =~ ^[0-9]+$ ]]; then
            break
        fi
        
        ((attempt++))
    done
    
    local end_time=$(date +%s.%N)
    local response_time=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    
    # Determine if successful
    if [[ "$status_code" =~ ^(2[0-9][0-9]|3[0-9][0-9]|400|404|405)$ ]]; then
        _print_status "OK" "$status_code" "$url" "$response_time"
        _RESULTS+=("$url: OK [$status_code]")
        ((_SUCCESS_COUNT++))
        return 0
    else
        _print_status "FAILED" "$status_code" "$url" "$response_time"
        _RESULTS+=("$url: FAILED [$status_code]")
        ((_FAILURE_COUNT++))
        return 1
    fi
}

_check_sources_parallel() {
    local protocol="$1"
    local sources_ref="$2"
    local -n sources=$sources_ref
    
    local pids=()
    
    for source in "${sources[@]}"; do
        _check_single_source "$protocol" "$source" &
        pids+=($!)
    done
    
    # Wait for all background processes
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
}

_check_sources_sequential() {
    local protocol="$1"
    local sources_ref="$2"
    local -n sources=$sources_ref
    
    for source in "${sources[@]}"; do
        _check_single_source "$protocol" "$source"
    done
}

_check_protocol() {
    local protocol="$1"
    local protocol_upper=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$_OUTPUT_FORMAT" == "text" ]]; then
        _print_color "$_BLUE" "\n=== Checking $protocol_upper sources ==="
    fi
    
    local sources_var="_${protocol_upper}_SOURCES[@]"
    
    if [[ "$_PARALLEL" == "true" ]]; then
        _check_sources_parallel "$protocol" "$sources_var"
    else
        _check_sources_sequential "$protocol" "$sources_var"
    fi
}

###############################################################################
# Help
###############################################################################

# _print_help()
#
# Print the program help information.
function _print_help() {
  cat <<HEREDOC
      _               _
  ___| |__   ___  ___| | __    ___  ___  _   _ _ __ ___ ___  ___
 / __| '_ \\ / _ \\/ __| |/ /   / __|/ _ \\| | | | '__/ __/ _ \\/ __|
| (__| | | |  __/ (__|   <    \\__ \\ (_) | |_| | | | (_|  __/\\__ \\
 \\___|_| |_|\\___|\\___|_|\\_\\___|___/\\___/ \\__,_|_|  \\___\\___||___/
                         |_____|

Checks access to Canonical package repositories as well any third party
resources required by (PCB|K8s) infrastructure deployment

Usage:
  ${_ME} [proxy URL]
  ${_ME} -h | --help

Options:
  -h --help  Show this screen.
HEREDOC
}

###############################################################################
# Program Functions
###############################################################################

# _set_proxy()
#
# Description:
#  Export http{,s} variables
function _set_proxy() {
  export http_proxy="${1}"
  export https_proxy=$http_proxy
}

# _ok()
#
# Description:
#  Print green status code
function _ok() {
  printf "${_GREEN}[%s] %s${_RESET}\\n" "${1}" "OK"
}

# Description:
#  Print red status code
function _err() {
  printf "${_RED}[%s] %s${_RESET}\\n" "${1}" "ERR"
}

# Description:
#  Check http{,s} connection to the _HTTP and _HTTPS server arrays
function _check_http() {
  _PROTO=$(echo "$1" | tr "[:lower:]" "[:upper:]")
  printf "\\n[ Checking %s sources ]--------------------------------------\\n" \
    "${_PROTO}"
  _SOURCES="_${_PROTO}_SOURCES[@]"

  for _SOURCE in "${!_SOURCES}"; do
    printf "%s: %s - " "${1}" "${_SOURCE}"
    _RET=$(
      curl -s -m 5 -o /dev/null \
        -w "%{http_code}" -I --insecure "$1"://"${_SOURCE}" || echo $?
    )

    # Print OK if the server replies with 2xx, 3xx or 4xx HTTP status codes
    if [[ "${_RET}" =~ ^2.*|^3.*|^4.* ]]; then
      _ok "${_RET}"
    else
      _err "${_RET}"
    fi
  done
}

###############################################################################
# Main
###############################################################################

# _main()
#
# Description:
#   Entry point for the program, handling basic option parsing and dispatching.
function _main() {
  # Avoid complex option parsing when only one program option is expected.
  if [[ "${1:-}" =~ ^-h|--help$ ]]; then
    _print_help
  else
    if [[ -n "${1:-}" ]]; then
      if [[ "${1}" =~ ^https?:\/\/.+:? ]]; then
        printf "\\nChecking sources against %s proxy.\\n" "${1}"
        _set_proxy "${1}"
      else
        printf "\\nERROR: Invalid proxy URL: %s\\n" "${1}"
        _print_help
        exit 1
      fi
    fi
    _check_http "http"
    _check_http "https"
  fi
}

# Call main function with all arguments
_main "$@"
