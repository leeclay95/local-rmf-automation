#!/usr/bin/env bash
# Stage 2: deploy Keycloak, MySQL and the STIG Manager API into the clusters.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

cd "$LAB_DIR/terraform/02-workloads"
terraform init -input=false
terraform apply -input=false "$@"
