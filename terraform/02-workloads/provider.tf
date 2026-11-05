###############################################################################
# Stage 2 reads stage 1's state rather than duplicating cluster coordinates.
#
# This is a separate root module on purpose: the kubernetes provider has to be
# configured from the cluster's API endpoint and CA, which do not exist until
# stage 1 has run. A single apply would need those values at plan time and fail
# on a clean checkout.
###############################################################################
data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../01-infra/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  # kubectl and the provider both authenticate the way real EKS does: the token
  # is a SigV4-presigned STS GetCallerIdentity request that Floci's webhook
  # verifies against the lab IAM user's key. The env block pins the lab-only
  # credential files so the exec plugin cannot pick up ~/.aws.
  exec_env = {
    AWS_CONFIG_FILE             = abspath("${path.module}/../../aws/config")
    AWS_SHARED_CREDENTIALS_FILE = abspath("${path.module}/../../aws/credentials")
    AWS_PROFILE                 = local.infra.aws_profile
    AWS_REGION                  = local.infra.region
    AWS_EC2_METADATA_DISABLED   = "true"
  }
}

provider "kubernetes" {
  alias = "keycloak"

  host                   = local.infra.keycloak_cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.keycloak_cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.keycloak_cluster_name]
    env         = local.exec_env
  }
}

provider "kubernetes" {
  alias = "stigman"

  host                   = local.infra.stigman_cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.stigman_cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.stigman_cluster_name]
    env         = local.exec_env
  }
}
