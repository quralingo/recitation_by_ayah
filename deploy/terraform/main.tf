terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state remotely (recommended for team use):
  # backend "s3" {
  #   bucket  = "your-tf-state-bucket"
  #   key     = "quran-muaalem/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    Project     = var.project_name
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

# Auto-select the latest Deep Learning AMI (Ubuntu 22.04, GPU PyTorch, x86_64)
# This image pre-installs CUDA drivers, nvidia-container-toolkit, and Docker.
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.* (Ubuntu 22.04) *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "main" {
  name        = "${var.project_name}-sg"
  description = "Quran Muaalem: allow SSH, HTTP (ACME), HTTPS"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description      = "HTTP - Lets Encrypt ACME challenge"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-sg" })
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-deployer"
  public_key = var.ssh_public_key
  tags       = local.tags
}

# ── IAM Role (enables AWS SSM Session Manager as an SSH-free access method) ──

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── EC2 Spot Instance (g4dn.xlarge, T4 GPU) ──────────────────────────────────

resource "aws_instance" "main" {
  ami                    = data.aws_ami.deep_learning.id
  instance_type          = "g4dn.xlarge"
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Toggle spot vs on-demand via var.use_spot in terraform.tfvars.
  # New AWS accounts need a quota increase before spot G-instances work:
  #   AWS Console → Service Quotas → EC2 → "All G and VT Spot Instance Requests" → Request 4 vCPUs
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
        max_price                      = var.spot_max_price
      }
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 80
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url = var.repo_url
    app_dir  = "/app"
  })

  tags = merge(local.tags, { Name = var.project_name })

  # Don't replace the instance when AMI is updated by AWS – only on explicit
  # terraform apply after a manual taint.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
# The EIP stays associated through spot stop/start cycles because the
# instance ID doesn't change for persistent spot.

resource "aws_eip" "main" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = var.project_name })
}

resource "aws_eip_association" "main" {
  instance_id   = aws_instance.main.id
  allocation_id = aws_eip.main.id
}
