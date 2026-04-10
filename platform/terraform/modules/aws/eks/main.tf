# =============================================================================
# Module: AWS EKS — DR/Secondary Cluster with Cilium
# =============================================================================
# Purpose: Secondary Kubernetes cluster on AWS for DR and multi-cloud resilience
# Features:
#   - EKS with managed node groups (multi-AZ)
#   - Cilium as CNI (installed via Helm, replacing aws-node DaemonSet)
#   - IRSA (IAM Roles for Service Accounts) — pod-level AWS auth without secrets
#   - EKS Pod Identity (new, recommended over IRSA for new deployments)
#   - OIDC provider for Workload Identity
#   - KMS encryption for etcd secrets
#   - Security Hub + GuardDuty integration (CNAPP AWS side)
# Compliance: SOC 2 CC6.3 | DORA Articles 9, 28 (multi-cloud concentration risk)
# =============================================================================

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.50" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "cluster_name"         { type = string }
variable "kubernetes_version"   { type = string; default = "1.30" }
variable "region"               { type = string; default = "eu-west-1" }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "node_instance_type"   { type = string; default = "m5.2xlarge" }
variable "node_min_count"       { type = number; default = 3 }
variable "node_max_count"       { type = number; default = 20 }
variable "node_desired_count"   { type = number; default = 3 }
variable "cilium_version"       { type = string; default = "1.15.6" }
variable "tags"                 { type = map(string); default = {} }

variable "allowed_management_cidrs" {
  description = "CIDRs allowed to communicate with EKS API (Azure VNet CIDRs + VPN)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# EKS-optimised AMI for worker nodes (Amazon Linux 2023 — hardened)
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/x86_64/standard/image_id"
}

# -----------------------------------------------------------------------------
# KMS Key — encrypt EKS etcd secrets at rest
# SOC 2 C1.1 — Kubernetes secrets encrypted with CMK
# -----------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secrets encryption — ${var.cluster_name}"
  deletion_window_in_days = 30  # 30-day deletion window
  enable_key_rotation     = true  # Annual automatic rotation (SOC 2 CC6.6)
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EKS service"
        Effect = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { "Name" = "eks-secrets-cmk-${var.cluster_name}" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/eks-${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

# -----------------------------------------------------------------------------
# IAM Role for EKS Control Plane
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name = "role-eks-cluster-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

# -----------------------------------------------------------------------------
# Security Group for EKS Control Plane
# -----------------------------------------------------------------------------
resource "aws_security_group" "eks_control_plane" {
  name        = "sg-eks-cp-${var.cluster_name}"
  description = "EKS Control Plane security group — managed by Terraform"
  vpc_id      = var.vpc_id

  # Allow API server access from specified management CIDRs only
  ingress {
    description = "Kubectl access from management networks (Azure VNet + VPN)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_management_cidrs
  }

  egress {
    description = "Allow all outbound (control plane to node communication)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    "Name"                                        = "sg-eks-cp-${var.cluster_name}"
    "kubernetes.io/cluster/${var.cluster_name}"   = "owned"
  })
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.eks_control_plane.id]
    endpoint_private_access = true   # API server accessible from VPC
    endpoint_public_access  = false  # No public API server endpoint (Zero Trust)
    public_access_cidrs     = []     # No public access
  }

  # Encrypt etcd secrets with CMK
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Enable EKS control plane logging — all types for SOC 2 CC4.1
  enabled_cluster_log_types = [
    "api",           # API server requests
    "audit",         # Audit log (who did what)
    "authenticator", # Auth decisions
    "controllerManager",
    "scheduler",
  ]

  # Bootstrap cluster creator admin permissions (Terraform role)
  bootstrap_cluster_creator_admin_permissions = false

  # Access entry — use EKS Access Entries (new model, not aws-auth ConfigMap)
  access_config {
    authentication_mode                         = "API"  # EKS Access Entries only
    bootstrap_cluster_creator_admin_permissions = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  tags = merge(var.tags, {
    "Name"    = var.cluster_name
    "role"    = "dr-secondary"
  })
}

# -----------------------------------------------------------------------------
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# Allows pods to assume IAM roles without AWS credentials
# -----------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  tags            = var.tags
}

