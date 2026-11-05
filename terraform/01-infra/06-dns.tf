###############################################################################
# Route53 — so that pods resolve the same hostnames the browser uses.
#
# This is the piece that makes the OIDC flow work. STIG Manager's API validates
# tokens against STIGMAN_OIDC_PROVIDER, and the browser is redirected to the
# same issuer URL. Both must be https://keycloak.mil/realms/stigman, so the
# stigman-api pod has to resolve keycloak.mil too.
#
# Floci answers private hosted zone records from its own embedded DNS server,
# and the k3s cluster containers use Floci as their resolver. Pointing the
# records at Floci's address on the lab Docker network therefore sends pod
# traffic for keycloak.mil to Floci:443, where the ALB listener picks the
# keycloak load balancer by SNI.
#
# The host's browser does not use this zone — it goes through /etc/hosts. See
# scripts/05-hosts.sh.
###############################################################################
resource "aws_route53_zone" "mil" {
  name    = "mil"
  comment = "stig-cloud-lab private zone"

  vpc {
    vpc_id = aws_vpc.lab.id
  }
}

resource "aws_route53_record" "app" {
  for_each = local.albs

  zone_id = aws_route53_zone.mil.zone_id
  name    = each.value.host
  type    = "A"
  ttl     = 60
  records = [var.floci_network_ip]
}
