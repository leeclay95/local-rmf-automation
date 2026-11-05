output "urls" {
  value = local.infra.urls
}

output "node_ports" {
  value = {
    keycloak = local.infra.keycloak_node_port
    stigman  = local.infra.stigman_node_port
  }
}

output "oidc_issuer" {
  value = local.infra.oidc_issuer
}
