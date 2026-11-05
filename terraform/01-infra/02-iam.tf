###############################################################################
# IAM — cluster role, node role, and the service-account roles the original lab
# created for the AWS Load Balancer Controller and the EBS CSI driver.
#
# The two controller roles are not load-bearing here (see 05-alb.tf and the
# README): Terraform creates the load balancers directly instead of running the
# controller in-cluster. They are kept because the original lab's IRSA trust
# policies are the part worth being able to read side by side, and Floci does
# emulate the whole OIDC provider / AssumeRoleWithWebIdentity path.
###############################################################################
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

###############################################################################
# IRSA — one OIDC provider per cluster
###############################################################################
# Floci generates a real RSA keypair and an AWS-shaped issuer URL per cluster,
# so these are genuine OIDC providers, not placeholders. The thumbprint is the
# well-known AWS root CA fingerprint; Floci stores it without verifying it.
locals {
  oidc_thumbprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"

  clusters = {
    keycloak = aws_eks_cluster.keycloak
    stigman  = aws_eks_cluster.stigman
  }
}

resource "aws_iam_openid_connect_provider" "cluster" {
  for_each = local.clusters

  url             = each.value.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [local.oidc_thumbprint]
}

# sub/aud-scoped trust, exactly as the original lab wrote it by hand.
data "aws_iam_policy_document" "irsa_assume" {
  for_each = {
    lbc_keycloak = {
      cluster         = "keycloak"
      service_account = "system:serviceaccount:kube-system:aws-load-balancer-controller"
    }
    lbc_stigman = {
      cluster         = "stigman"
      service_account = "system:serviceaccount:kube-system:aws-load-balancer-controller"
    }
    ebs_csi = {
      cluster         = "stigman"
      service_account = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    }
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster[each.value.cluster].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster[each.value.cluster].url, "https://", "")}:sub"
      values   = [each.value.service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster[each.value.cluster].url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "eks-ebs-csi-stigman"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["ebs_csi"].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "lbc" {
  for_each = { keycloak = "lbc_keycloak", stigman = "lbc_stigman" }

  name               = "eks-lbc-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.value].json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  for_each = aws_iam_role.lbc

  role       = each.value.name
  policy_arn = aws_iam_policy.lbc.arn
}

# Trimmed from the original lab's inline policy to the statements that matter
# for reading it: the controller is not actually run here.
resource "aws_iam_policy" "lbc" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "Permissions the AWS Load Balancer Controller would need."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones", "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces", "ec2:DescribeTags",
          "ec2:CreateSecurityGroup", "ec2:CreateTags", "ec2:DeleteTags",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["acm:ListCertificates", "acm:DescribeCertificate"]
        Resource = "*"
      },
    ]
  })
}
