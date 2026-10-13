# One apply, no Forward UI step: create the collector in Forward, hand its
# token to the AWS deployment, and attach it to the networks it should collect.
#
# Needs the Forward Terraform provider (forwardnetworks/forward) and a Forward
# login (an API token's access key and secret) that is an org admin or can
# manage collection sources on a network.
#
#   cp terraform.tfvars.example terraform.tfvars   # fill in
#   export TF_VAR_forward_username='<api token access key>'
#   export TF_VAR_forward_password='<api token secret>'
#   export TF_VAR_quay_username='...' TF_VAR_quay_password='...'
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    forward = {
      source  = "forwardnetworks/forward"
      version = ">= 0.7.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "forward" {
  base_url = "https://${var.forward_app_host}"
  username = var.forward_username
  password = var.forward_password
}

# Registers the collector with Forward. The token exists only in this
# resource's state and in Secrets Manager; Forward cannot show it again.
# Destroying this resource deletes the collector in Forward.
resource "forward_collector" "this" {
  name = var.name
}

# Forward has no detach: removing an attachment from this list leaves the
# network on this collector until another one is attached.
resource "forward_collector_attachment" "this" {
  for_each = toset(var.network_ids)

  network_id = each.value
  username   = forward_collector.this.username
}

module "forward_collector" {
  source = "../.."

  name      = var.name
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  instance_type          = var.instance_type
  collector_heap_size_gb = var.collector_heap_size_gb
  forward_app_host       = var.forward_app_host

  collector_token = forward_collector.this.token
  quay_username   = var.quay_username
  quay_password   = var.quay_password

  secret_recovery_window_days = var.secret_recovery_window_days

  tags = var.tags
}

variable "region" {
  type = string
}

variable "name" {
  description = "Collector name in Forward, and name prefix for the AWS resources."
  type        = string
  default     = "fwdcollector"
}

variable "forward_app_host" {
  description = "Forward instance host: fwd.app for Forward SaaS."
  type        = string
  default     = "fwd.app"
}

variable "forward_username" {
  description = "Forward API token access key (or user name)."
  type        = string
  sensitive   = true
}

variable "forward_password" {
  description = "Forward API token secret (or password)."
  type        = string
  sensitive   = true
}

variable "network_ids" {
  description = "Forward networks this collector should collect. Empty attaches none."
  type        = list(string)
  default     = []
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

variable "tags" {
  type    = map(string)
  default = {}
}

output "collector" {
  value = {
    forward_collector_id = forward_collector.this.id
    forward_username     = forward_collector.this.username
    attached_networks    = keys(forward_collector_attachment.this)
    instance_id          = module.forward_collector.instance_id
    private_ip           = module.forward_collector.private_ip
    connect_command      = module.forward_collector.connect_command
    status_command       = module.forward_collector.status_command
  }
}
