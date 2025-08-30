# check_sources

## About

The `check_sources` script is a Bash utility that validates connectivity to Canonical package repositories and third-party resources required for infrastructure deployment. It's particularly useful for environments where internet access may be restricted or proxied.

## Features

- Tests HTTP and HTTPS connectivity to essential Ubuntu and Canonical services
- Supports proxy configuration for environments with restricted internet access
- Validates access to repositories needed for:
  - Ubuntu package management
  - Snap packages
  - Juju charms and controllers
  - MAAS images
  - Landscape management
  - Livepatch services
  - Elasticsearch packages

## Usage

```bash
# Basic connectivity check
./check_sources.sh

# Check connectivity through a proxy
./check_sources.sh http://proxy.example.com:8080

# Display help
./check_sources.sh -h
```

## Dependencies

- `curl` - for HTTP connectivity testing
- Bash shell environment

## Tested Services

The script validates connectivity to critical services including:

**Ubuntu Infrastructure:**
- archive.ubuntu.com
- security.ubuntu.com
- cloud-images.ubuntu.com
- keyserver.ubuntu.com

**Canonical Services:**
- charmhub.io
- snapcraft.io
- launchpad.net
- landscape.canonical.com
- livepatch.canonical.com

**Third-party Dependencies:**
- packages.elastic.co
- artifacts.elastic.co

## Exit Codes

The script uses standard HTTP status codes and curl exit codes to determine connectivity status. Successful responses include 2xx, 3xx, 400, 404, and 405 status codes.

## License

Please refer to the repository for current license information.
