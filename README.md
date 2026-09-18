# check_sources

## About

The `check_sources` script is a comprehensive Bash utility that validates connectivity to Canonical package repositories and third-party resources required for infrastructure deployment. Version 2.0.0 introduced configurable options, multiple output formats, parallel execution, and enhanced error handling. Version 2.1.0 adds custom sources, URL filtering, descriptive failure labels, and color-aware output. It's particularly useful for environments where internet access may be restricted or proxied.

## Features

### Core Functionality

- Tests HTTP and HTTPS connectivity to 45+ essential Ubuntu and Canonical services
- Comprehensive proxy support using curl `--proxy` flag for clean isolation
- Response time measurement and detailed performance metrics
- Configurable timeout and retry mechanisms for reliable testing

### Advanced Options (v2.0.0)

- **Multiple Output Formats**: Text (default), JSON, and CSV for integration with monitoring systems
- **Parallel Execution**: `--parallel` flag for faster connectivity testing
- **Verbose Logging**: Detailed timestamped logs with optional file output
- **Flexible Configuration**: Customizable timeouts, retry counts, and user agents
- **Enhanced Error Handling**: Comprehensive dependency checking and validation
- **Comprehensive Help**: Built-in documentation with usage examples

### What's New (v2.1.0)

- **Custom Sources**: Add your own URLs with `--source` or a `--sources-file`
- **Source Filtering**: `--include` and `--exclude` regular expressions to test a subset of sources
- **Failure Labels**: Unreachable sources report `TIMEOUT`, `DNS`, `REFUSED`, `TLS` or `ERR<n>` instead of a bare `000`
- **Color Aware Output**: Colors are disabled automatically when piped, when `NO_COLOR` is set, or with `--no-color`
- **Reliable Parallel Mode**: Summary counts and exit code are correct with `--parallel`, and a failed source no longer aborts the run

### Validated Services

- **Ubuntu Infrastructure**: Package management, security updates, cloud images, keyserver, Ubuntu Pro contracts
- **Canonical Services**: Snap packages, Juju charms, MAAS images, Landscape, Livepatch
- **Development Platforms**: Launchpad, Charmhub, JAAS, API endpoints, dashboard services
- **Third-party Dependencies**: Elastic package and artifact repositories

## Usage

### Basic Usage

```bash
# Basic connectivity check
./check_sources.sh

# Display help and all available options
./check_sources.sh --help

# Show version information
./check_sources.sh --version
```

### Advanced Usage (v2.0.0)

```bash
# Verbose mode with custom timeout
./check_sources.sh --verbose --timeout 15

# Parallel execution with JSON output
./check_sources.sh --parallel --format json

# CSV output with logging and proxy
./check_sources.sh --format csv --log /tmp/check.log http://proxy:8080

# YAML output, one list item per source
./check_sources.sh --format yaml

# Custom retry settings with specific user agent
./check_sources.sh --retries 3 --user-agent "MyOrg-ConnChecker/1.0"
```

### Custom Sources

Extra sources are checked in addition to the built-in list. Each one must be a full `http://` or `https://` URL.

```bash
# Add sources on the command line
./check_sources.sh --source https://mirror.example.com --source http://apt.example.com

# Add sources from a file
./check_sources.sh --sources-file my-sources.txt
```

A sources file holds one URL per line. Blank lines and anything after a `#` are ignored:

```text
# Internal mirrors
https://mirror.example.com
http://apt.example.com      # legacy apt mirror
```

### Filtering Sources

`--include` and `--exclude` take extended regular expressions matched against the full URL and can be repeated. A source is checked when it matches at least one include pattern, or when no include pattern was given, and matches no exclude pattern. The filters apply to built-in and custom sources alike.

```bash
# Only the Elastic sources
./check_sources.sh --include elastic

# Everything except plain HTTP
./check_sources.sh --exclude '^http:'

# Only https Launchpad and Charmhub endpoints
./check_sources.sh --include launchpad --include charmhub --exclude '^http:'
```

### Colors

