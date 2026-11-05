#!/usr/bin/env bash
# End-to-end check of the whole lab, bottom layer first.
#
# Each step prints PASS or FAIL and the README explains what a FAIL at that
# step means. Exits non-zero if anything failed.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

CA="$LAB_DIR/certs/lab-ca.crt"
FAILED=0
STEP=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
step() { STEP=$((STEP + 1)); printf '\n[%d] %s\n' "$STEP" "$1"; }

###############################################################################
step "Floci emulator reachable"
if curl -fsS --max-time 10 http://localhost:4566/_floci/health >/dev/null 2>&1; then
  pass "http://localhost:4566 answering"
else
  fail "Floci not reachable on :4566 — run 'docker compose up -d'"
fi

###############################################################################
step "AWS credentials are the emulated ones"
ident="$(aws sts get-caller-identity --output json 2>/dev/null)"
if [ "$(jq -r .Account <<<"$ident" 2>/dev/null)" = "000000000000" ]; then
  pass "account 000000000000 ($(jq -r .Arn <<<"$ident"))"
else
  fail "not talking to Floci's IAM — did you source env.sh?"
fi

###############################################################################
step "Both EKS clusters ACTIVE"
for c in keycloak-eks stigman-eks; do
  s="$(aws eks describe-cluster --name "$c" --query 'cluster.status' --output text 2>/dev/null)"
  [ "$s" = "ACTIVE" ] && pass "$c $s" || fail "$c is '$s' (want ACTIVE)"
done

###############################################################################
step "Kubernetes API reachable with IAM auth"
for ctx in keycloak stigman; do
  if kubectl --context "$ctx" get --raw /readyz >/dev/null 2>&1; then
    pass "context '$ctx' authenticated"
  else
    fail "context '$ctx' unauthorized or unreachable — run scripts/03-kubeconfig.sh"
  fi
done

###############################################################################
step "Nodes Ready and not under disk pressure"
for ctx in keycloak stigman; do
  ready="$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  disk="$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null)"
  [ "$ready" = "True" ] && pass "$ctx node Ready" || fail "$ctx node Ready=$ready"
  if [ "$disk" = "False" ]; then
    pass "$ctx DiskPressure=False"
  else
    fail "$ctx DiskPressure=$disk — run scripts/06-patch-eviction.sh"
  fi
done

###############################################################################
step "Workload pods running"
check_pod() {
  local ctx=$1 ns=$2 label=$3
  local ready
  ready="$(kubectl --context "$ctx" get pods -n "$ns" -l "$label" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null)"
  if [[ "$ready" == *true* ]]; then
    pass "$ctx/$ns $label ready"
  else
    fail "$ctx/$ns $label not ready (ready='$ready')"
  fi
}
check_pod keycloak keycloak app=keycloak
check_pod stigman stigman app=mysql
check_pod stigman stigman app=stigman-api

###############################################################################
step "MySQL volume bound"
phase="$(kubectl --context stigman get pvc mysql-pvc -n stigman \
  -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$phase" = "Bound" ] && pass "mysql-pvc Bound" || fail "mysql-pvc is '$phase'"

###############################################################################
step "ALB target groups healthy"
# A target group registers the k3s node by IP (target_type = "ip"). Docker
# reassigns those addresses whenever the containers are recreated, so the
# registration can outlive the address it points at. That shows up as an
# unhealthy target and a 503 from the ALB, with nothing wrong inside the
# cluster -- so compare the registration against the live address and say so.
for tg in keycloak-tg stigman-tg; do
  cluster="${tg%-tg}-eks"
  arn="$(aws elbv2 describe-target-groups --names "$tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  read -r target state <<<"$(aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[0].[Target.Id,TargetHealth.State]' --output text 2>/dev/null)"
  live="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${cluster}-node" \
    --query 'Reservations[].Instances[].PrivateIpAddress' --output text 2>/dev/null)"
  if [ "$state" = "healthy" ]; then
    pass "$tg -> $target $state"
  elif [ -n "$live" ] && [ "$target" != "$live" ]; then
    fail "$tg -> $target is stale; ${cluster}-node is now $live — run scripts/02-apply-infra.sh -auto-approve"
  else
    fail "$tg -> $target is '$state' (want healthy)"
  fi
done

###############################################################################
step "/etc/hosts entries present"
for h in stigman.mil keycloak.mil; do
  grep -qE "^[^#]*\b$h\b" /etc/hosts \
    && pass "$h in /etc/hosts" \
    || fail "$h missing — run scripts/05-hosts.sh"
done

###############################################################################
step "HTTPS through the ALB, certificate verified by the lab CA"
for url in https://keycloak.mil/realms/stigman https://stigman.mil/; do
  code="$(curl -s --cacert "$CA" --max-time 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
  [ "$code" = "200" ] && pass "$url -> $code" || fail "$url -> $code (want 200)"
done

###############################################################################
step "Pods resolve keycloak.mil (CoreDNS override)"
pod="$(kubectl --context stigman get pod -n stigman -l app=stigman-api \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$pod" ] && kubectl --context stigman exec -n stigman "$pod" -- \
     node -e 'require("dns").resolve4("keycloak.mil",(e,a)=>process.exit(e?1:0))' 2>/dev/null; then
  pass "stigman-api resolves keycloak.mil"
else
  fail "stigman-api cannot resolve keycloak.mil — check the coredns-custom ConfigMap"
fi

###############################################################################
step "Browser is pointed at the right OIDC issuer"
# /js/Env.js is what the UI actually reads to decide where to send you to log
# in. Asked live rather than grepped out of the API log, where a successful
# discovery line scrolls away.
want="$(cd "$LAB_DIR/terraform/01-infra" && terraform output -raw oidc_issuer 2>/dev/null)"
authority="$(curl -s --cacert "$CA" --max-time 20 https://stigman.mil/js/Env.js 2>/dev/null \
  | grep -oE 'authority: *"[^"]+"' | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [ -n "$want" ] && [ "$authority" = "$want" ]; then
  pass "authority = $authority"
else
  fail "authority is '$authority' (want '$want')"
fi

###############################################################################
step "Full OIDC login: token from Keycloak accepted by the API"
scopes="openid stig-manager:stig stig-manager:stig:read stig-manager:collection"
scopes="$scopes stig-manager:user stig-manager:user:read stig-manager:op stig-manager:op:read"
token="$(curl -s --cacert "$CA" --max-time 20 \
  -d client_id=stig-manager -d username=admin -d password=password \
  -d grant_type=password --data-urlencode "scope=$scopes" \
  https://keycloak.mil/realms/stigman/protocol/openid-connect/token 2>/dev/null \
  | jq -r '.access_token // empty')"
if [ -z "$token" ]; then
  fail "Keycloak would not issue a token for admin/password"
else
  pass "token issued ($(( ${#token} )) chars)"
  who="$(curl -s --cacert "$CA" --max-time 20 -H "Authorization: Bearer $token" \
    https://stigman.mil/api/user 2>/dev/null | jq -r '.username // empty')"
  [ "$who" = "admin" ] && pass "GET /api/user -> $who" \
    || fail "API did not accept the token (username='$who')"
fi

###############################################################################
printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mall %d checks passed\033[0m\n' "$STEP"
  printf '  STIG Manager  https://stigman.mil   (admin / password)\n'
  printf '  Keycloak      https://keycloak.mil  (admin / Pa55w0rd)\n'
  exit 0
fi
printf '\033[31m%d check(s) failed\033[0m — see the Troubleshooting table in README.md\n' "$FAILED"
exit 1
