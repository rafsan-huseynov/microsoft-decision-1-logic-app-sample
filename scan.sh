#!/usr/bin/env bash
# Pre-publish scan: checks every file in the repo (except .env) for values that would
# identify your Azure environment or leak a secret. Real values are read from .env at
# run time and reported by key name only, so this script itself contains nothing identifying.
# Exits non-zero if anything matches.
set -uo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill in your values." >&2
  exit 1
fi

files=$(find . -type f ! -name .env ! -path './.git/*' | sort)
# The pattern checks skip this script, since its own regexes would match themselves.
# The .env value checks below still cover it.
pattern_files=$(echo "$files" | grep -v '^\./scan\.sh$')
matches=0

report() {
  local label=$1 out=$2
  if [[ -n "$out" ]]; then
    echo "[MATCH] $label"
    echo "$out" | cut -c1-200 | sed 's/^/    /'
    matches=$((matches + 1))
  else
    echo "[clean] $label"
  fi
}

check() {
  local label=$1; shift
  report "$label" "$(echo "$pattern_files" | xargs grep -nIE "$@" 2>/dev/null)"
}

echo "Scanning $(echo "$files" | wc -l | tr -d ' ') files (.env excluded)"
echo

check "GUIDs"                     -i '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
report "Emails not at example.com" \
  "$(echo "$pattern_files" | xargs grep -nIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null | grep -viE '@example\.com$')"
check "URLs with a SAS signature" 'sig=[A-Za-z0-9%]'
check "Storage keys / SAS tokens" -i 'AccountKey=|SharedAccessSignature=|DefaultEndpointsProtocol=|[?&]sv=20[0-9]{2}-'
check "API keys"                  -i 'api-key"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9]{16,}|Ocp-Apim-Subscription-Key|x-functions-key|[?&]code=[A-Za-z0-9_-]{20,}'
check "Bearer tokens / JWTs"      'Bearer [A-Za-z0-9._-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
check "Long key-like strings"     '[A-Za-z0-9+]{40,}={0,2}|[0-9a-fA-F]{32,}'
check "Azure hostnames"           -i '[a-z0-9-]+\.(cognitiveservices|openai|services\.ai)\.azure\.com|[a-z0-9-]+\.azurewebsites\.net|[a-z0-9-]+\.(blob|queue|table|file)\.core\.windows\.net'

echo
echo "Values from .env (reported by key, values not printed):"
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* || -z "$value" || "$key" == SCAN_EXTRA_PATTERNS ]] && continue
  value=${value%/}
  # Whole-token match, so a value like "my-model" doesn't flag "contoso-my-model".
  out=$(echo "$files" | xargs perl -ne '
    BEGIN { $v = quotemeta shift }
    print "$ARGV:$.:$_" if /(?<![A-Za-z0-9_-])$v(?![A-Za-z0-9_-])/;
    close ARGV if eof' "$value" 2>/dev/null)
  report "$key" "$out"
done < .env

# Optional: other identifiers to look for (your name, other resource names), as a regex in .env.
extra=$(grep -E '^SCAN_EXTRA_PATTERNS=' .env | cut -d= -f2-)
if [[ -n "$extra" ]]; then
  echo
  echo "SCAN_EXTRA_PATTERNS from .env:"
  report "extra identifiers" "$(echo "$files" | xargs grep -nIiE "$extra" 2>/dev/null)"
fi

echo
if [[ $matches -eq 0 ]]; then
  echo "Scan clean."
else
  echo "Scan found $matches issue(s). Review before publishing."
  exit 1
fi
