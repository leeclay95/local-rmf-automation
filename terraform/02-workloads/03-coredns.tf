###############################################################################
# CoreDNS — teach each cluster to resolve the .mil lab hostnames.
#
# Floci answers the Route53 private zone from its embedded DNS server, and it is
# the k3s container's first resolver. But the pods never get there: the node's
# /etc/resolv.conf points at Docker's embedded resolver on 127.0.0.11, and k3s
# refuses to hand CoreDNS a loopback nameserver, substituting a public resolver
# instead. So a pod asking for keycloak.mil ends up at 8.8.8.8 and gets
# NXDOMAIN, which surfaces as STIG Manager logging
#   {"component":"auth","type":"discovery","data":{"success":false,...}}
# and never becoming ready.
#
# k3s's packaged Corefile ends with `import /etc/coredns/custom/*.server`, and
# its CoreDNS Deployment already mounts the optional `coredns-custom` ConfigMap
# at that path. Adding a server block for the mil zone therefore needs no change
# to the managed Corefile and survives k3s's addon reconciliation. CoreDNS's
# `reload` plugin picks the file up within about 30 seconds; if you want it
# immediately, `kubectl rollout restart deployment/coredns -n kube-system`.
###############################################################################
locals {
  mil_server_block = <<-EOT
    mil:53 {
        errors
        cache 30
        forward . ${local.infra.floci_network_ip}
    }
  EOT
}

resource "kubernetes_config_map" "coredns_custom_keycloak" {
  provider = kubernetes.keycloak

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
  }

  data = {
    "mil.server" = local.mil_server_block
  }
}

resource "kubernetes_config_map" "coredns_custom_stigman" {
  provider = kubernetes.stigman

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
  }

  data = {
    "mil.server" = local.mil_server_block
  }
}