Colored output is used only when standard output is a terminal. It is turned off automatically when the output is piped or redirected, when the [`NO_COLOR`](https://no-color.org/) environment variable is set, or when `--no-color` is given.

### Command-Line Options

```text
-h, --help              Show help message and usage examples
-v, --version           Display version information  
-V, --verbose           Enable verbose logging with timestamps
-t, --timeout SECONDS   Set timeout for each check (default: 10)
-r, --retries COUNT     Set number of retries for failed checks (default: 2)
-p, --parallel          Run checks in parallel (faster execution)
-f, --format FORMAT     Output format: text, json, csv, yaml (default: text)  
-l, --log FILE          Log detailed output to specified file
-u, --user-agent STRING Set custom User-Agent header
-s, --source URL        Add a source to check (repeatable)
-S, --sources-file FILE Add sources from a file, one URL per line
-i, --include PATTERN   Only check sources whose URL matches the pattern (repeatable)
-x, --exclude PATTERN   Skip sources whose URL matches the pattern (repeatable)
    --no-color          Disable colored output
```

### Output Formats

| Format | Structure                                | Headers and summary | Example line                                                          |
|--------|------------------------------------------|---------------------|-----------------------------------------------------------------------|
| `text` | Aligned columns, colored when on a tty   | Yes                 | `http://jaas.ai       [200] OK (1.55s) -> https://canonical.com/jaas` |
| `json` | One JSON object per line                 | No                  | `{"url":"http://jaas.ai","status":"OK","code":"200",...}`             |
| `csv`  | Header row, then one quoted row per line | No                  | `"http://jaas.ai","OK","200","1.55","1","https://canonical.com/jaas"` |
| `yaml` | One list item per line                   | No                  | `- {url: "http://jaas.ai", status: "OK", code: "200", ...}`           |

Every record carries six fields: the requested URL, the status, the code, the
response time, how many redirects were followed, and the URL the request ended
on. The machine-readable formats always emit all six, so that their schema does
not change from source to source; `text` appends `-> destination` only when the
request actually moved somewhere else.

Only `text` prints the per-protocol section headers and the summary block; the
machine-readable formats emit one record per source and nothing else.

The `yaml` format uses a single-line flow mapping per record rather than a block
mapping, so that records from different sources never interleave in `--parallel`
mode. It parses to the same structure either way.

## Dependencies

- `curl` - for HTTP/HTTPS connectivity testing
- `timeout` and `mktemp` (coreutils) - for request timeout management and parallel mode
- `bc` - for response time calculations (optional, falls back to "N/A")
- Bash 4.0+ shell environment

## Tested Services

The built-in list has 46 URLs across 31 hosts. Hosts are grouped as in the script; most are checked over both HTTP and HTTPS.

**Ubuntu archives and cloud images:**

- archive.ubuntu.com
- security.ubuntu.com
- usn.ubuntu.com
- ubuntu-cloud.archive.canonical.com
- nova.cloud.archive.ubuntu.com
- nova.clouds.archive.ubuntu.com
- cloud-images.ubuntu.com
- keyserver.ubuntu.com
- contracts.canonical.com

**Launchpad:**

- launchpad.net
- api.launchpad.net
- ppa.launchpad.net
- ppa.launchpadcontent.net

**Juju and Charmhub:**

- charmhub.io
- api.charmhub.io
- jujucharms.com
- registry.jujucharms.com
- jaas.ai

**Canonical services:**

- api.snapcraft.io
- dashboard.snapcraft.io
- login.ubuntu.com
- public.apps.ubuntu.com
- entropy.ubuntu.com
- streams.canonical.com
- images.maas.io
- landscape.canonical.com
- livepatch.canonical.com

**Third party:**

- packages.elastic.co
- artifacts.elastic.co
- packages.elasticsearch.org

Run `./check_sources.sh --format csv` to get the exact list of URLs checked, including the protocol of each one.

## Exit Codes

- **0**: All sources accessible, no failures detected
- **1**: Some sources failed connectivity tests or errors occurred during execution  
- **2**: Invalid command-line arguments, unreadable sources file, invalid pattern, no sources left after filtering, or missing required dependencies

The script considers 2xx, 3xx, 400, 401, 404, 405, and 429 HTTP status codes as successful connectivity indicators. The probe is a `HEAD` on the root of the host rather than on a repository file, so the code says little about the service and almost everything about the network path: each of these means the origin answered.

`403` is deliberately not on the list, because it is what a filtering proxy returns when it blocks a URL, which is one of the conditions this script exists to detect. `407` and `5xx` are excluded for the same reason: they point at the proxy rather than at the origin.

### Redirects

Redirects are followed, up to 10 of them, and the code being judged is the one of the destination. A `3xx` on its own only proves that something answered, and on a filtered network that something is often a portal redirecting to a login or block page; following the redirect turns that case into the `403` or `503` it really is. A chain longer than 10 hops, or a loop, is reported as `REDIRS`.

Two consequences are worth keeping in mind:

- Several of the built-in sources redirect the root path to a completely different host, for example `http://ppa.launchpad.net` to `https://launchpad.net/` and `http://artifacts.elastic.co` to `https://www.elastic.co/downloads/`. The verdict for those sources therefore reflects the destination host, not the one that was asked for. The destination is always reported, so the report can be audited.
- A `3xx` still counts as a success when it survives as the final code, which now only happens for a redirect without a usable `Location` header.

## Failure Labels

When a source returns no usable HTTP response, the code column shows a short label derived from the curl exit status instead of an HTTP code. The same label appears in the text, JSON, CSV, and YAML output and in the failed sources list of the summary.

| Label     | Meaning                                                   | curl exit code            |
|-----------|-----------------------------------------------------------|---------------------------|
| `TIMEOUT` | No response within the configured timeout                 | 28, or 124 from `timeout` |
| `DNS`     | Hostname could not be resolved                            | 6                         |
| `REFUSED` | Connection refused or could not be established            | 7                         |
| `TLS`     | TLS handshake or certificate error                        | 35, 60                    |
| `REDIRS`  | More than 10 redirects, or a redirect loop                | 47                        |
| `ERR<n>`  | Any other curl failure, where `<n>` is the curl exit code | other                     |

Example:

```text
http://nonexistent.invalid.example                 [DNS] FAILED
http://127.0.0.1:1                                 [REFUSED] FAILED
http://10.255.255.1                                [TIMEOUT] FAILED
```

## Future Improvements

The following enhancements are planned for future versions:

- **IPv6 Support**: `-4` and `-6` options to force IPv4 or IPv6 for dual-stack deployments
- **Enhanced JSON**: A single JSON document with a summary object and the list of results, instead of one object per line
- **Progress Indicator**: A `[n/total]` counter in sequential text mode
- **Exit Code Alignment**: Missing dependencies and invalid proxy URLs currently exit with 1 instead of the documented 2

---

*Contributions and feature requests are welcome! Please submit issues or pull requests to help prioritize development efforts.*

## License

Please refer to the repository for current license information.
