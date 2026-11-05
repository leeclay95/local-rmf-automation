###############################################################################
# EKS — two clusters, as in the original lab.
#
# Floci backs each cluster with a real k3s container holding a live Kubernetes
# API server, published on a host port from 6500-6599. These are genuine
# clusters: kubectl, Deployments, Services and PVCs all behave normally.
#
# Two differences from real EKS that shape the rest of this stack:
#
#   1. One container per cluster *is* the control plane and the only node.
#      aws_eks_node_group is therefore metadata that sets the node's labels,
#      taints and the container's CPU/memory ceiling — it does not add machines.
#
#   2. Cluster addons are recorded but never installed. The aws-ebs-csi-driver
#      addon below creates no CSI pods, so the MySQL PVC in ../02-workloads
#      binds through k3s's local-path provisioner instead (enabled by
#      FLOCI_SERVICES_EKS_DEFAULT_STORAGE_CLASS in ../../docker-compose.yml).
###############################################################################
locals {
  cluster_subnet_ids = [for s in aws_subnet.private : s.id]
}

resource "aws_eks_cluster" "keycloak" {
  name     = "keycloak-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = local.cluster_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Required before CreateAccessEntry is accepted; this is also the modern EKS
  # default, replacing the aws-auth ConfigMap the original lab would have used.
  access_config {
    authentication_mode = "API"
  }

  # Left explicit so it cannot collide with the VPC CIDR. Floci otherwise
  # defaults the service range to 10.100.0.0/16, which is this lab's VPC.
  kubernetes_network_config {
    service_ipv4_cidr = "10.96.0.0/16"
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_cluster" "stigman" {
  name     = "stigman-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = local.cluster_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Required before CreateAccessEntry is accepted; this is also the modern EKS
  # default, replacing the aws-auth ConfigMap the original lab would have used.
  access_config {
    authentication_mode = "API"
  }

  kubernetes_network_config {
    service_ipv4_cidr = "10.96.0.0/16"
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_node_group" "keycloak" {
  cluster_name    = aws_eks_cluster.keycloak.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = local.cluster_subnet_ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

resource "aws_eks_node_group" "stigman" {
  cluster_name    = aws_eks_cluster.stigman.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = local.cluster_subnet_ids
  instance_types  = [var.node_instance_type]

  # The original lab ran two nodes here. Floci serves one node per cluster, so
  # this is a declared desired size the emulator records rather than honours.
  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 3
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

# Metadata only — see the header note. Kept so the original lab's addon wiring,
# including the IRSA role it attaches, is still visible in the plan.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.stigman.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_node_group.stigman]
}

###############################################################################
# Cluster access — the lab IAM user gets cluster-admin on both clusters.
###############################################################################
data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "lab_user" {
  for_each = local.clusters

  cluster_name  = each.value.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "lab_user_admin" {
  for_each = aws_eks_access_entry.lab_user

  cluster_name  = each.value.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

###############################################################################
# The node behind each cluster, as EC2 sees it.
#
# Floci registers each k3s container as a synthesized EC2 instance tagged
# eks:cluster-name=<cluster>. Its PrivateIpAddress is the container's address on
# the lab Docker network, which is what the ALB target groups in 05-alb.tf
# register — Floci's ALB data plane does not resolve instance-id targets, so the
# target groups use target_type = "ip" with these addresses.
###############################################################################
data "aws_instances" "keycloak_node" {
  instance_tags = { "eks:cluster-name" = aws_eks_cluster.keycloak.name }
  depends_on    = [aws_eks_node_group.keycloak]
}

data "aws_instances" "stigman_node" {
  instance_tags = { "eks:cluster-name" = aws_eks_cluster.stigman.name }
  depends_on    = [aws_eks_node_group.stigman]
}
