# =============================================================================
# SuperApp Platform – AWS Networking Module
# VPC · Subnets · Transit Gateway · Route Tables · NACLs · VPC Endpoints
# Site-to-Site VPN (on-prem T24 connectivity) · VPC Flow Logs
# =============================================================================
# Standards: SOC 2 CC6.6 (network controls), DORA Art.9 (network resilience),
#            CIS AWS Foundations 3.x, AWS Well-Architected Security Pillar
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "environment"     { type = string }
variable "aws_region"      { type = string }
variable "tags"            { type = map(string) }

variable "vpc" {
  description = "VPC CIDR and DNS configuration"
  type = object({
    cidr                  = string
    enable_dns_support    = optional(bool, true)
    enable_dns_hostnames  = optional(bool, true)
    instance_tenancy      = optional(string, "default")  # "dedicated" for strict isolation
  })
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into (min 3 for HA)"
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones required for HA."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private (EKS workload) subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public (ALB/NAT) subnets"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for isolated database subnets"
  type        = list(string)
}

variable "flow_logs_retention_days" {
  description = "VPC Flow Log retention in days (SOC 2 min 90)"
  type        = number
  default     = 90
}

variable "on_premises_cidr" {
  description = "On-premises network CIDR (T24 / HQ)"
  type        = string
  default     = "10.0.0.0/8"
}

variable "on_premises_bgp_asn" {
  description = "On-premises BGP ASN for VPN"
  type        = number
  default     = 65000
}

variable "on_premises_public_ip" {
  description = "Public IP of on-premises VPN device"
  type        = string
  default     = ""
}

variable "azure_primary_cidr" {
  description = "Azure primary VNet CIDR (for routing)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "azure_dr_cidr" {
  description = "Azure DR VNet CIDR (for routing)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "kms_key_arn" {
  description = "KMS key ARN for flow log encryption"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc.cidr
  enable_dns_support   = var.vpc.enable_dns_support
  enable_dns_hostnames = var.vpc.enable_dns_hostnames
  instance_tenancy     = var.vpc.instance_tenancy

  tags = merge(var.tags, {
    Name = "vpc-superapp-${var.environment}-${var.aws_region}"
  })
}

# Enable IPv6 (dual-stack for future-proofing)
resource "aws_vpc_ipv6_cidr_block_association" "main" {
  vpc_id                          = aws_vpc.main.id
  amazon_provided_ipv6_cidr_block = true
}

# ---------------------------------------------------------------------------
# Internet Gateway (public subnets only)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "igw-superapp-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# NAT Gateways (one per AZ for HA) – private subnet egress
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "eip-nat-${var.environment}-az${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "nat-${var.environment}-az${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

# Public subnets – ALB, NAT Gateway (no workloads deployed here)
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false  # explicit EIPs only; no auto-assign

  tags = merge(var.tags, {
    Name                                          = "subnet-public-${var.environment}-az${count.index + 1}"
    "kubernetes.io/role/elb"                      = "1"  # ALB controller annotation
    "kubernetes.io/cluster/eks-superapp-${var.environment}" = "shared"
  })
}

# Private subnets – EKS node groups, application workloads
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name                                          = "subnet-private-${var.environment}-az${count.index + 1}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/eks-superapp-${var.environment}" = "shared"
  })
}

# Database subnets – RDS Aurora, ElastiCache (no route to internet)
resource "aws_subnet" "database" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "subnet-database-${var.environment}-az${count.index + 1}"
  })
}

# DB Subnet Group for RDS Aurora
resource "aws_db_subnet_group" "main" {
  name        = "dbsg-superapp-${var.environment}"
  description = "SuperApp database subnet group – ${var.environment}"
  subnet_ids  = aws_subnet.database[*].id

  tags = merge(var.tags, {
    Name = "dbsg-superapp-${var.environment}"
  })
}

