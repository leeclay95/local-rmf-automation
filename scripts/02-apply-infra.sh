#!/usr/bin/env bash
# Stage 1: apply the AWS layer (VPC, IAM, EKS, ACM, ALBs, Route53).
#
# floci_network_ip is discovered rather than hardcoded: it is Floci's address on
# the lab Docker network, which the Route53 private zone points the hostnames at
# so pods inside the clusters can reach the ALB listeners. See terraform/01-infra/06-dns.tf.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

NETWORK="$LAB_NETWORK"
FLOCI_IP="$(docker inspect floci \
  --format "{{ (index .NetworkSettings.Networks \"$NETWORK\").IPAddress }}")"
[ -n "$FLOCI_IP" ] || { echo "could not find floci's IP on $NETWORK" >&2; exit 1; }
echo "==> floci is $FLOCI_IP on $NETWORK"

cd "$LAB_DIR/terraform/01-infra"
terraform init -input=false
terraform apply -input=false -var "floci_network_ip=$FLOCI_IP" "$@"
