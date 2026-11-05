###############################################################################
# TLS — a lab CA, two leaf certificates, imported into ACM.
#
# The original lab imported self-signed certs into ACM by hand (README step 4).
# Here Terraform generates them, so the hostnames in the certificate always
# match var.stigman_host / var.keycloak_host and there is one CA to trust in the
# browser instead of two unrelated self-signed leaves.
#
# Floci's ACM holds the real key material and its ALB listeners terminate TLS
# with it, selecting the certificate by SNI. That is what lets both load
# balancers share port 443.
###############################################################################
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  is_ca_certificate     = true
  validity_period_hours = 8760 # 1 year

  subject {
    common_name  = "STIG Cloud Lab Root CA"
    organization = "stig-cloud-lab"
    country      = "US"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

locals {
  leaf_hosts = {
    stigman  = var.stigman_host
    keycloak = var.keycloak_host
  }
}

resource "tls_private_key" "leaf" {
  for_each = local.leaf_hosts

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "leaf" {
  for_each = local.leaf_hosts

  private_key_pem = tls_private_key.leaf[each.key].private_key_pem

  subject {
    common_name  = each.value
    organization = "stig-cloud-lab"
  }

  dns_names = [each.value]
}

resource "tls_locally_signed_cert" "leaf" {
  for_each = local.leaf_hosts

  cert_request_pem   = tls_cert_request.leaf[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "leaf" {
  for_each = local.leaf_hosts

  private_key       = tls_private_key.leaf[each.key].private_key_pem
  certificate_body  = tls_locally_signed_cert.leaf[each.key].cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem

  tags = { Name = each.value }
}

# Written out so the browser, and `curl --cacert`, have one file to trust.
resource "local_file" "ca_cert" {
  content         = tls_self_signed_cert.ca.cert_pem
  filename        = "${path.module}/../../certs/lab-ca.crt"
  file_permission = "0644"
}
