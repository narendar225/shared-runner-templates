#!/usr/bin/env bash
# Update Mule runtime version for deployed APIs (CloudHub 2.0 / Runtime Fabric)
# via the Anypoint Application Manager REST API (AMC v2).
#
# If APIS is "all" (case-insensitive), every deployment in the environment is
# considered. Otherwise only the named applications are considered.
# An application is patched only when its current runtime version does not
# match RUNTIME_VERSION.
#
# Required environment variables:
#   ANYPOINT_CLIENT_ID, ANYPOINT_CLIENT_SECRET
#   BUSINESS_GROUP_ORG_ID (or ANYPOINT_ORG)
#   ANYPOINT_ENV          Anypoint environment name or UUID
#   RUNTIME_VERSION       Target runtime, e.g. 4.9.11:6-java17
#   APIS                  "all" or comma-separated application names
# Optional:
#   ENV_NAME              GitHub environment (dev/it used for name prefix match)
#   RELEASE_CHANNEL       LTS / EDGE / LEGACY; included in the PATCH when set
#   ANYPOINT_BASE_URL     Default https://anypoint.mulesoft.com
set -euo pipefail

ANYPOINT_BASE_URL="${ANYPOINT_BASE_URL:-https://anypoint.mulesoft.com}"
ANYPOINT_ORG="${ANYPOINT_ORG:-${BUSINESS_GROUP_ORG_ID:-}}"
APIS="${APIS:-}"
RUNTIME_VERSION="${RUNTIME_VERSION:-}"
ANYPOINT_ENV="${ANYPOINT_ENV:-}"
ENV_NAME="${ENV_NAME:-}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-}"

if [ -z "${ANYPOINT_CLIENT_ID:-}" ] || [ -z "${ANYPOINT_CLIENT_SECRET:-}" ]; then
  echo "ERROR: ANYPOINT_CLIENT_ID and ANYPOINT_CLIENT_SECRET are required." >&2
  exit 1
fi
if [ -z "$ANYPOINT_ORG" ]; then
  echo "ERROR: BUSINESS_GROUP_ORG_ID (or ANYPOINT_ORG) is required." >&2
  exit 1
fi
if [ -z "$ANYPOINT_ENV" ]; then
  echo "ERROR: ANYPOINT_ENV is required." >&2
  exit 1
fi
if [ -z "$RUNTIME_VERSION" ]; then
  echo "ERROR: RUNTIME_VERSION is required." >&2
  exit 1
fi
if [ -z "$APIS" ]; then
  echo "ERROR: APIS is required. Use 'all' or a comma-separated list of application names." >&2
  exit 1
fi

AMC_BASE="${ANYPOINT_BASE_URL}/amc/application-manager/api/v2/organizations/${ANYPOINT_ORG}/environments"
SUMMARY_DIR=$(mktemp -d)
trap 'rm -rf "$SUMMARY_DIR"' EXIT
: > "$SUMMARY_DIR/updated"
: > "$SUMMARY_DIR/skipped"
: > "$SUMMARY_DIR/failed"
: > "$SUMMARY_DIR/not_found"

