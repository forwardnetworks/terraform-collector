output "instance_id" {
  description = "Collector EC2 instance ID."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Collector private IP. Devices that filter management access by source address must allow it (or the NAT gateway's address for devices reached through it)."
  value       = aws_instance.this.private_ip
}

output "security_group_id" {
  description = "Collector security group. Reference it in device-side security groups to allow collection."
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "Collector instance role."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Collector instance role name, for attaching extra policies."
  value       = aws_iam_role.this.name
}

output "collector_token_secret_arn" {
  description = "Secret holding the collector auth token."
  value       = local.token_secret_arn
}

output "quay_secret_arn" {
  description = "Secret holding the quay.io credentials."
  value       = local.quay_secret_arn
}

output "customer_key_secret_arn" {
  description = "Secret holding the backup of the collector encryption key."
  value       = aws_secretsmanager_secret.customer_key.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group for the collector container."
  value       = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.this[0].name : null
}

output "connect_command" {
  description = "Open a shell on the collector."
  value       = "aws ssm start-session --region ${data.aws_region.current.region} --target ${aws_instance.this.id}"
}

output "status_command" {
  description = "Show collector status without opening a shell."
  value       = "aws ssm send-command --region ${data.aws_region.current.region} --instance-ids ${aws_instance.this.id} --document-name AWS-RunShellScript --parameters 'commands=[\"fwdcollector status\"]'"
}
