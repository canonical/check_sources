#!/usr/bin/env bash
# The failure labels are documented in three places that must agree: the
# FAILURE LABELS block in _print_help, the README table, and what the code
# can emit. This extracts all three lists and fails on any drift. It is part
# of the offline suite and runs in CI, replacing a rule that previously
# lived in comments and discipline.
set -euo pipefail

cd "$(dirname "$0")/.."

labels='TIMEOUT|DNS|REFUSED|TLS|REDIRS|ERR<n>|NOINDEX|NOBODY|CERTEXPIRED|CERTNAME|CERTUNTRUSTED|CERT<n>|MANIFEST<n>|NOAUTH|NOTOKEN|NOMANIFEST|RATELIMIT|RESET'

# No \b after the alternation: a label ending in ">" has no word boundary
# before a space, which silently dropped ERR<n>, MANIFEST<n> and CERT<n>.
from_help=$(./check_sources.sh --help |
  grep -oE "^\s{4}($labels) " | tr -d ' ' | sort -u)
from_readme=$(grep -oE "^\| \`($labels)\`" README.md | tr -d '|` ' | sort -u)

if ! diff <(echo "$from_help") <(echo "$from_readme") >/dev/null; then
  echo "label lists differ between --help and README:" >&2
  diff <(echo "$from_help") <(echo "$from_readme") >&2 || true
  exit 1
fi

# Every label the code can emit must be documented. The emitters are
# _curl_error_label, _cert_error_label and the literal labels in the probes.
from_code=$(grep -oE '"(NOINDEX|NOBODY|NOAUTH|NOTOKEN|NOMANIFEST|RATELIMIT|TIMEOUT|DNS|REFUSED|TLS|REDIRS|CERTEXPIRED|CERTNAME|CERTUNTRUSTED)"' \
  check_sources.sh | tr -d '"' | sort -u)
missing=$(comm -23 <(echo "$from_code") <(echo "$from_help" | grep -v '<n>'))
if [[ -n "$missing" ]]; then
  echo "labels emitted by the code but absent from --help: $missing" >&2
  exit 1
fi

echo "label lists in sync: $(echo "$from_help" | wc -l) labels"
