output "keycloak_cluster_name" {
  value = aws_eks_cluster.keycloak.name
}

output "stigman_cluster_name" {
  value = aws_eks_cluster.stigman.name
}

output "keycloak_cluster_endpoint" {
  description = "k3s API server, published on the host by Docker."
  value       = aws_eks_cluster.keycloak.endpoint
}

output "stigman_cluster_endpoint" {
  value = aws_eks_cluster.stigman.endpoint
}

output "keycloak_node_ip" {
  description = "Address the keycloak ALB forwards to."
  value       = one(data.aws_instances.keycloak_node.private_ips)
}

output "stigman_node_ip" {
  value = one(data.aws_instances.stigman_node.private_ips)
}

output "keycloak_node_port" {
  value = var.keycloak_node_port
}

output "stigman_node_port" {
  value = var.stigman_node_port
}

output "keycloak_host" {
  value = var.keycloak_host
}

output "stigman_host" {
  value = var.stigman_host
}

output "keycloak_alb_dns_name" {
  value = aws_lb.app["keycloak"].dns_name
}

output "stigman_alb_dns_name" {
  value = aws_lb.app["stigman"].dns_name
}

output "keycloak_certificate_arn" {
  value = aws_acm_certificate.leaf["keycloak"].arn
}

output "stigman_certificate_arn" {
  value = aws_acm_certificate.leaf["stigman"].arn
}

output "ca_certificate_path" {
  description = "Trust this one file and both hostnames verify."
  value       = local_file.ca_cert.filename
}

output "oidc_issuer" {
  description = "Value ../02-workloads passes as STIGMAN_OIDC_PROVIDER."
  value       = "https://${var.keycloak_host}/realms/stigman"
}

output "lbc_role_arns" {
  value = { for k, r in aws_iam_role.lbc : k => r.arn }
}

output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "lab_user_arn" {
  value = data.aws_caller_identity.current.arn
}

output "urls" {
  value = {
    stigman  = "https://${var.stigman_host}"
    keycloak = "https://${var.keycloak_host}"
  }
}

output "keycloak_cluster_ca" {
  description = "Base64 PEM CA for the k3s API server, for the kubernetes provider."
  value       = aws_eks_cluster.keycloak.certificate_authority[0].data
}

output "stigman_cluster_ca" {
  value = aws_eks_cluster.stigman.certificate_authority[0].data
}

output "region" {
  value = var.region
}

output "aws_profile" {
  value = var.aws_profile
}

output "floci_network_ip" {
  description = "Floci's address on the lab Docker network; the DNS answer for both hosts."
  value       = var.floci_network_ip
}
