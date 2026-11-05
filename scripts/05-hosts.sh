#!/usr/bin/env bash
# Point stigman.mil and keycloak.mil at the local ALB listeners.
#
# Floci's embedded DNS serves the Route53 private zone to containers, but the
# host's browser does not use it, so the host needs /etc/hosts. 127.0.0.1 is
# correct here: Docker publishes Floci's :443 on the host, and the ALB picks the
# right load balancer from the TLS SNI name.
#
# Run with `--remove` to take the entries back out.
set -euo pipefail

MARKER="# stig-cloud-lab"
HOSTS=/etc/hosts

if [ "${1:-}" = "--remove" ]; then
  sudo sed -i "/$MARKER\$/d" "$HOSTS"
  echo "==> removed stig-cloud-lab entries from $HOSTS"
  grep -E 'stigman\.mil|keycloak\.mil' "$HOSTS" || echo "    none left"
  exit 0
fi

sudo sed -i "/$MARKER\$/d" "$HOSTS"
sudo tee -a "$HOSTS" >/dev/null <<EOF
127.0.0.1 stigman.mil $MARKER
127.0.0.1 keycloak.mil $MARKER
EOF

echo "==> $HOSTS now contains:"
grep -E 'stigman\.mil|keycloak\.mil' "$HOSTS"
