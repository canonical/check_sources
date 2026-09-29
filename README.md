# check_sources

## About

The `check_sources` script is a comprehensive Bash utility that validates connectivity to Canonical package repositories and third-party resources required for infrastructure deployment. Version 2.0.0 introduced configurable options, multiple output formats, parallel execution, and enhanced error handling. Version 2.1.0 adds custom sources, URL filtering, descriptive failure labels, and color-aware output. Version 3.0.0 probes each source the way the application that consumes it does, so a reachable verdict reflects whether that application can use the source, 3.0.1 fixes the text column alignment that change disturbed, and 3.1.0 drops the `bc` dependency so elapsed times are measured on any host the script already runs on. It's particularly useful for environments where internet access may be restricted or proxied.

## Why Bash, and Why a Single File

The script runs at the moment when connectivity is still an open question, and that constraint rules out most of the alternatives.

**The runtime has to be there already.** Installing a Python package, a Go toolchain or any library would depend on the very network access the script is meant to measure. A stock Ubuntu image ships Bash, `curl` and coreutils, so the only hard requirements are `curl` and `timeout`, both already present. Elapsed times are computed in Bash arithmetic from `date`, so there is no optional math dependency either.

**Getting it onto the machine has to be trivial.** One executable file can be copied with `scp`, pasted into a console session, or dropped in by cloud-init, then run with `chmod +x`. There is no clone, no build step, no install target, and nothing to uninstall afterwards.

**Whoever owns the network has to be able to read it.** A restricted environment usually means someone must review what is about to probe their perimeter. A single readable file can be reviewed in one sitting; a dependency tree cannot.

**The list of sources travels with the tool.** Keeping the sources in the script rather than in a config file means the file that was reviewed is the file that runs, with no second artifact to keep in sync.

The cost is accepted on purpose: a script long enough that a real language would handle its option parsing, its string work and its testing better, with `shellcheck` as the only automated check.

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

### What's New (v3.1.0)

- **No Optional Math Dependency**: Elapsed times are computed in Bash arithmetic from `date`, so `bc` is no longer used. On the minimal images and containers where `bc` is absent, every source now reports a real timing instead of `N/A`
- **Readable Response Times**: The text report rounds the elapsed time to three decimals with a leading zero, so the column has a fixed width and the `-> destination` note lines up across sources. The `json`, `csv` and `yaml` records keep full nanosecond precision

The `response_time` field in the machine-readable formats gains a leading zero, so
`.505224349` now reads `0.505224349`. The value is identical and parses the same.

### Fixed in v3.0.1

- **Text Column Alignment**: The URL column is sized to the widest URL in the run instead of a fixed 50 characters, so the index paths introduced in 3.0.0 no longer push the status column out of line

### What's New (v3.0.0)

- **Probe Profiles**: A source is probed as the application that consumes it. The `apt` profile sends APT's request and requires a complete PGP signed index, so a repository blocked by application-aware network policy is no longer reported reachable
- **Body Verification**: A profiled source fails when the response is not what the application expects, catching a block page served with `200` and a transfer reset partway through
- **Release Codename**: `--release` sets the codename in a profiled index path, defaulting to `VERSION_CODENAME` from `/etc/os-release`
- **YAML Output**: `--format yaml` emits one flow mapping per record
- **Destination-Based Verdicts**: Redirects are followed and the destination's status code is the one judged, so a portal redirecting to a login or block page is reported as the failure it is
- **New Failure Labels**: `NOINDEX` and `NOBODY` mark a response that arrived but is not usable

**Breaking changes.** The machine-readable formats are unchanged in schema but not in
content. The `url` field for the archive hosts is now the index path that was
requested, for example `http://archive.ubuntu.com/ubuntu/dists/noble/InRelease`
rather than `http://archive.ubuntu.com`, so a consumer matching those URLs by
equality needs updating. The set of records is no longer fixed either: on a host
where no release codename resolves and none is given with `--release`, the profiled
sources are skipped and do not appear in the output.

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
-t, --timeout SECONDS   Set timeout for each check (default: 10). A profiled
                        probe downloads a repository index rather than headers
                        only, so it needs more time on a slow link
