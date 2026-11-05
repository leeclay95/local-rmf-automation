#!/usr/bin/env bash
# Write the lab kubeconfig for both clusters.
#
# `aws eks update-kubeconfig` wires `aws eks get-token` in as an exec credential
# plugin, but the plugin inherits the caller's environment. Without pinning the
# lab's env into the exec block, kubectl would shell out to `aws` with whatever
# profile happened to be active and sign the token with the wrong key. So we
# pin the lab's isolated config/credentials files onto each context.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

declare -A CLUSTERS=( [keycloak-eks]=keycloak [stigman-eks]=stigman )

rm -f "$KUBECONFIG"
for name in "${!CLUSTERS[@]}"; do
  alias_name="${CLUSTERS[$name]}"
  echo "==> $name -> context '$alias_name'"
  aws eks update-kubeconfig --name "$name" --alias "$alias_name" >/dev/null

  user="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$alias_name\")].context.user}")"
  kubectl config set-credentials "$user" \
    --exec-env="AWS_CONFIG_FILE=$AWS_CONFIG_FILE" \
    --exec-env="AWS_SHARED_CREDENTIALS_FILE=$AWS_SHARED_CREDENTIALS_FILE" \
    --exec-env="AWS_PROFILE=floci-lab" \
    --exec-env="AWS_REGION=$AWS_REGION" \
    --exec-env="AWS_EC2_METADATA_DISABLED=true" >/dev/null
done

chmod 600 "$KUBECONFIG"
echo "==> contexts"
kubectl config get-contexts
