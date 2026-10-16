# Changelog

Notable changes to `check_sources.sh`, newest first. Dates are the release tag
dates. The same notes are published on each
[GitHub release](https://github.com/canonical/check_sources/releases).

## [4.0.1] - 2026-10-16

- **Resolver Logs Say Which Failure**: The verbose log distinguishes a version
  tool missing from PATH from one that answered with something unparseable, and
  quotes the rejected output in the second case. One message covered both, which
  left a field report unanswerable when the same machine flipped between them
  during an unattended upgrade. Which version gets used is unchanged in every
  case

## [4.0.0] - 2026-10-16

- **Certificate Verification**: Probes verify server certificates by default,
  against the same trust store `apt`, `docker` and `juju` use. A source whose
  certificate the machine rejects is reported unreachable with a label naming why:
  `CERTEXPIRED`, `CERTNAME`, `CERTUNTRUSTED` or `CERT<n>`. One further request with
  verification off distinguishes a bad certificate on an open path from a path that
  is closed. `--insecure` restores the old behavior for the whole run
- **Real Destinations for Registries**: An `oci` result reports the host the probe
  actually reached. Every registry hands the blob to a CDN, and `registry.k8s.io`
  sends even the manifest to a region-specific host, so a failure now names the
  host a firewall rule would have to allow instead of the registry that was typed
- **containerd Fingerprint**: The `oci` profile sends `containerd/<version>` on all
  of its requests, as the `apt` profile sends APT's, with the version read from the
  local containerd or a documented default
- **Runs on BusyBox**: The OCI probe no longer needs GNU grep, so a minimal jump
  box or container reports what the network did rather than what its grep could not
  parse. The token request also gained the timeout and proxy handling every other
  request already had
- **Bounded Parallelism**: `--parallel` runs at most 64 probes at once, a throttled
  registry is reported without being retried, and token query values are
  URL-encoded by curl
- **Correct Exit Codes**: Missing dependencies and an invalid proxy exit `2` as
  documented, instead of `1`
- **Test Suite and CI**: An offline bats suite in `tests/` covers the probe flows
  against local stubs, a sync check keeps the three failure label lists identical,
  and GitHub Actions runs it all on every push

**Breaking changes.** A run on a network that intercepts TLS with a CA the machine
does not trust goes from all green to all red; that is the verification working,
and `--insecure` is the escape hatch while the CA is installed. The machine-readable
`code` field gains the `CERT*` values. On OCI rows, `redirects` and `final_url`
change value: they previously claimed zero redirects and a registry URL for
transfers that were redirected to a CDN, so consumers reading them were reading
false values. Exit code `1` from a missing dependency or malformed proxy becomes
`2`. `https://ppa.launchpad.net` now fails with `CERTNAME` on every network,
because its certificate only covers `private-ppa.launchpad.net`; that is a finding,
not a regression.

## [3.2.1] - 2026-10-16

- **Registry Swap**: `rocks.canonical.com` is replaced by `ghcr.io/canonical/metrics-server:0.7.2-ck7`. Canonical has made the ROCKs registry a temporary service, to be retired in early 2027, with `ghcr.io/canonical/cdk` the supported registry from Charmed Kubernetes 1.36 on. It was also the one source that failed a healthy run: about four times slower than any other registry, which with five requests per probe put it over the timeout in 3 of 10 parallel runs
- **Corrected Label List**: `DENIED` was documented as a failure label but is never emitted. A rejected pull token reports `NOTOKEN`

The URL count is unchanged at 47, since one registry replaced another. The
`--exclude` pattern that skips the registries changes: `rocks\.canonical` becomes
`ghcr\.io`.

## [3.2.0] - 2026-10-16

- **Container Registries**: A source can be an OCI image reference, probed with the `oci` profile: it resolves the manifest with an anonymous pull token, follows a multi-arch index to the amd64 manifest, and range-GETs the first 64 KiB of a layer. That crosses the registry to CDN to storage-backend path a real `docker pull` takes, which a `HEAD` on the host never reaches
- **Five Registries Built In**: `public.ecr.aws`, `registry-1.docker.io`, `rocks.canonical.com`, `registry.k8s.io` and `quay.io`, each with an image a Canonical deployment genuinely pulls. A blocked `registry.k8s.io` stops a cluster coming up as surely as a blocked archive, so the list covers what a deployment consumes and not only what Canonical publishes
- **Registry Failure Labels**: `MANIFEST<n>`, `NOMANIFEST`, `NOTOKEN`, `RATELIMIT` and `RESET` say which step of the pull failed, so a throttled registry is not mistaken for a firewall rule
- **HTTPS-Only Frontends**: `usn.ubuntu.com`, `jujucharms.com`, `jaas.ai` and `charmhub.io` are no longer checked over HTTP. Their addresses do not accept a connection on port 80, so those four entries failed on every healthy network for a path no client takes

The built-in list goes from 46 URLs to 47. Both numbers moved: five registries were
added and four HTTP entries were dropped. A run filtered with `--exclude` to skip the
registries now yields 42 sources rather than 46, so a consumer counting records or
matching the removed URLs needs updating. `--include`, `--exclude` and `--source` all
work on registries, since they are ordinary entries in the list.

## [3.1.0] - 2026-09-29

- **No Optional Math Dependency**: Elapsed times are computed in Bash arithmetic from `date`, so `bc` is no longer used. On the minimal images and containers where `bc` is absent, every source now reports a real timing instead of `N/A`
- **Readable Response Times**: The text report rounds the elapsed time to three decimals with a leading zero, so the column has a fixed width and the `-> destination` note lines up across sources. The `json`, `csv` and `yaml` records keep full nanosecond precision

The `response_time` field in the machine-readable formats gains a leading zero, so
`.505224349` now reads `0.505224349`. The value is identical and parses the same.

## [3.0.1] - 2026-09-29

- **Text Column Alignment**: The URL column is sized to the widest URL in the run instead of a fixed 50 characters, so the index paths introduced in 3.0.0 no longer push the status column out of line

## [3.0.0] - 2026-09-29

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

## [2.1.0] - 2026-09-17

- **Custom Sources**: Add your own URLs with `--source` or a `--sources-file`
- **Source Filtering**: `--include` and `--exclude` regular expressions to test a subset of sources
- **Failure Labels**: Unreachable sources report `TIMEOUT`, `DNS`, `REFUSED`, `TLS` or `ERR<n>` instead of a bare `000`
- **Color Aware Output**: Colors are disabled automatically when piped, when `NO_COLOR` is set, or with `--no-color`
- **Reliable Parallel Mode**: Summary counts and exit code are correct with `--parallel`, and a failed source no longer aborts the run

## [2.0.0] - 2025-08-30

- **Multiple Output Formats**: Text (default), JSON, and CSV for integration with monitoring systems
- **Parallel Execution**: `--parallel` flag for faster connectivity testing
- **Verbose Logging**: Detailed timestamped logs with optional file output
- **Flexible Configuration**: Customizable timeouts, retry counts, and user agents
- **Enhanced Error Handling**: Comprehensive dependency checking and validation
- **Comprehensive Help**: Built-in documentation with usage examples
