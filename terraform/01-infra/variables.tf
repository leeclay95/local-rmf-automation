variable "region" {
  description = "Region to emulate. Floci derives the cluster AZ as <region>a."
  type        = string
  default     = "us-east-2"
}

variable "floci_endpoint" {
  description = "Floci AWS API endpoint."
  type        = string
  default     = "http://localhost:4566"
}

variable "aws_profile" {
  description = "Profile in the lab-only credentials file."
  type        = string
  default     = "floci-lab"
}

variable "aws_config_file" {
  description = "Lab-only AWS config file (never ~/.aws/config)."
  type        = string
  default     = "../../aws/config"
}

variable "aws_credentials_file" {
  description = "Lab-only AWS credentials file (never ~/.aws/credentials)."
  type        = string
  default     = "../../aws/credentials"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Matches the original EKS lab."
  type        = string
  default     = "10.100.0.0/16"
}

variable "cluster_version" {
  description = "Kubernetes version for both clusters."
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = <<-EOT
    Instance type for the node group. Floci turns this into the CPU and memory
    ceiling of the k3s container, so it is a real constraint on this host, not
    just metadata. Two clusters at t3.medium = 2 vCPU / 4 GiB each.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "stigman_host" {
  description = "Hostname the STIG Manager UI is reached on."
  type        = string
  default     = "stigman.mil"
}

variable "keycloak_host" {
  description = "Hostname Keycloak is reached on. Must match the OIDC issuer."
  type        = string
  default     = "keycloak.mil"
}

variable "keycloak_node_port" {
  description = "NodePort the keycloak Service is pinned to (see ../02-workloads)."
  type        = number
  default     = 30080
}

variable "stigman_node_port" {
  description = "NodePort the stigman-api Service is pinned to (see ../02-workloads)."
  type        = number
  default     = 30540
}

variable "floci_network_ip" {
  description = <<-EOT
    Floci's own address on the lab Docker network. The Route53 private zone points
    stigman.mil / keycloak.mil here so that pods inside the clusters resolve the
    same hostnames the browser uses, and reach them through the ALB listeners.
    scripts/02-apply-infra.sh discovers this with `docker inspect`.
  EOT
  type        = string
}
