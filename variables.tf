variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
  default     = "fwdcollector"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,32}$", var.name))
    error_message = "name must be 1-32 characters of letters, digits and hyphens."
  }
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}

# --- Network ---------------------------------------------------------------

variable "vpc_id" {
  description = "VPC the collector runs in."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the collector. Use a private subnet with outbound internet (NAT gateway or proxy) to reach Forward, and routes to the devices it collects from."
  type        = string
}

variable "private_ip" {
  description = "Optional fixed private IP for the collector, so device ACLs that allow the collector by address survive an instance rebuild. Must be inside subnet_id."
  type        = string
  default     = null
}

variable "associate_public_ip_address" {
  description = "Give the instance a public IP. Leave false in a private subnet; only set true if the subnet routes straight to an internet gateway."
  type        = bool
  default     = false
}

variable "egress_cidr_blocks" {
  description = "Destinations the collector may connect to. It needs HTTPS to Forward plus SSH, SNMP, HTTPS and APIs on the devices and clouds it collects from."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_security_group_ids" {
  description = "Extra security groups to attach to the collector."
  type        = list(string)
  default     = []
}

# --- Instance --------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. The collector reserves its whole heap at start, so memory must exceed collector_heap_size_gb by at least 4 GiB."
  type        = string
  default     = "r6i.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (OS, Docker image, collector logs)."
  type        = number
  default     = 64
}

variable "ami_id" {
  description = "Optional AMI override. Defaults to the latest Amazon Linux 2023 x86_64 AMI at first apply; later AMI releases do not replace the instance."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key for the EBS volume and the Secrets Manager secrets. Defaults to the AWS-managed keys."
  type        = string
  default     = null
}

variable "key_name" {
  description = "Optional EC2 key pair. Not needed: shell access is through SSM Session Manager."
  type        = string
  default     = null
}

# --- Collector -------------------------------------------------------------

variable "collector_image" {
  description = "Collector container image without tag."
  type        = string
  default     = "quay.io/forwardnetworks/cloud-collector"
}

variable "collector_image_tag" {
  description = "Image tag pulled on every service start. Pin a specific tag for controlled upgrades."
  type        = string
  default     = "latest"
}

variable "collector_heap_size_gb" {
  description = "COLLECTOR_HEAP_SIZE in GiB. Forward's default is 32."
  type        = number
  default     = 32

  validation {
    condition     = var.collector_heap_size_gb >= 4 && floor(var.collector_heap_size_gb) == var.collector_heap_size_gb
    error_message = "collector_heap_size_gb must be a whole number of at least 4."
  }
}

variable "forward_app_host" {
  description = "Forward host the collector registers with (APP_HOST). fwd.app for Forward SaaS."
  type        = string
  default     = "fwd.app"
}

variable "proxy" {
  description = "Optional HTTP proxy the collector uses to reach Forward."
  type = object({
    host     = string
    port     = number
    username = optional(string, "")
  })
  default = null
}

variable "proxy_password" {
  description = "Password for proxy.username, stored in Secrets Manager."
  type        = string
  default     = null
  sensitive   = true
}

# --- Credentials -----------------------------------------------------------
# Either pass the values (Terraform stores them in Secrets Manager, and they
# also appear in Terraform state), or create the secrets yourself and pass
# their ARNs.

variable "collector_token" {
  description = "Collector auth token from Forward (Settings > Collectors), in username:password form. Ignored if collector_token_secret_arn is set."
  type        = string
  default     = null
  sensitive   = true
}

variable "collector_token_secret_arn" {
  description = "Existing Secrets Manager secret holding the collector token as a plain string."
  type        = string
  default     = null
}

variable "quay_username" {
  description = "quay.io robot account username. Ignored if quay_secret_arn is set."
  type        = string
  default     = null
  sensitive   = true
}

variable "quay_password" {
  description = "quay.io robot account password. Ignored if quay_secret_arn is set."
  type        = string
  default     = null
  sensitive   = true
}

variable "quay_secret_arn" {
  description = "Existing Secrets Manager secret holding {\"username\":\"...\",\"password\":\"...\"} for quay.io."
  type        = string
  default     = null
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret can be restored. Covers the encryption key backup: deleting it means re-entering every collection secret. 0 deletes at once (tests only)."
  type        = number
  default     = 30
}

# --- Operations ------------------------------------------------------------

variable "enable_cloudwatch_logs" {
  description = "Ship collector container logs to CloudWatch Logs. docker logs keeps working either way."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for collector logs."
  type        = number
  default     = 30
}

variable "alarm_actions" {
  description = "Extra actions (e.g. SNS topic ARNs) for the instance health alarms."
  type        = list(string)
  default     = []
}

variable "additional_iam_policy_arns" {
  description = "Extra IAM policies for the collector's instance role, e.g. read-only access if it should collect this AWS account."
  type        = list(string)
  default     = []
}

variable "auto_upgrade_schedule" {
  description = "Optional systemd OnCalendar schedule (e.g. \"Sun *-*-* 03:00:00\") to pull collector_image_tag and restart if it changed. Null disables scheduled upgrades."
  type        = string
  default     = null
}
