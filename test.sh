#!/usr/bin/env bash
# Sends the fictional messages in test-data/messages.json to the workflow, prints a summary table,
# and checks each next_action against expectedNextAction. Exits non-zero if any check fails.
# The trigger callback URL contains a SAS signature, so it is kept in memory only:
# never echoed, never written to disk, and passed to curl via stdin instead of argv.
# Usage: ./test.sh [--raw]   (--raw also prints each JSON response)
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill in your values." >&2
  exit 1
fi
set -a; source .env; set +a

: "${AZ_SUBSCRIPTION_ID:?AZ_SUBSCRIPTION_ID is not set in .env}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is not set in .env}"
: "${LOGIC_APP_NAME:?LOGIC_APP_NAME is not set in .env}"

WORKFLOW_NAME="zucca-fan-mail-radar"
MESSAGES_FILE="test-data/messages.json"
raw=false
[[ "${1:-}" == "--raw" ]] && raw=true

callback_url=$(az rest --method post \
  --uri "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$LOGIC_APP_NAME/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WORKFLOW_NAME/triggers/manual/listCallbackUrl?api-version=2023-12-01" \
  --query value -o tsv)

rows=()
failures=0
count=$(jq length "$MESSAGES_FILE")
for ((i = 0; i < count; i++)); do
  payload=$(jq -c ".[$i] | {customerEmail, message}" "$MESSAGES_FILE")
  email=$(jq -r ".[$i].customerEmail" "$MESSAGES_FILE")
  expected=$(jq -r ".[$i].expectedNextAction // empty" "$MESSAGES_FILE")
  response=$(curl -sS --max-time 120 -X POST -H "Content-Type: application/json" \
    -d "$payload" -w '\n%{http_code}' --config - <<<"url = \"$callback_url\"")
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  if $raw; then
    echo "$body" | jq .
  fi

  if [[ "$status" != "200" ]]; then
    rows+=("$email	HTTP $status	-	-	-	-	-	FAIL")
    failures=$((failures + 1))
    continue
  fi

  next_action=$(jq -r '.next_action' <<<"$body")
  result="-"
  if [[ -n "$expected" ]]; then
    if [[ "$next_action" == "$expected" ]]; then result="PASS"; else result="FAIL (expected: $expected)"; failures=$((failures + 1)); fi
  fi

  rows+=("$email	$(jq -r '[.product, .happiness, .shareable_story, .share_permission, .flavor_request, .next_action] | @tsv' <<<"$body")	$result")
done

{
  printf 'CUSTOMER\tPRODUCT\tHAPPINESS\tSHAREABLE\tPERMISSION\tFLAVOR\tNEXT ACTION\tRESULT\n'
  printf '%s\n' "${rows[@]}"
} | column -t -s $'\t'

# Input validation: the trigger must reject these with 400 before any model call.
echo
invalid_cases=(
  'empty message|{"customerEmail":"empty.test@example.com","message":""}'
  'missing message|{"customerEmail":"missing.test@example.com"}'
)
validation_rows=()
for case in "${invalid_cases[@]}"; do
  name=${case%%|*}
  payload=${case#*|}
  status=$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" -d "$payload" --config - <<<"url = \"$callback_url\"")
  if [[ "$status" == "400" ]]; then result="PASS"; else result="FAIL (expected 400)"; failures=$((failures + 1)); fi
  validation_rows+=("$name	HTTP $status	$result")
done
{
  printf 'INVALID INPUT\tSTATUS\tRESULT\n'
  printf '%s\n' "${validation_rows[@]}"
} | column -t -s $'\t'

[[ $failures -eq 0 ]]
