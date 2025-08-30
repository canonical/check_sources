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
        echo "[$timestamp] $message"
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
    local sources_var="$2"
    local -n sources="$sources_var"
    
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
    local sources_var="$2"
    local -n sources="$sources_var"
    
    for source in "${sources[@]}"; do
        _check_single_source "$protocol" "$source"
    done
}

_check_protocol() {
    local protocol="$1"
    local protocol_upper=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$_OUTPUT_FORMAT" == "text" ]]; then
        echo
        _print_color "$_BLUE" "=== Checking $protocol_upper sources ==="
    fi
    
    local sources_var="_${protocol_upper}_SOURCES"
    
    if [[ "$_PARALLEL" == "true" ]]; then
        _check_sources_parallel "$protocol" "$sources_var"
    else
        _check_sources_sequential "$protocol" "$sources_var"
    fi
}

###############################################################################
# Help
###############################################################################

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

PROXY_URL:
    HTTP/HTTPS proxy URL in format: http://host:port or https://host:port

EXAMPLES:
    $_ME                                    # Basic check
    $_ME --verbose --timeout 15             # Verbose with longer timeout
    $_ME --parallel --format json           # Parallel execution with JSON output
    $_ME --log /tmp/check.log http://proxy:8080  # With logging and proxy

EXIT CODES:
    0    All sources accessible
    1    Some sources failed or error occurred
    2    Invalid arguments or missing dependencies

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
            -h|--help)
                _print_help
                exit 0
                ;;
            -v|--version)
                _print_version
                exit 0
                ;;
            -V|--verbose)
                _VERBOSE=true
                shift
                ;;
            -t|--timeout)
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    _TIMEOUT="$2"
                    shift 2
                else
                    _print_color "$_RED" "ERROR: --timeout requires a numeric argument"
                    exit 2
                fi
                ;;
            -r|--retries)
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    _RETRIES="$2"
                    shift 2
                else
                    _print_color "$_RED" "ERROR: --retries requires a numeric argument"
                    exit 2
                fi
                ;;
            -p|--parallel)
                _PARALLEL=true
                shift
                ;;
            -f|--format)
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^(text|json|csv)$ ]]; then
                    _OUTPUT_FORMAT="$2"
                    shift 2
                else
                    _print_color "$_RED" "ERROR: --format must be one of: text, json, csv"
                    exit 2
                fi
                ;;
            -l|--log)
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
            -u|--user-agent)
                if [[ -n "${2:-}" ]]; then
                    _USER_AGENT="$2"
                    shift 2
                else
                    _print_color "$_RED" "ERROR: --user-agent requires a string argument"
                    exit 2
                fi
                ;;
            http://*|https://*)
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

_main() {
    # Check dependencies first
    _check_dependencies
    
    # Parse command line options
    _parse_options "$@"
    
    # Initialize log file
    if [[ -n "$_LOG_FILE" ]]; then
        _log "Starting check_sources.sh version $_VERSION"
        _log "Options: timeout=$_TIMEOUT, retries=$_RETRIES, parallel=$_PARALLEL, format=$_OUTPUT_FORMAT"
    fi
    
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