-r, --retries COUNT     Set number of retries for failed checks (default: 2)
-p, --parallel          Run checks in parallel (faster execution)
-f, --format FORMAT     Output format: text, json, csv, yaml (default: text)  
-l, --log FILE          Log detailed output to specified file
-u, --user-agent STRING Set custom User-Agent header. Applies to profiled
                        probes too, so it can defeat the request fingerprint
                        a profile depends on
-R, --release CODENAME  Release codename substituted for {codename} in a
                        profiled source path (default: VERSION_CODENAME from
                        /etc/os-release). Sources needing one are skipped when
                        neither supplies it
-s, --source URL        Add a source to check (repeatable). Accepts
                        URL|PROFILE to probe it as that application
-S, --sources-file FILE Add sources from a file, one URL per line
-i, --include PATTERN   Only check sources whose URL matches the pattern (repeatable)
-x, --exclude PATTERN   Skip sources whose URL matches the pattern (repeatable)
    --no-color          Disable colored output
```

### Output Formats

| Format | Structure                                | Headers and summary | Example line                                                       |
|--------|------------------------------------------|---------------------|--------------------------------------------------------------------|
| `text` | Aligned columns, colored when on a tty   | Yes                 | `http://jaas.ai   [200] OK (1.547s) -> https://canonical.com/jaas` |
| `json` | One JSON object per line                 | No                  | `{"url":"http://jaas.ai","status":"OK","code":"200",...}`          |
| `csv`  | Header row, then one quoted row per line | No                  | `"http://jaas.ai","OK","200","1.547077312","1",...`                |
| `yaml` | One list item per line                   | No                  | `- {url: "http://jaas.ai", status: "OK", code: "200", ...}`        |

The elapsed time is measured in nanoseconds and rendered differently per format:
`text` rounds it to three decimals so the column has a fixed width, while `json`,
`csv` and `yaml` carry the full nanosecond precision. Both forms are written with a
leading zero, so a sub-second time reads `0.505` rather than `.505`.

Every record carries six fields: the requested URL, the status, the code, the
response time, how many redirects were followed, and the URL the request ended
on. The machine-readable formats always emit all six, so that their schema does
not change from source to source; `text` appends `-> destination` only when the
request actually moved somewhere else.

Only `text` prints the per-protocol section headers and the summary block; the
machine-readable formats emit one record per source and nothing else.

The `text` URL column is sized to the widest URL in the run, so both protocol
sections line up with each other rather than each one lining up with itself. A
profiled source carries an index path, which is longer than a host root, so the
column is wider on a run that includes one. It is capped, so a single long
`--source` cannot push the status column off the terminal.

The `yaml` format uses a single-line flow mapping per record rather than a block
mapping, so that records from different sources never interleave in `--parallel`
mode. It parses to the same structure either way.

## Dependencies

- `curl` - for HTTP/HTTPS connectivity testing
- `timeout`, `mktemp` and `date` (coreutils) - for request timeouts, parallel mode, and elapsed time
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

For a source on the default `generic` profile, the script considers 2xx, 3xx, 400, 401, 404, 405, and 429 HTTP status codes as successful connectivity indicators. That probe is a `HEAD` on the root of the host rather than on a repository file, so the code says little about the service and almost everything about the network path: each of these means the origin answered. A source on another profile is judged by that profile's rule instead, described under [Probe Profiles](#probe-profiles).

`403` is deliberately not on the list, because it is what a filtering proxy returns when it blocks a URL, which is one of the conditions this script exists to detect. `407` and `5xx` are excluded for the same reason: they point at the proxy rather than at the origin.

### Redirects

Redirects are followed, up to 10 of them, and the code being judged is the one of the destination. A `3xx` on its own only proves that something answered, and on a filtered network that something is often a portal redirecting to a login or block page; following the redirect turns that case into the `403` or `503` it really is. A chain longer than 10 hops, or a loop, is reported as `REDIRS`.

Two consequences are worth keeping in mind:

