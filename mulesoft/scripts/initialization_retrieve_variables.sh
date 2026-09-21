#!/usr/bin/env bash
# Retrieve Variables Script
# Extracts environment-specific configuration from JSON maps and outputs to GITHUB_OUTPUT.
# Used by the INITIALIZATION job in CICD workflows.
#
# Required environment variables:
#   ORG_ID, ENV_NAME
#   AWS_ROLE_ARN_MAP, SPLUNK_TOKEN_MAP, ANYPOINT_MULE_KEY_MAP
#   ANYPOINT_PLATFORM_CLIENT_ID_MAP, ANYPOINT_PLATFORM_CLIENT_SECRET_MAP
#   CLUSTER_MODE_MAP, DEPLOYMENT_TARGET_CH2_MAP, REPLICA_COUNT_MAP, REPLICA_SIZE_MAP
#   SPLUNK_INDEX_MAP, ANYPOINT_ENV_MAP, VANITY_INTERNAL_DOMAIN_MAP
#   ANYPOINT_FWD_SSL_SESSION, ANYPOINT_LAST_MILE_SECURITY, SPLUNK_URL
#   RUNTIME_VERSION, RELEASE_CHANNEL, STAGE_DEPLOYMENT_SKIP
#   APP_URI_PATH, GH_USER_EMAIL, GH_USER_NAME (optional)

set -euo pipefail

# Parse mapped variables using jq
ANYPOINT_PLATFORM_CLIENT_ID=$(echo "$ANYPOINT_PLATFORM_CLIENT_ID_MAP" | tr -d '\r\n' | jq -r --arg id "$ORG_ID" --arg env "$ENV_NAME" '.[$id][$env]')
ANYPOINT_PLATFORM_CLIENT_SECRET=$(echo "$ANYPOINT_PLATFORM_CLIENT_SECRET_MAP" | tr -d '\r\n' | jq -r --arg id "$ORG_ID" --arg env "$ENV_NAME" '.[$id][$env]')
AWS_ROLE_ARN=$(echo "$AWS_ROLE_ARN_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
SPLUNK_TOKEN=$(echo "$SPLUNK_TOKEN_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
ANYPOINT_MULE_KEY=$(echo "$ANYPOINT_MULE_KEY_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
CLUSTER_MODE=$(echo "$CLUSTER_MODE_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
DEPLOYMENT_TARGET_CH2=$(echo "$DEPLOYMENT_TARGET_CH2_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
REPLICA_COUNT=$(echo "$REPLICA_COUNT_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
REPLICA_SIZE=$(echo "$REPLICA_SIZE_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
SPLUNK_INDEX=$(echo "$SPLUNK_INDEX_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')
ANYPOINT_ENV=$(echo "$ANYPOINT_ENV_MAP" | tr -d '\r\n' | jq -r --arg id "$ORG_ID" --arg env "$ENV_NAME" '.[$id][$env]')
VANITY_INTERNAL_DOMAIN=$(echo "$VANITY_INTERNAL_DOMAIN_MAP" | jq -r 'to_entries | map(select(.key == "'"$ENV_NAME"'")) | .[].value')

# Write to GITHUB_OUTPUT (set by GitHub Actions runner)
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

{
  echo "env_name=$ENV_NAME"
  echo "ANYPOINT_PLATFORM_CLIENT_ID=$ANYPOINT_PLATFORM_CLIENT_ID"
  echo "ANYPOINT_PLATFORM_CLIENT_SECRET=$ANYPOINT_PLATFORM_CLIENT_SECRET"
  echo "AWS_ROLE_ARN=$AWS_ROLE_ARN"
  echo "SPLUNK_TOKEN=$SPLUNK_TOKEN"
  echo "ANYPOINT_MULE_KEY=$ANYPOINT_MULE_KEY"
  echo "CLUSTER_MODE=$CLUSTER_MODE"
  echo "DEPLOYMENT_TARGET_CH2=$DEPLOYMENT_TARGET_CH2"
  echo "REPLICA_COUNT=$REPLICA_COUNT"
  echo "REPLICA_SIZE=$REPLICA_SIZE"
  echo "SPLUNK_INDEX=$SPLUNK_INDEX"
  echo "ANYPOINT_ENV=$ANYPOINT_ENV"
  echo "VANITY_INTERNAL_DOMAIN=$VANITY_INTERNAL_DOMAIN"
  echo "OBJECTSTORE_V2=$OBJECTSTORE_V2"
  echo "ANYPOINT_FWD_SSL_SESSION=${ANYPOINT_FWD_SSL_SESSION:-}"
  echo "ANYPOINT_LAST_MILE_SECURITY=${ANYPOINT_LAST_MILE_SECURITY:-}"
  echo "SPLUNK_URL=${SPLUNK_URL:-}"
  echo "RUNTIME_VERSION=${RUNTIME_VERSION:-}"
  echo "RELEASE_CHANNEL=${RELEASE_CHANNEL:-}"
  echo "STAGE_DEPLOYMENT_SKIP=${STAGE_DEPLOYMENT_SKIP:-}"
  echo "APP_URI_PATH=${APP_URI_PATH:-}"
  echo "GH_USER_EMAIL=${GH_USER_EMAIL:-}"
  echo "GH_USER_NAME=${GH_USER_NAME:-}"
  echo "SONAR_SOURCES=${SONAR_SOURCES:-}"
  echo "SONAR_HOST_URL=${SONAR_HOST_URL:-}"
  echo "SONAR_TOKEN=${SONAR_TOKEN:-}"
  echo "SKIP_CH2_DEPLOY=${SKIP_CH2_DEPLOY:-false}"
} >> "$GITHUB_OUTPUT"
