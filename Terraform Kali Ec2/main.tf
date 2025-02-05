# Get current AWS region and account details
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_iam_user" "terraform_kali_deployer" {
  name = "terraform-kali-deployer"
}

resource "aws_iam_user_policy" "kali_deployment_policy" {
  name = "terraform-kali-deployment-policy"
  user = aws_iam_user.terraform_kali_deployer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:CreateInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:DetachInternetGateway",
          "ec2:DeleteInternetGateway",
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable",
          "ec2:AssociateRouteTable",
          "ec2:CreateRoute"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances"
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${data.aws_region.current.name}::image/*",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInternetGateways"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:CreateLogGroup",
          "cloudwatch:DeleteLogGroup",
          "cloudwatch:PutRetentionPolicy"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:Subscribe",
          "sns:Unsubscribe"
        ]
        Resource = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:kali-*"
      }
    ]
  })
}

# VPC Endpoints for SSM
resource "aws_vpc_endpoint" "vpc_endpoints" {
  for_each            = toset(var.vpc_endpoints)
  vpc_id              = module.networking.vpc_resources.vpc_id
  subnet_ids          = module.networking.vpc_resources.private_subnet_ids
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_security_groups.id]
  
  tags = {
    "Name" = "kali-vpc-endpoint-${each.key}"
  }
}

# Kali Linux AMI Datasource
data "aws_ami" "kali_linux" {
  most_recent = true
  owners      = ["679593333241"] # Official Kali Linux AMI owner

  filter {
    name   = "name"
    values = ["kali-linux-*-x86_64-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Kali Instance Resource
resource "aws_instance" "kali_instance" {
  ami                         = data.aws_ami.kali_linux.id
  instance_type               = var.kali_instance_type
  subnet_id                   = module.networking.vpc_resources.private_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.kali_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.kali_ssm_profile.name
  monitoring                  = true
  
  user_data                   = templatefile("userdata.sh", {
    cloudwatch_log_group = aws_cloudwatch_log_group.ssm_logs.name
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    encrypted   = true
    volume_type = "gp3"
  }

  tags = {
    Name = "Kali-Penetration-Testing-Instance"
    Environment = "Security-Research"
  }
}

# CloudWatch Log Group for SSM Logs
resource "aws_cloudwatch_log_group" "ssm_logs" {
  name              = "/aws/ssm/kali-instance-logs"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.log_encryption_key.arn
}

# SNS Topic for Alerts
resource "aws_sns_topic" "security_alerts" {
  name = "kali-security-alerts"
}

# CloudWatch Metric Filter for Suspicious Commands
resource "aws_cloudwatch_log_metric_filter" "suspicious_commands" {
  name           = "suspicious-command-filter"
  pattern        = "/(whoami|cat /etc/passwd|cat /etc/shadow|sudo)/"
  log_group_name = aws_cloudwatch_log_group.ssm_logs.name

  metric_transformation {
    name      = "SuspiciousCommandCount"
    namespace = "SecurityMetrics"
    value     = "1"
  }
}

# VPC Resource
resource "aws_vpc" "kali_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "kali-pentesting-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.kali_vpc.id

  tags = {
    Name = "kali-vpc-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public_subnets" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.kali_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "Public Subnet ${count.index + 1}"
  }
}

# Private Subnets
resource "aws_subnet" "private_subnets" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.kali_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "Private Subnet ${count.index + 1}"
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.kali_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

# Route Table Association for Public Subnets
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public_subnets)
  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public.id
}
