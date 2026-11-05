#!/usr/bin/env bash
# Tear the lab down.
#
#   ./scripts/99-down.sh            stop the containers, keep all state
#   ./scripts/99-down.sh --destroy  terraform destroy, then stop
#   ./scripts/99-down.sh --purge    destroy, stop, and delete Floci's state,
#                                   the k3s data volumes, certs and kubeconfig
#
# Nothing here touches your real ~/.aws or ~/.kube files.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB_DIR"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

MODE="${1:-stop}"

if [ "$MODE" = "--destroy" ] || [ "$MODE" = "--purge" ]; then
  echo "==> terraform destroy: workloads"
  (cd terraform/02-workloads && terraform destroy -auto-approve) || true

  echo "==> terraform destroy: infrastructure"
  FLOCI_IP="$(docker inspect floci \
    --format "{{ (index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress }}" \
    2>/dev/null || echo 127.0.0.1)"
  (cd terraform/01-infra && terraform destroy -auto-approve \
      -var "floci_network_ip=$FLOCI_IP") || true
fi

echo "==> removing /etc/hosts entries"
./scripts/05-hosts.sh --remove || true

echo "==> stopping Floci"
docker compose down

# Floci starts the k3s containers itself, so compose does not own them.
echo "==> removing leftover Floci containers"
docker ps -aq --filter label=floci=true | xargs -r docker rm -f

if [ "$MODE" = "--purge" ]; then
  echo "==> deleting Floci state and k3s data volumes"
  docker volume ls -q --filter label=floci=true | xargs -r docker volume rm -f
  docker volume ls -q | grep -E '^floci-' | xargs -r docker volume rm -f || true
  rm -rf data/* certs/lab-ca.crt kubeconfig
  echo "==> resetting the lab credentials file to its bootstrap state"
  cat > aws/credentials <<'CRD'
# Emulated credentials only — minted by Floci's IAM service, valid nowhere else.
# scripts/01-bootstrap-iam.sh rewrites [floci-lab] with the real emulated key.
[floci-bootstrap]
aws_access_key_id = test
aws_secret_access_key = test

[floci-lab]
aws_access_key_id = test
aws_secret_access_key = test
CRD
  chmod 600 aws/credentials
  echo
  echo "Purged. Terraform state files are kept; delete them too if you want a"
  echo "completely clean slate:"
  echo "  rm -f terraform/0*/terraform.tfstate*"
fi

echo
echo "done ($MODE)"
