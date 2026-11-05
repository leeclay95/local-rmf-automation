variable "keycloak_image" {
  description = "Keycloak preloaded with the STIG Manager realm."
  type        = string
  default     = "nuwcdivnpt/stig-manager-auth:latest"
}

variable "stigman_image" {
  type    = string
  default = "nuwcdivnpt/stig-manager:latest"
}

variable "mysql_image" {
  type    = string
  default = "mysql:8"
}

variable "storage_class" {
  description = <<-EOT
    The original lab used gp2, provisioned by the EBS CSI driver. Floci records
    the aws-ebs-csi-driver addon but installs nothing, so a gp2 claim would sit
    Pending forever — exactly as it does on a real EKS cluster with no CSI
    driver. k3s's local-path provisioner backs the volume instead.
  EOT
  type        = string
  default     = "local-path"
}

variable "mysql_storage" {
  type    = string
  default = "20Gi"
}

variable "mysql_root_password" {
  type      = string
  default   = "rootpw"
  sensitive = true
}

variable "mysql_password" {
  type      = string
  default   = "stigman"
  sensitive = true
}

variable "classification" {
  description = "Banner classification shown in the STIG Manager UI."
  type        = string
  default     = "U"
}
