#!/usr/bin/env bash
# Pin the stig-manager Keycloak client to the lab's hostname.
#
# The nuwcdivnpt/stig-manager-auth image ships the stigman realm with the
# stig-manager client already wide open (redirectUris ["http://*","https://*"],
# webOrigins ["*"]), so the login flow works without this. The original EKS lab
# had to widen them by hand in the admin console because it was reaching the
# client over an ALB DNS name it could not predict; here the hostname is fixed,
# so this narrows them instead of widening them.
#
# Idempotent: re-running makes no change once the values match.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

HOSTNAME_URL="https://$(cd "$LAB_DIR/terraform/01-infra" && terraform output -raw stigman_host)"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-Pa55w0rd}"

POD="$(kubectl --context keycloak get pod -n keycloak -l app=keycloak \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { echo "no running keycloak pod" >&2; exit 1; }
echo "==> keycloak pod: $POD"

run() { kubectl --context keycloak exec -n keycloak "$POD" -- sh -c "$1"; }

LOGIN="/opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user '$ADMIN_USER' --password '$ADMIN_PASS' >/dev/null 2>&1"

echo "==> locating the stig-manager client"
CLIENT_ID="$(run "$LOGIN; /opt/keycloak/bin/kcadm.sh get clients -r stigman \
  --query clientId=stig-manager --fields id 2>/dev/null" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
echo "    id: $CLIENT_ID"

echo "==> setting redirect URIs and web origins to $HOSTNAME_URL"
run "$LOGIN; /opt/keycloak/bin/kcadm.sh update clients/$CLIENT_ID -r stigman \
  -s 'redirectUris=[\"$HOSTNAME_URL/*\"]' \
  -s 'webOrigins=[\"$HOSTNAME_URL\"]' 2>&1" || true

echo "==> now:"
run "$LOGIN; /opt/keycloak/bin/kcadm.sh get clients/$CLIENT_ID -r stigman \
  --fields clientId,redirectUris,webOrigins 2>/dev/null"
