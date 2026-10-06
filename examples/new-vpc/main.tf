# Self-contained deployment: a new VPC with a NAT gateway and a private subnet
# for the collector. Used to test the module; also a starting point when no
# VPC exists yet.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Application = "forward-collector", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "fwdcollector"
}

variable "availability_zone" {
  description = "AZ for both subnets. Defaults to the region's first AZ; set it if that AZ lacks NAT gateways or the instance type."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  type    = string
  default = "10.200.0.0/24"
}

variable "instance_type" {
  type    = string
  default = "r6i.2xlarge"
}

variable "collector_heap_size_gb" {
  type    = number
  default = 32
}

variable "collector_token" {
  type      = string
  sensitive = true
}

variable "quay_username" {
  type      = string
  sensitive = true
}

variable "quay_password" {
  type      = string
  sensitive = true
}

variable "secret_recovery_window_days" {
  type    = number
  default = 30
}

variable "auto_upgrade_schedule" {
  type    = string
  default = null
}

data "aws_availability_zones" "available" {
  state = "available"

  # Regular AZs only, not Local or Wavelength Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone = local.az
  tags              = { Name = "${var.name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 1)
  availability_zone = local.az
  tags              = { Name = "${var.name}-private" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = var.name }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

module "forward_collector" {
  source = "../.."

  name   = var.name
  vpc_id = aws_vpc.this.id
  # Through the route table association so the instance boots after NAT works.
  subnet_id = aws_route_table_association.private.subnet_id

  instance_type          = var.instance_type
  collector_heap_size_gb = var.collector_heap_size_gb
  auto_upgrade_schedule  = var.auto_upgrade_schedule

  collector_token = var.collector_token
  quay_username   = var.quay_username
  quay_password   = var.quay_password

  secret_recovery_window_days = var.secret_recovery_window_days
}

output "collector" {
  value = {
    instance_id             = module.forward_collector.instance_id
    private_ip              = module.forward_collector.private_ip
    nat_public_ip           = aws_eip.nat.public_ip
    connect_command         = module.forward_collector.connect_command
    status_command          = module.forward_collector.status_command
    log_group               = module.forward_collector.log_group_name
    customer_key_secret_arn = module.forward_collector.customer_key_secret_arn
    token_secret_arn        = module.forward_collector.collector_token_secret_arn
  }
}
