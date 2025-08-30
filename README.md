# check_sources

## About

The `check_sources` script is a comprehensive Bash utility that validates connectivity to Canonical package repositories and third-party resources required for infrastructure deployment. Version 2.0.0 introduces advanced features including configurable options, multiple output formats, parallel execution, and enhanced error handling. It's particularly useful for environments where internet access may be restricted or proxied.

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

### Validated Services

- **Ubuntu Infrastructure**: Package management, security updates, cloud images, keyserver
- **Canonical Services**: Snap packages, Juju charms, MAAS images, Landscape, Livepatch
- **Development Platforms**: Charmhub, JAAS, API endpoints, dashboard services  
- **Third-party Dependencies**: Elasticsearch packages and artifacts

## Usage

### Basic Usage

```bash
# Basic connectivity check (backward compatible)
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

# Custom retry settings with specific user agent
./check_sources.sh --retries 3 --user-agent "MyOrg-ConnChecker/1.0"
```

### Command-Line Options

```
-h, --help              Show help message and usage examples
-v, --version           Display version information  
-V, --verbose           Enable verbose logging with timestamps
-t, --timeout SECONDS   Set timeout for each check (default: 10)
-r, --retries COUNT     Set number of retries for failed checks (default: 2)
-p, --parallel          Run checks in parallel (faster execution)
-f, --format FORMAT     Output format: text, json, csv (default: text)  
-l, --log FILE          Log detailed output to specified file
-u, --user-agent STRING Set custom User-Agent header
```

## Dependencies

- `curl` - for HTTP/HTTPS connectivity testing
- `timeout` (coreutils) - for request timeout management  
- `bc` - for response time calculations (optional, falls back to "N/A")
- Bash 4.0+ shell environment with nameref support

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

- **0**: All sources accessible, no failures detected
- **1**: Some sources failed connectivity tests or errors occurred during execution  
- **2**: Invalid command-line arguments or missing required dependencies

The script considers 2xx, 3xx, 400, 404, and 405 HTTP status codes as successful connectivity indicators.

## Future Improvements

The following enhancements are planned for future versions:

### Configuration & Usability

- **Configuration Files**: Support for `~/.check_sources.conf` and `/etc/check_sources.conf` to persist user preferences
- **Custom Source Lists**: Allow users to define additional URLs via configuration files or command-line options
- **Interactive Mode**: Guided setup with prompts for timeout, retries, output format, and other preferences
- **Progress Indicators**: Real-time progress bars and status updates for long-running checks

### Advanced Connectivity Features  

- **Source Filtering**: `--include` and `--exclude` patterns to test specific subsets of sources
- **IPv6 Support**: Dual-stack connectivity testing for both IPv4 and IPv6
- **Health Scoring**: Weighted scoring system to calculate overall infrastructure health metrics
- **Circuit Breaker**: Intelligent skipping of consistently failing sources to improve performance

### Enhanced Output Formats

- **HTML Reports**: Rich web-based output with interactive charts and detailed analysis
- **XML Format**: Structured output for enterprise integration and automated processing  
- **Enhanced JSON**: Pretty-printed JSON with syntax highlighting and extended metadata

### Operational Features

- **Systemd Integration**: Native service files for production deployment and management
- **Docker Container**: Containerized version for cloud-native and orchestrated deployments
- **Plugin Architecture**: Extensible framework for custom check types and third-party integrations
- **Rate Limiting**: Configurable request throttling to respect server limits and policies

### Performance Optimizations

- **Connection Pooling**: HTTP connection reuse for improved performance and reduced overhead
- **Adaptive Timeouts**: Dynamic timeout adjustment based on historical response patterns  
- **Intelligent Scheduling**: Smart retry strategies and failure prediction algorithms

---

*Contributions and feature requests are welcome! Please submit issues or pull requests to help prioritize development efforts.*

## License

Please refer to the repository for current license information.
