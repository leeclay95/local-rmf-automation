#!/usr/bin/env bash
# Relax the kubelet disk-eviction threshold on the k3s cluster containers.
#
# Floci pins nodefs.available<10%, which on a large host disk is several GB and
# makes kubelet evict pods and taint the node while there is still plenty of
# room. This rewrites it to an absolute 1Gi. See scripts/eviction_patch.py for
# why it has to recreate the containers to do that.
#
# Safe to re-run. Run it again after `floci restart`, `docker compose restart`,
# or anything else that makes Floci rebuild a cluster container.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

python3 "$LAB_DIR/scripts/eviction_patch.py" "$@"

echo
echo "==> waiting for both API servers to answer"
for ctx in keycloak stigman; do
  for _ in $(seq 1 60); do
    if kubectl --context "$ctx" get --raw /readyz >/dev/null 2>&1; then
      echo "    $ctx ready"
      break
    fi
    sleep 3
  done
done

echo
echo "==> node conditions"
for ctx in keycloak stigman; do
  printf '    %-9s ' "$ctx"
  kubectl --context "$ctx" get nodes \
    -o jsonpath='{range .items[*].status.conditions[?(@.type=="DiskPressure")]}DiskPressure={.status}{end}' 2>/dev/null
  echo
done