- Several of the built-in sources redirect the root path to a completely different host, for example `http://ppa.launchpad.net` to `https://launchpad.net/` and `http://artifacts.elastic.co` to `https://www.elastic.co/downloads/`. The verdict for those sources therefore reflects the destination host, not the one that was asked for. The destination is always reported, so the report can be audited.
- A `3xx` still counts as a success when it survives as the final code, which now only happens for a redirect without a usable `Location` header.

## Probe Profiles

A generic HTTP request reaching a host does not prove that the application which
will consume that host can reach it. On a network with application-aware policy,
traffic is classified by request fingerprint, so `curl` can succeed on exactly the
URL where `apt update` is reset. A probe profile makes the check send the request
the consuming application sends, and judge the answer the way that application
would.

| Profile   | Request                                                          | Counts as reachable when                                |
|-----------|------------------------------------------------------------------|---------------------------------------------------------|
| `generic` | `HEAD` on the host root, with the script's own User-Agent        | The status code is 2xx, 3xx, 400, 401, 404, 405, or 429 |
| `apt`     | `GET` of the repository index, with APT's User-Agent and headers | A complete PGP signed document arrives                  |

`generic` is the default, so a source declared as a bare URL behaves exactly as it
did before profiles existed.

The `apt` profile sends the User-Agent `Debian APT-HTTP/1.3 (<version>)`, which is
the literal string apt puts on the wire. `Debian` is part of it because Ubuntu ships
apt with the identifier its upstream compiles in, so that is what a traffic
classifier sees coming from an Ubuntu host. It is not a reference to another
distribution, and changing it would defeat the profile: a User-Agent no real apt
sends is classified as ordinary web traffic, which is the false positive this
profile exists to remove.

The version is read from the local apt, so the probe matches the apt that will
consume the source. A host without apt, such as a jump box that is not Ubuntu,
falls back to a built-in version.

The body check is the part that matters most. A filtering proxy that answers a
probe with a block page and a 200, or one that resets the connection partway
through the response, both pass a status-code check and both fail here.

### Declaring a profile

Append `|PROFILE` to a source. This works in the built-in list, in `--source`, and
in a `--sources-file`:

```bash
./check_sources.sh --source 'http://mirror.internal/ubuntu/dists/{codename}/InRelease|apt'
```

A profiled source carries its own path, because archive layouts differ. `{codename}`
in that path is replaced with the release codename, taken from `--release` when
given and otherwise from `VERSION_CODENAME` in `/etc/os-release`. When neither
supplies one, those sources are skipped and listed at the end of the run rather
than probed against a guessed value; skipped sources count as neither reachable nor
unreachable.

Two caveats. `--user-agent` overrides the User-Agent for every probe, including a
profiled one, so it can defeat the fingerprint the profile depends on. And a
profiled probe downloads a repository index of a few hundred KB rather than headers
only, so `--timeout` may need raising on a slow link.

The built-in archive hosts use the `apt` profile. `ubuntu-cloud.archive.canonical.com`
does not: its index path needs an OpenStack release segment as well as a codename,
so there is no repository-wide path to probe. The PPA hosts are generic for the same
reason, since a PPA index path needs an owner and an archive name.

## Failure Labels

When a source returns no usable HTTP response, the code column shows a short label derived from the curl exit status instead of an HTTP code. `NOINDEX` and `NOBODY` are the exception: they mark a response that did arrive but is not usable. The same label appears in the text, JSON, CSV, and YAML output and in the failed sources list of the summary.

| Label     | Meaning                                                    | curl exit code            |
|-----------|------------------------------------------------------------|---------------------------|
| `TIMEOUT` | No response within the configured timeout                  | 28, or 124 from `timeout` |
| `DNS`     | Hostname could not be resolved                             | 6                         |
| `REFUSED` | Connection refused or could not be established             | 7                         |
| `TLS`     | TLS handshake or certificate error                         | 35, 60                    |
| `REDIRS`  | More than 10 redirects, or a redirect loop                 | 47                        |
| `NOINDEX` | Profiled probe: client error on the index path             | none, a response arrived  |
| `NOBODY`  | Profiled probe: response is not what the application wants | none, a response arrived  |
| `ERR<n>`  | Any other curl failure, where `<n>` is the curl exit code  | other                     |

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