# ---------------------------------------------------------------------------
# 1. Access token (connected app / client credentials)
# ---------------------------------------------------------------------------
TOKEN=$(curl -sS -X POST "${ANYPOINT_BASE_URL}/accounts/api/v2/oauth2/token" \
  -H "Content-Type: application/json" \
  -d "{\"client_id\":\"${ANYPOINT_CLIENT_ID}\",\"client_secret\":\"${ANYPOINT_CLIENT_SECRET}\",\"grant_type\":\"client_credentials\"}" \
  | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to obtain an Anypoint access token." >&2
  exit 1
fi
echo "Obtained Anypoint access token."

# ---------------------------------------------------------------------------
# 2. Resolve environment id from name or UUID
# ---------------------------------------------------------------------------
if echo "$ANYPOINT_ENV" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
  ENV_ID="$ANYPOINT_ENV"
else
  ENV_HTTP=$(curl -sS -o /tmp/anypoint_environments.json -w "%{http_code}" \
    "${ANYPOINT_BASE_URL}/accounts/api/organizations/${ANYPOINT_ORG}/environments" \
    -H "Authorization: Bearer $TOKEN")
  if [ "$ENV_HTTP" -lt 200 ] || [ "$ENV_HTTP" -ge 300 ]; then
    echo "ERROR: Failed to list Anypoint environments (HTTP $ENV_HTTP)." >&2
    cat /tmp/anypoint_environments.json >&2 || true
    exit 1
  fi
  ENV_ID=$(jq -r --arg n "$ANYPOINT_ENV" '
      (.data // .)
      | if type == "array" then . else [] end
      | map(select((.name | ascii_downcase) == ($n | ascii_downcase) or .id == $n))
      | .[0].id // empty
    ' /tmp/anypoint_environments.json)
fi

if [ -z "$ENV_ID" ]; then
  echo "ERROR: Could not resolve Anypoint environment id for '$ANYPOINT_ENV'." >&2
  exit 1
fi
echo "Resolved environment '$ANYPOINT_ENV' -> $ENV_ID"

# ---------------------------------------------------------------------------
# 3. List all deployments (paginated)
# ---------------------------------------------------------------------------
OFFSET=0
LIMIT=100
ALL_ITEMS="[]"
while true; do
  LIST_HTTP=$(curl -sS -o /tmp/anypoint_deployments.json -w "%{http_code}" \
    "${AMC_BASE}/${ENV_ID}/deployments?offset=${OFFSET}&limit=${LIMIT}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json;charset=UTF-8" \
    -H "X-ANYPNT-ORG-ID: ${ANYPOINT_ORG}" \
    -H "X-ANYPNT-ENV-ID: ${ENV_ID}")
  if [ "$LIST_HTTP" -lt 200 ] || [ "$LIST_HTTP" -ge 300 ]; then
    echo "ERROR: Failed to list deployments (HTTP $LIST_HTTP)." >&2
    cat /tmp/anypoint_deployments.json >&2 || true
    exit 1
  fi

  PAGE_ITEMS=$(jq -c 'if type == "array" then . else (.items // []) end' /tmp/anypoint_deployments.json)
  COUNT=$(echo "$PAGE_ITEMS" | jq 'length')
  ALL_ITEMS=$(jq -c --argjson a "$ALL_ITEMS" --argjson b "$PAGE_ITEMS" '$a + $b')
  TOTAL=$(jq -r '.total // empty' /tmp/anypoint_deployments.json)
  OFFSET=$((OFFSET + COUNT))

  if [ "$COUNT" -eq 0 ]; then
    break
  fi
  if [ -n "$TOTAL" ] && [ "$OFFSET" -ge "$TOTAL" ]; then
    break
  fi
  if [ "$COUNT" -lt "$LIMIT" ]; then
    break
  fi
done

DEPLOYMENT_COUNT=$(echo "$ALL_ITEMS" | jq 'length')
echo "Found $DEPLOYMENT_COUNT deployment(s) in environment '$ANYPOINT_ENV'."

if [ "$DEPLOYMENT_COUNT" -eq 0 ]; then
  echo "No deployments found. Nothing to update."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Select target APIs
# ---------------------------------------------------------------------------
APIS_NORMALIZED=$(echo "$APIS" | tr '[:upper:]' '[:lower:]' | tr -d '\r' | xargs)
ENV_LOWER=$(echo "${ENV_NAME:-}" | tr '[:upper:]' '[:lower:]')
ENV_PREFIX=""
if [ "$ENV_LOWER" = "dev" ] || [ "$ENV_LOWER" = "it" ]; then
  ENV_PREFIX="$ENV_LOWER"
fi

if [ "$APIS_NORMALIZED" = "all" ]; then
  TARGET_ITEMS="$ALL_ITEMS"
  echo "APIS=all -> evaluating every deployed application."
else
  REQUESTED_JSON=$(printf '%s' "$APIS" | tr ',' '\n' | tr -d '\r' | awk '{$1=$1; if (NF) print}' | jq -Rsc 'split("\n") | map(select(length > 0))')
  echo "APIS filter: $(echo "$REQUESTED_JSON" | jq -r 'join(", ")')"

  TARGET_ITEMS=$(echo "$ALL_ITEMS" | jq -c --argjson names "$REQUESTED_JSON" --arg prefix "$ENV_PREFIX" '
    def norm: ascii_downcase;
    def requested:
      $names | map(norm);
    def aliases($n):
      [$n]
      + (if $prefix != "" then [$prefix + "-" + $n] else [] end)
      + (if $prefix != "" and ($n | startswith($prefix + "-")) then [$n[($prefix | length)+1:]] else [] end);
    [.[] | select((.name // "") as $n | (aliases($n | norm) | any(. as $a | (requested | index($a)) != null)))]
  ')

  # Record requested names that did not match any deployment
  echo "$ALL_ITEMS" | jq -r --argjson names "$REQUESTED_JSON" --arg prefix "$ENV_PREFIX" '
    def norm: ascii_downcase;
    def aliases($n):
      [$n]
      + (if $prefix != "" then [$prefix + "-" + $n] else [] end)
      + (if $prefix != "" and ($n | startswith($prefix + "-")) then [$n[($prefix | length)+1:]] else [] end);
    ($names) as $req
    | ($req | map(norm)) as $reqn
    | . as $items
    | $req[]
    | . as $orig
    | select(
        ($items | map(.name // "") | map(aliases(. | norm) | any(. as $a | $a == ($orig | norm))) | any)
        | not
      )
  ' >> "$SUMMARY_DIR/not_found" || true
fi

TARGET_COUNT=$(echo "$TARGET_ITEMS" | jq 'length')
echo "Selected $TARGET_COUNT application(s) for runtime version check."

if [ "$TARGET_COUNT" -eq 0 ]; then
  echo "No matching applications to evaluate."
fi

# ---------------------------------------------------------------------------
# 5. Compare current runtime version and PATCH when different
# ---------------------------------------------------------------------------
PATCH_PAYLOAD=$(jq -n --arg rv "$RUNTIME_VERSION" --arg rc "$RELEASE_CHANNEL" '
  {target: {deploymentSettings: ({runtimeVersion: $rv} + (if $rc != "" then {runtimeReleaseChannel: $rc} else {} end))}}
')

while IFS= read -r APP; do
  APP_ID=$(echo "$APP" | jq -r '.id // empty')
  APP_NAME=$(echo "$APP" | jq -r '.name // empty')
  CURRENT_VERSION=$(echo "$APP" | jq -r '.target.deploymentSettings.runtimeVersion // empty')

  if [ -z "$APP_ID" ] || [ -z "$APP_NAME" ]; then
    echo "WARN: Skipping a deployment with missing id/name." >&2
    continue
  fi

  # List payload sometimes omits deploymentSettings; fetch the full record.
  if [ -z "$CURRENT_VERSION" ]; then
    DETAIL_HTTP=$(curl -sS -o /tmp/anypoint_deployment_detail.json -w "%{http_code}" \
      "${AMC_BASE}/${ENV_ID}/deployments/${APP_ID}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json;charset=UTF-8" \
      -H "X-ANYPNT-ORG-ID: ${ANYPOINT_ORG}" \
      -H "X-ANYPNT-ENV-ID: ${ENV_ID}")
    if [ "$DETAIL_HTTP" -ge 200 ] && [ "$DETAIL_HTTP" -lt 300 ]; then
      CURRENT_VERSION=$(jq -r '.target.deploymentSettings.runtimeVersion // empty' /tmp/anypoint_deployment_detail.json)
    else
      echo "ERROR: Failed to fetch deployment '$APP_NAME' ($APP_ID) (HTTP $DETAIL_HTTP)." >&2
      echo "$APP_NAME" >> "$SUMMARY_DIR/failed"
      continue
    fi
  fi

  CURRENT_VERSION="${CURRENT_VERSION:-unknown}"
  echo "Checking '$APP_NAME' ($APP_ID): current=$CURRENT_VERSION target=$RUNTIME_VERSION"

  if [ "$CURRENT_VERSION" = "$RUNTIME_VERSION" ]; then
    echo "Skipping '$APP_NAME' — already on $RUNTIME_VERSION."
    echo "$APP_NAME" >> "$SUMMARY_DIR/skipped"
    continue
  fi

  echo "Updating '$APP_NAME' runtime $CURRENT_VERSION -> $RUNTIME_VERSION"
  HTTP_CODE=$(curl -sS -o /tmp/anypoint_runtime_patch.json -w "%{http_code}" -X PATCH \
    "${AMC_BASE}/${ENV_ID}/deployments/${APP_ID}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json;charset=UTF-8" \
    -H "X-ANYPNT-ORG-ID: ${ANYPOINT_ORG}" \
    -H "X-ANYPNT-ENV-ID: ${ENV_ID}" \
    -d "$PATCH_PAYLOAD")

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "ERROR: Failed to update '$APP_NAME' (HTTP $HTTP_CODE)." >&2
    cat /tmp/anypoint_runtime_patch.json >&2 || true
    echo "$APP_NAME" >> "$SUMMARY_DIR/failed"
    continue
  fi

  echo "Successfully requested runtime update for '$APP_NAME'."
  echo "$APP_NAME" >> "$SUMMARY_DIR/updated"
done < <(echo "$TARGET_ITEMS" | jq -c '.[]')

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
UPDATED_COUNT=$(grep -c . "$SUMMARY_DIR/updated" 2>/dev/null || true)
SKIPPED_COUNT=$(grep -c . "$SUMMARY_DIR/skipped" 2>/dev/null || true)
FAILED_COUNT=$(grep -c . "$SUMMARY_DIR/failed" 2>/dev/null || true)
NOT_FOUND_COUNT=$(grep -c . "$SUMMARY_DIR/not_found" 2>/dev/null || true)

echo
echo "======== Runtime version update summary ========"
echo "Target runtime version : $RUNTIME_VERSION"
echo "Updated                : ${UPDATED_COUNT:-0}"
if [ "${UPDATED_COUNT:-0}" -gt 0 ]; then
  sed 's/^/  - /' "$SUMMARY_DIR/updated"
fi
echo "Skipped (already current): ${SKIPPED_COUNT:-0}"
if [ "${SKIPPED_COUNT:-0}" -gt 0 ]; then
  sed 's/^/  - /' "$SUMMARY_DIR/skipped"
fi
echo "Not found              : ${NOT_FOUND_COUNT:-0}"
if [ "${NOT_FOUND_COUNT:-0}" -gt 0 ]; then
  sed 's/^/  - /' "$SUMMARY_DIR/not_found"
fi
echo "Failed                 : ${FAILED_COUNT:-0}"
if [ "${FAILED_COUNT:-0}" -gt 0 ]; then
  sed 's/^/  - /' "$SUMMARY_DIR/failed"
fi
echo "==============================================="

if [ "${FAILED_COUNT:-0}" -gt 0 ] || [ "${NOT_FOUND_COUNT:-0}" -gt 0 ]; then
  echo "ERROR: One or more applications failed to update or were not found." >&2
  exit 1
fi

echo "Runtime version update completed."
