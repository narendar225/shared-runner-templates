#!/usr/bin/env bash
# PATCH RTF RUNTIME MANAGER DEPLOYMENT SETTINGS FOR MULE
#
# Variables are passed directly from the workflow step (needs.initialization.outputs.*).
# ---------------------------------------------------------------------------
# RTF only: enable Persistent Object Store and/or Enforce deploying replicas
# across nodes, cluster mode setup. The anypoint-cli deploy/modify commands above do not expose
# these RTF deployment settings, so we PATCH them via the Application Manager
# REST API (AMC v2) after the application has been deployed/updated.
# ---------------------------------------------------------------------------

set -euo pipefail


if [ "$PERSISTENT_OBJECT_STORE" = "true" ] || [ "$DEPLOY_ACROSS_NODES" = "true" ] || [ "$CLUSTER_MODE" = "clustered" ]; then
  echo "Persistent Object Store, Deploy-Across-Nodes OR Clustered mode requested. Applying RTF deployment settings via Application Manager API..."
  
  ENV_LOWER=$(echo "$ANYPOINT_ENV" | tr '[:upper:]' '[:lower:]')
  TARGET_APP_NAME="$REPO_NAME"
  
  if [ "$ENV_NAME" = "dev" ] || [ "$ENV_NAME" = "it" ]; then
    TARGET_APP_NAME="$ENV_LOWER-$REPO_NAME"
  fi
  
  
  # RTF post-deploy settings (Persistent Object Store + Enforce deploying replicas across nodes).
  #PERSISTENT_OBJECT_STORE="${PERSISTENT_OBJECT_STORE:-}"
  #DEPLOY_ACROSS_NODES="${DEPLOY_ACROSS_NODES:-}"
  
  # Anypoint control plane base URL and org used for the Application Manager REST API.
  ANYPOINT_BASE_URL="${ANYPOINT_BASE_URL:-https://anypoint.mulesoft.com}"
  ANYPOINT_ORG="${ANYPOINT_ORG:-$BUSINESS_GROUP_ORG_ID}" 

  # 1. Extract the application/deployment id from the deploy command output.
  APP_ID=$(anypoint-cli-v4 runtime-mgr:application:list --output json | jq -r ".[] | select(.name == \"${TARGET_APP_NAME}\" and .target.targetId == \"$DEPLOYMENT_TARGET_RTF\") | .id")

  if [ -z "$APP_ID" ]; then
    echo "ERROR: Could not determine the deployment id for '$TARGET_APP_NAME'. Skipping RTF settings patch." >&2
    exit 1
  fi
  # echo "Resolved application id: $APP_ID"
 
  # 2. Fetch an access token using the connected app client id/secret.
  TOKEN=$(curl -s -X POST "${ANYPOINT_BASE_URL}/accounts/api/v2/oauth2/token" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\":\"${ANYPOINT_CLIENT_ID}\",\"client_secret\":\"${ANYPOINT_CLIENT_SECRET}\",\"grant_type\":\"client_credentials\"}" \
    | jq -r '.access_token // empty')
 
  if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to obtain an Anypoint access token." >&2
    exit 1
  fi
  # echo "Resolved access token: $TOKEN"
 
  # 3. Resolve the environment id (UUID) from the environment name/id.
  ENV_ID=$(anypoint-cli-v4 account:environment:list --output json \
    | jq -r --arg n "$ANYPOINT_ENV" '.[] | select(.name == $n or .id == $n) | .id' \
    | head -n1)   
  # echo "Resolved environment id: $ENV_ID"

  # 4. Build the patch payload for the RTF deployment settings.
  #    Values are derived from the flags so each setting reflects what was requested.
  POS_VALUE=$([ "$PERSISTENT_OBJECT_STORE" = "true" ] && echo true || echo false)

  # Enforcing replicas across nodes only applies when more than one replica is deployed.
  DAN_VALUE=$([ "$DEPLOY_ACROSS_NODES" = "true" ] && [ "${REPLICA_COUNT:-1}" -gt 1 ] 2>/dev/null && echo true || echo false)

  # Runtime cluster mode is enabled when CLUSTER_MODE is "clustered" and more than one replica is deployed.
  CLUSTERED_VALUE=$([ "$CLUSTER_MODE" = "clustered" ] && [ "${REPLICA_COUNT:-1}" -gt 1 ] 2>/dev/null && echo true || echo false)

  PATCH_PAYLOAD=$(jq -n \
    --argjson pos "$POS_VALUE" \
    --argjson dan "$DAN_VALUE" \
    --argjson clustered "$CLUSTERED_VALUE" \
    '{target:{deploymentSettings:{persistentObjectStore:$pos, enforceDeployingReplicasAcrossNodes:$dan, clustered:$clustered}}}')
  # echo "Resolved patch payload: $PATCH_PAYLOAD"

  # 5. Patch the deployment.
  HTTP_CODE=$(curl -s -o /tmp/rtf_patch_response.json -w "%{http_code}" -X PATCH \
    "${ANYPOINT_BASE_URL}/amc/application-manager/api/v2/organizations/${ANYPOINT_ORG}/environments/${ENV_ID}/deployments/${APP_ID}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PATCH_PAYLOAD")
 
  # echo "Application Manager PATCH response ($HTTP_CODE):"
  # cat /tmp/rtf_patch_response.json || true
  # echo
 
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "ERROR: Failed to apply RTF deployment settings (HTTP $HTTP_CODE)." >&2
    exit 1
  fi
 
  echo "Successfully applied Persistent Object Store and Deploy-Across-Nodes settings to '$TARGET_APP_NAME'."
fi
