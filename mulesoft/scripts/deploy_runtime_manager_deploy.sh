#!/usr/bin/env bash
# Deploy or Update Mule Application Script
# Deploys a new Mule application or updates an existing one in Anypoint Runtime Manager.
#
# Variables are passed directly from the workflow step (needs.initialization.outputs.*).
# Required: ENV_NAME, REPO_NAME, PROJECT_VERSION, BUSINESS_GROUP_ORG_ID,
#   ANYPOINT_ENV, ANYPOINT_MULE_KEY, ANYPOINT_PLATFORM_CLIENT_ID, ANYPOINT_PLATFORM_CLIENT_SECRET,
#   SPLUNK_TOKEN, SPLUNK_URL, SPLUNK_INDEX, DEPLOYMENT_TARGET_CH2, RUNTIME_VERSION, RELEASE_CHANNEL,
#   REPLICA_SIZE, REPLICA_COUNT, CLUSTER_MODE,
#   ANYPOINT_FWD_SSL_SESSION, ANYPOINT_LAST_MILE_SECURITY, VANITY_INTERNAL_DOMAIN
# Optional: APP_URI_PATH, RELEASE_TAG (for preprod - format: prefix-version)
set -euo pipefail

ENV_LOWER=$(echo "$ANYPOINT_ENV" | tr '[:upper:]' '[:lower:]')

# Extract Artifact/Asset version used to fetch from exchange
if [ "$ENV_NAME" = "preprod" ] && [ -n "${RELEASE_TAG:-}" ]; then
  RELEASE_VERSION="${RELEASE_TAG#*-}"
elif [ "$ENV_NAME" = "prod" ] || [ "$ENV_NAME" = "stage" ]; then
  RELEASE_VERSION="$BASELINE_TAG"
else
  # Default fallback for dev, local, or when tags are missing
  RELEASE_VERSION="$PROJECT_VERSION"
fi


TARGET_APP_NAME="$REPO_NAME"
if [ "$ENV_NAME" = "dev" ] || [ "$ENV_NAME" = "it" ]; then
  TARGET_APP_NAME="$ENV_LOWER-$REPO_NAME"
fi

#echo "APP URI PATH : ${APP_URI_PATH:-}"
APP_URL_PATH=$( [ -n "${APP_URI_PATH:-}" ] && echo "${APP_URI_PATH}" || echo "/${TARGET_APP_NAME}" )
PUBLIC_ENDPOINTS="${VANITY_INTERNAL_DOMAIN:-}"
if [ -n "$PUBLIC_ENDPOINTS" ] && [ "$PUBLIC_ENDPOINTS" != "null" ]; then
  PUBLIC_ENDPOINTS="${PUBLIC_ENDPOINTS}${APP_URL_PATH}"
  #echo "PUBLIC_ENDPOINTS: ${PUBLIC_ENDPOINTS}${APP_URL_PATH}"
fi

OBJECTSTORE=$( [ -n "${OBJECTSTORE_V2:-}" ] && echo "${OBJECTSTORE_V2}" || echo "no-objectStoreV2" )

echo "Listing applications in environment: Sandbox for app: '$TARGET_APP_NAME'"
APP_ID=$(anypoint-cli-v4 runtime-mgr:application:list --environment "Sandbox" --output json | jq -r ".[] | select(.name == \"${TARGET_APP_NAME}\") | .id")

if [ -n "$APP_ID" ]; then
  echo "Application '$TARGET_APP_NAME' already exists. Updating..."
  anypoint-cli-v4 runtime-mgr:application:modify "$APP_ID" \
    --artifactId "$PROJECT_ARTIFACTID" \
    --assetVersion "$RELEASE_VERSION" \
    --groupId "$BUSINESS_GROUP_ORG_ID" \
    --replicaSize "$REPLICA_SIZE" \
    --replicas "$REPLICA_COUNT" \
    --$CLUSTER_MODE \
    --$OBJECTSTORE \
    --$ANYPOINT_FWD_SSL_SESSION \
    --$ANYPOINT_LAST_MILE_SECURITY \
    --publicEndpoints "$PUBLIC_ENDPOINTS" \
    --secureProperty mule.key:"$ANYPOINT_MULE_KEY" \
    --secureProperty anypoint.platform.client_id:"$ANYPOINT_PLATFORM_CLIENT_ID" \
    --secureProperty anypoint.platform.client_secret:"$ANYPOINT_PLATFORM_CLIENT_SECRET" \
    --secureProperty splunk.token:"$SPLUNK_TOKEN" \
    --property splunk.url:"$SPLUNK_URL" \
    --property splunk.source:"$TARGET_APP_NAME" \
    --property splunk.index:"$SPLUNK_INDEX" \
    --property mule.env:"$ENV_LOWER" \
    --property env:"$ENV_LOWER"
else
  echo "Application '$TARGET_APP_NAME' not found. Deploying new application..."
  anypoint-cli-v4 runtime-mgr:application:deploy "$TARGET_APP_NAME" "$DEPLOYMENT_TARGET_CH2" "$RUNTIME_VERSION" "$PROJECT_ARTIFACTID" \
    --assetVersion "$RELEASE_VERSION" \
    --groupId "$BUSINESS_GROUP_ORG_ID" \
    --replicaSize "$REPLICA_SIZE" \
    --replicas "$REPLICA_COUNT" \
    --releaseChannel "$RELEASE_CHANNEL" \
    --$CLUSTER_MODE \
    --$OBJECTSTORE \
    --$ANYPOINT_FWD_SSL_SESSION \
    --$ANYPOINT_LAST_MILE_SECURITY \
    --publicEndpoints "$PUBLIC_ENDPOINTS" \
    --secureProperty mule.key:"$ANYPOINT_MULE_KEY" \
    --secureProperty anypoint.platform.client_id:"$ANYPOINT_PLATFORM_CLIENT_ID" \
    --secureProperty anypoint.platform.client_secret:"$ANYPOINT_PLATFORM_CLIENT_SECRET" \
    --secureProperty splunk.token:"$SPLUNK_TOKEN" \
    --property splunk.url:"$SPLUNK_URL" \
    --property splunk.source:"$TARGET_APP_NAME" \
    --property splunk.index:"$SPLUNK_INDEX" \
    --property mule.env:"$ENV_LOWER" \
    --property env:"$ENV_LOWER"
fi