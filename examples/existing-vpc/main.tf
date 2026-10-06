# Forward collector in an existing VPC.
#
#   cp terraform.tfvars.example terraform.tfvars   # fill in
#   export TF_VAR_collector_token='collector-xxxx:yyyy'
#   export TF_VAR_quay_username='...' TF_VAR_quay_password='...'
#   terraform init && terraform apply

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
}

module "forward_collector" {
  source = "../.."

  name      = var.name
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  instance_type          = var.instance_type
  collector_heap_size_gb = var.collector_heap_size_gb

  collector_token = var.collector_token
  quay_username   = var.quay_username
  quay_password   = var.quay_password

  tags = var.tags
}

variable "region" {
  type = string
}

variable "name" {
  type    = string
  default = "fwdcollector"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
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

variable "tags" {
  type    = map(string)
  default = {}
}

output "collector" {
  value = {
    instance_id     = module.forward_collector.instance_id
    private_ip      = module.forward_collector.private_ip
    connect_command = module.forward_collector.connect_command
    status_command  = module.forward_collector.status_command
    log_group       = module.forward_collector.log_group_name
  }
}