resource "aws_elasticache_subnet_group" "main" {
  name        = "ecsg-superapp-${var.environment}"
  description = "SuperApp ElastiCache subnet group – ${var.environment}"
  subnet_ids  = aws_subnet.database[*].id

  tags = merge(var.tags, {
    Name = "ecsg-superapp-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# Route Tables
# ---------------------------------------------------------------------------

# Public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "rt-public-${var.environment}"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables (per AZ – different NAT GW for resilience)
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  # Route to on-premises via VPN (T24 integration)
  dynamic "route" {
    for_each = var.on_premises_public_ip != "" ? [1] : []
    content {
      cidr_block         = var.on_premises_cidr
      transit_gateway_id = aws_ec2_transit_gateway.main.id
    }
  }

  # Route to Azure (inter-cloud via Transit Gateway – placeholder for Direct Connect)
  route {
    cidr_block         = var.azure_primary_cidr
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  route {
    cidr_block         = var.azure_dr_cidr
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "rt-private-${var.environment}-az${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Database route table – no internet egress
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  # Only route within VPC (implicit) – no external routes

  tags = merge(var.tags, {
    Name = "rt-database-${var.environment}"
  })
}

resource "aws_route_table_association" "database" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# ---------------------------------------------------------------------------
# Network ACLs
# SOC 2 CC6.6 – Additional stateless layer of network security
# ---------------------------------------------------------------------------

# Private subnet NACLs
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # Allow inbound HTTPS from public subnets (ALB → pods)
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc.cidr
    from_port  = 443
    to_port    = 443
  }

  # Allow inbound ephemeral ports (response traffic)
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Allow inbound from on-premises (T24 callback)
  ingress {
    rule_no    = 300
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.on_premises_cidr
    from_port  = 0
    to_port    = 0
  }

  # Deny known malicious ranges (example – update with threat intel)
  ingress {
    rule_no    = 32766
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # Allow all outbound
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(var.tags, {
    Name = "nacl-private-${var.environment}"
  })
}

# Database NACL – only accept from private subnet
resource "aws_network_acl" "database" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.database[*].id

  # Allow inbound from private subnets only
  dynamic "ingress" {
    for_each = var.private_subnet_cidrs
    content {
      rule_no    = 100 + ingress.key * 10
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 1433  # MSSQL / Aurora compat
      to_port    = 5432  # PostgreSQL
    }
  }

  # Allow Redis port
  dynamic "ingress" {
    for_each = var.private_subnet_cidrs
    content {
      rule_no    = 200 + ingress.key * 10
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 6379
      to_port    = 6380
    }
  }

  # Allow ephemeral response ports
  ingress {
    rule_no    = 900
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc.cidr
    from_port  = 1024
    to_port    = 65535
  }

  # Deny everything else
  ingress {
    rule_no    = 32766
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(var.tags, {
    Name = "nacl-database-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# VPC Endpoints (PrivateLink) – Zero Trust: no S3/ECR traffic over internet
# SOC 2 CC6.6 – Private network paths
# ---------------------------------------------------------------------------

# Gateway endpoints (free)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(
    aws_route_table.private[*].id,
    [aws_route_table.database.id]
  )

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3Access"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource  = "*"
    }]
  })

  tags = merge(var.tags, { Name = "vpce-s3-${var.environment}" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "vpce-dynamodb-${var.environment}" })
}