# -----------------------------------------------------------------------------
# IAM Role for EKS Worker Nodes
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_nodes" {
  name = "role-eks-nodes-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# Minimum required policies for EKS worker nodes
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  # Note: Only required if using aws-node DaemonSet for CNI.
  # With Cilium (replacing aws-node), this is kept for node IP assignment only.
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  # Allow SSM Session Manager access (no SSH keys on nodes)
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# EKS Managed Node Group — System nodes
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  # Only AL2023 AMI — regularly patched, minimal attack surface
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.node_instance_type]
  disk_size      = 100  # GB

  scaling_config {
    desired_size = var.node_desired_count
    min_size     = var.node_min_count
    max_size     = var.node_max_count
  }

  # Update config — rolling update with max 1 unavailable
  update_config {
    max_unavailable = 1
  }

  # Launch template for additional node config
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  labels = {
    "node-role"     = "workload"
    "cluster-role"  = "dr-secondary"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_readonly,
  ]

  tags = merge(var.tags, {
    "Name"                                      = "eks-node-${var.cluster_name}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# Launch template — node-level configuration (encryption, metadata protection)
resource "aws_launch_template" "eks_nodes" {
  name = "lt-eks-nodes-${var.cluster_name}"

  # Block device mapping — encrypt root volume with CMK
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  # IMDSv2 required — prevent SSRF-based credential theft
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 mandatory
    http_put_response_hop_limit = 1            # Prevent container escape to IMDS
    instance_metadata_tags      = "disabled"
  }

  # Monitoring
  monitoring {
    enabled = true
  }

  tags = var.tags

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { "Name" = "eks-node-${var.cluster_name}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { "Name" = "eks-node-volume-${var.cluster_name}" })
  }
}

# -----------------------------------------------------------------------------
# Cilium Installation via Helm
# IMPORTANT: The default aws-node DaemonSet must be removed BEFORE Cilium install
# This is handled by a pre-install script or by setting --set cni.chainingMode=none
# -----------------------------------------------------------------------------
resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 600  # 10-minute timeout for Cilium to become healthy

  # Core settings
  set {
    name  = "kubeProxyReplacement"
    value = "strict"  # Full kube-proxy replacement via eBPF
  }

  # AWS-specific: use ENI mode for IPAM (native AWS networking)
  set {
    name  = "ipam.mode"
    value = "eni"
  }
  set {
    name  = "eni.enabled"
    value = "true"
  }
  set {
    name  = "egressMasqueradeInterfaces"
    value = "eth0"
  }

  # Disable aws-node CNI (replaced by Cilium)
  set {
    name  = "cni.chainingMode"
    value = "none"
  }

  # eBPF bandwidth manager
  set {
    name  = "bandwidthManager.enabled"
    value = "true"
  }

  # WireGuard node-to-node encryption
  set {
    name  = "encryption.enabled"
    value = "true"
  }
  set {
    name  = "encryption.type"
    value = "wireguard"
  }

  # Hubble — network observability
  set {
    name  = "hubble.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  # Cluster Mesh — for cross-cluster (Azure AKS ↔ AWS EKS) connectivity
  set {
    name  = "cluster.name"
    value = var.cluster_name
  }
  set {
    name  = "cluster.id"
    value = "2"  # Azure cluster = 1, AWS cluster = 2
  }
  set {
    name  = "clusterMesh.useAPIServer"
    value = "true"
  }

  # L7 proxy for HTTP/gRPC/Kafka policy enforcement
  set {
    name  = "l7Proxy"
    value = "true"
  }

  # Tetragon integration (runtime security)
  set {
    name  = "tetragon.enabled"
    value = "true"
  }

  depends_on = [aws_eks_node_group.system]
}

# -----------------------------------------------------------------------------
# EKS Access Entry — grant Terraform and GitHub Actions access
# Uses the new EKS Access Entries model (not aws-auth ConfigMap)
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "terraform" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.terraform_role_arn  # CI/CD role
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "terraform_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.terraform_role_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# -----------------------------------------------------------------------------
# AWS Security Hub — CNAPP aggregation for AWS side
# Aggregates findings from: GuardDuty, Inspector, IAM Access Analyzer
# -----------------------------------------------------------------------------
resource "aws_securityhub_account" "this" {}

resource "aws_guardduty_detector" "this" {
  enable = true

  # Enable EKS audit log monitoring (SOC 2 CC4.1, CC7.2)
  datasources {
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
    s3_logs {
      enable = true
    }
  }

  tags = var.tags
}

# Amazon Inspector v2 — container vulnerability scanning (CNAPP CWPP)
resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2", "LAMBDA"]  # Scan containers, VMs, and functions
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value     = aws_eks_cluster.this.endpoint
  sensitive = true
}

output "cluster_certificate_authority_data" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "node_role_arn" {
  value = aws_iam_role.eks_nodes.arn
}
