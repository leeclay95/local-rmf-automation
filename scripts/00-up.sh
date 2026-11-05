#!/usr/bin/env bash
# Bring the whole lab up, from nothing or after a reboot.
#
# Safe to re-run: every step is idempotent, and Terraform reconciles whatever
# Floci changed while it was down (the k3s API server host ports and the node
# container addresses are both reassigned on a Floci restart, which is why
# stage 1 has to be applied again before the kubeconfig is rebuilt).
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB_DIR"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

say "1/8 starting Floci"
docker compose up -d
for _ in $(seq 1 60); do
  curl -fsS --max-time 5 http://localhost:4566/_floci/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 5 http://localhost:4566/_floci/health >/dev/null \
  || { echo "Floci did not become healthy" >&2; exit 1; }

say "2/8 bootstrapping the emulated IAM user"
./scripts/01-bootstrap-iam.sh

say "3/8 waiting for the EKS clusters to come back"
# Floci re-latches persisted clusters to their k3s containers on startup. On a
# cold start there is nothing to wait for and Terraform creates them in step 4.
for c in keycloak-eks stigman-eks; do
  if aws eks describe-cluster --name "$c" >/dev/null 2>&1; then
    for _ in $(seq 1 90); do
      s="$(aws eks describe-cluster --name "$c" --query 'cluster.status' --output text 2>/dev/null)"
      [ "$s" = "ACTIVE" ] && break
      [ "$s" = "FAILED" ] && { echo "$c came back FAILED" >&2; break; }
      sleep 5
    done
    echo "    $c: $(aws eks describe-cluster --name "$c" --query 'cluster.status' --output text)"
  else
    echo "    $c: not created yet"
  fi
done

say "4/8 applying AWS infrastructure (stage 1)"
# Creates the clusters on a cold start; on a restart it mostly reconciles the
# API server endpoints and the ALB target addresses Floci reassigned.
./scripts/02-apply-infra.sh -auto-approve

say "5/8 relaxing the kubelet disk-eviction threshold"
# Recreates the k3s containers, which can move their node IPs, so this has to
# happen before stage 1 is reconciled for the last time and before the
# kubeconfig is written.
python3 ./scripts/eviction_patch.py

say "6/8 reconciling endpoints, then writing the kubeconfig"
./scripts/02-apply-infra.sh -auto-approve
./scripts/03-kubeconfig.sh

say "7/8 applying Kubernetes workloads (stage 2)"
./scripts/04-apply-workloads.sh -auto-approve

say "8/8 /etc/hosts entries"
./scripts/05-hosts.sh

say "verifying"
./scripts/08-verify.sh