# Interface endpoints (ECR, ECR Docker, STS, Secrets Manager, etc.)
locals {
  interface_endpoint_services = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "secretsmanager",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "logs",
    "monitoring",
    "autoscaling",
    "elasticloadbalancing",
    "kms",
    "ecs",
    "xray",
  ]
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "sg-vpce-${var.environment}"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc.cidr]
  }

  tags = merge(var.tags, { Name = "sg-vpce-${var.environment}" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each          = toset(local.interface_endpoint_services)
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  private_dns_enabled = true  # override public DNS with private

  tags = merge(var.tags, {
    Name = "vpce-${each.value}-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# Transit Gateway – Multi-VPC + VPN connectivity hub
# ---------------------------------------------------------------------------
resource "aws_ec2_transit_gateway" "main" {
  description                     = "SuperApp Transit Gateway – ${var.environment}"
  amazon_side_asn                 = 64512
  auto_accept_shared_attachments  = "disable"   # explicit approval
  default_route_table_association = "disable"   # we manage route tables
  default_route_table_propagation = "disable"
  vpn_ecmp_support                = "enable"    # ECMP for VPN resilience
  dns_support                     = "enable"
  multicast_support               = "disable"

  tags = merge(var.tags, {
    Name = "tgw-superapp-${var.environment}"
  })
}

# VPC attachment to Transit Gateway
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  subnet_ids         = aws_subnet.private[*].id
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.main.id

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  appliance_mode_support = "enable"  # required for firewalls/NAT in path

  tags = merge(var.tags, {
    Name = "tgw-att-vpc-${var.environment}"
  })
}

# Transit Gateway Route Table
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = merge(var.tags, {
    Name = "tgw-rt-${var.environment}"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "vpc" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.main.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# ---------------------------------------------------------------------------
# Site-to-Site VPN – On-premises T24 / HQ connectivity
# SOC 2 CC6.7 – Encrypted transmission to external parties
# DORA Art.9 – Secure communication channels
# ---------------------------------------------------------------------------
resource "aws_customer_gateway" "on_premises" {
  count      = var.on_premises_public_ip != "" ? 1 : 0
  bgp_asn    = var.on_premises_bgp_asn
  ip_address = var.on_premises_public_ip
  type       = "ipsec.1"

  tags = merge(var.tags, {
    Name = "cgw-onprem-${var.environment}"
  })
}

resource "aws_vpn_connection" "to_on_premises" {
  count               = var.on_premises_public_ip != "" ? 1 : 0
  vpn_gateway_id      = null  # using Transit Gateway
  transit_gateway_id  = aws_ec2_transit_gateway.main.id
  customer_gateway_id = aws_customer_gateway.on_premises[0].id
  type                = "ipsec.1"

  # IKEv2 with AES-256 / SHA-256 (SOC 2 CC6.7 strong encryption)
  tunnel1_ike_versions = ["ikev2"]
  tunnel2_ike_versions = ["ikev2"]

  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]

  tunnel1_phase1_integrity_algorithms = ["SHA2-256"]
  tunnel2_phase1_integrity_algorithms = ["SHA2-256"]

  tunnel1_phase1_dh_group_numbers = [14, 19, 20]  # DH Group 14+ for PFS
  tunnel2_phase1_dh_group_numbers = [14, 19, 20]

  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]

  tunnel1_phase2_integrity_algorithms = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms = ["SHA2-256"]

  tunnel1_phase2_dh_group_numbers = [14, 19, 20]
  tunnel2_phase2_dh_group_numbers = [14, 19, 20]

  static_routes_only = false  # BGP dynamic routing

  tags = merge(var.tags, {
    Name = "vpn-onprem-${var.environment}"
  })
}

# VPN attachment to TGW route table
resource "aws_ec2_transit_gateway_route_table_association" "vpn" {
  count                          = var.on_premises_public_ip != "" ? 1 : 0
  transit_gateway_attachment_id  = tolist(aws_vpn_connection.to_on_premises[0].transit_gateway_attachment_id != null ? [aws_vpn_connection.to_on_premises[0].transit_gateway_attachment_id] : [])[0]
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# ---------------------------------------------------------------------------
# VPC Flow Logs – All accepted and rejected traffic
# SOC 2 CC7.2 – Network monitoring and anomaly detection
# CIS AWS 3.9 – VPC flow logging
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/superapp-${var.environment}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "iam-role-vpc-flow-logs-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"  # capture ACCEPT + REJECT (SOC 2 CC7.2)
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = merge(var.tags, {
    Name = "fl-superapp-${var.environment}"
  })
}

# ---------------------------------------------------------------------------
# Security Groups (base layer – EKS SGs in EKS module)
# ---------------------------------------------------------------------------

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "sg-alb-${var.environment}"
  description = "ALB inbound HTTPS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc.cidr]
  }

  tags = merge(var.tags, { Name = "sg-alb-${var.environment}" })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS workloads)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB)"
  value       = aws_subnet.public[*].id
}

output "database_subnet_ids" {
  description = "Database subnet IDs"
  value       = aws_subnet.database[*].id
}

output "db_subnet_group_name" {
  description = "RDS database subnet group name"
  value       = aws_db_subnet_group.main.name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name"
  value       = aws_elasticache_subnet_group.main.name
}

output "transit_gateway_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.main.id
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPs (whitelist on firewall rules)"
  value       = aws_eip.nat[*].public_ip
}

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "vpce_security_group_id" {
  description = "VPC endpoint security group ID"
  value       = aws_security_group.vpc_endpoints.id
}

output "private_route_table_ids" {
  description = "Private route table IDs"
  value       = aws_route_table.private[*].id
}

output "flow_log_group_name" {
  description = "CloudWatch log group name for VPC flow logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}
