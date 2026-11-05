# Every AWS call in this stack is answered by the local Floci emulator.
#
# The AWS provider needs an explicit endpoint per service: AWS_ENDPOINT_URL alone
# is not honoured by all of the provider's service clients. Credentials come from
# the lab-only profile in ../../aws/credentials, which holds a key minted by
# Floci's own IAM emulator and valid nowhere else.
provider "aws" {
  region = var.region

  profile                  = var.aws_profile
  shared_config_files      = [var.aws_config_file]
  shared_credentials_files = [var.aws_credentials_file]

  # Floci is not AWS: skip the handshakes that only a real account can satisfy.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    acm     = var.floci_endpoint
    ec2     = var.floci_endpoint
    eks     = var.floci_endpoint
    elb     = var.floci_endpoint
    elbv2   = var.floci_endpoint
    iam     = var.floci_endpoint
    logs    = var.floci_endpoint
    route53 = var.floci_endpoint
    sts     = var.floci_endpoint
  }

  default_tags {
    tags = {
      Project   = "stig-cloud-lab"
      ManagedBy = "terraform"
    }
  }
}
