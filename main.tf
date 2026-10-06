data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  tags = merge({ Application = "forward-collector" }, var.tags)

  ami_id = coalesce(var.ami_id, try(data.aws_ssm_parameter.al2023[0].insecure_value, null))

  # The heap is reserved up front (-Xms = -Xmx); leave room for the JVM's
  # off-heap memory, Docker and the OS.
  required_memory_mib = var.collector_heap_size_gb * 1024 + 4096
}

# --- Secrets ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "collector_token" {
  count = var.collector_token_secret_arn == null ? 1 : 0

  name_prefix             = "${var.name}/collector-token-"
  description             = "Forward collector auth token (username:password)."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "collector_token" {
  count = var.collector_token_secret_arn == null && var.collector_token != null ? 1 : 0

  secret_id     = aws_secretsmanager_secret.collector_token[0].id
  secret_string = var.collector_token
}

resource "aws_secretsmanager_secret" "quay" {
  count = var.quay_secret_arn == null ? 1 : 0

  name_prefix             = "${var.name}/quay-"
  description             = "quay.io pull credentials for the Forward collector image."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "quay" {
  count = var.quay_secret_arn == null && var.quay_username != null ? 1 : 0

  secret_id = aws_secretsmanager_secret.quay[0].id
  secret_string = jsonencode({
    username = var.quay_username
    password = var.quay_password
  })
}

resource "aws_secretsmanager_secret" "proxy_password" {
  count = var.proxy_password != null ? 1 : 0

  name_prefix             = "${var.name}/proxy-password-"
  description             = "Password for the collector's HTTP proxy."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "proxy_password" {
  count = var.proxy_password != null ? 1 : 0

  secret_id     = aws_secretsmanager_secret.proxy_password[0].id
  secret_string = var.proxy_password
}

# The collector generates customer_key.pb, which encrypts the device
# credentials stored in Forward. The instance writes it here the first time it
# appears and restores it on every rebuild. Terraform never sets a value.
resource "aws_secretsmanager_secret" "customer_key" {
  name_prefix             = "${var.name}/customer-key-"
  description             = "Backup of the Forward collector encryption key (customer_key.pb). Written by the collector instance. Losing it means re-entering every collection secret."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.tags
}

locals {
  token_secret_arn = coalesce(var.collector_token_secret_arn, try(aws_secretsmanager_secret.collector_token[0].arn, null))
  quay_secret_arn  = coalesce(var.quay_secret_arn, try(aws_secretsmanager_secret.quay[0].arn, null))
  proxy_secret_arn = try(aws_secretsmanager_secret.proxy_password[0].arn, "")
  read_secret_arns = compact([local.token_secret_arn, local.quay_secret_arn, local.proxy_secret_arn, aws_secretsmanager_secret.customer_key.arn])
  log_group_name   = "/forward/${var.name}"
}

# --- IAM -------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_iam_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid       = "ReadCollectorSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = local.read_secret_arns
  }

  statement {
    sid       = "BackUpEncryptionKey"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.customer_key.arn]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [1]
    content {
      sid       = "UseSecretsKey"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_cloudwatch_logs ? [1] : []
    content {
      sid       = "ShipContainerLogs"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      resources = ["${aws_cloudwatch_log_group.this[0].arn}:*"]
    }
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "forward-collector"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.collector.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.this.name
  tags        = local.tags
}

# --- Network ---------------------------------------------------------------

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "Forward collector: outbound only."
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = toset(var.egress_cidr_blocks)

  security_group_id = aws_security_group.this.id
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
  description       = "Forward SaaS, devices and cloud APIs"
}

# --- Logs ------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

# --- Instance --------------------------------------------------------------

locals {
  collector_conf = {
    AWS_REGION       = data.aws_region.current.region
    IMAGE            = "${var.collector_image}:${var.collector_image_tag}"
    HEAP_GB          = tostring(var.collector_heap_size_gb)
    APP_HOST         = var.forward_app_host
    PROXY_HOST       = try(var.proxy.host, "")
    PROXY_PORT       = try(tostring(var.proxy.port), "")
    PROXY_USERNAME   = try(var.proxy.username, "")
    PROXY_SECRET_ARN = local.proxy_secret_arn
    TOKEN_SECRET_ARN = local.token_secret_arn
    QUAY_SECRET_ARN  = local.quay_secret_arn
    KEY_SECRET_ARN   = aws_secretsmanager_secret.customer_key.arn
    LOG_GROUP        = var.enable_cloudwatch_logs ? local.log_group_name : ""
  }

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    conf                  = local.collector_conf
    helper_b64            = base64encode(file("${path.module}/templates/fwdcollector.sh"))
    auto_upgrade_schedule = var.auto_upgrade_schedule == null ? "" : var.auto_upgrade_schedule
  })
}

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = var.associate_public_ip_address
  vpc_security_group_ids      = concat([aws_security_group.this.id], var.additional_security_group_ids)
  iam_instance_profile        = aws_iam_instance_profile.this.name
  key_name                    = var.key_name
  monitoring                  = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
    tags                  = merge(local.tags, { Name = var.name })
  }

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    # New AMI releases should not rebuild a running collector. A rebuild for
    # any other reason picks up the latest AMI.
    ignore_changes = [ami]

    precondition {
      condition     = data.aws_ec2_instance_type.this.memory_size >= local.required_memory_mib
      error_message = "${var.instance_type} has ${data.aws_ec2_instance_type.this.memory_size} MiB; a ${var.collector_heap_size_gb} GiB heap needs at least ${local.required_memory_mib} MiB. Pick a larger instance_type or lower collector_heap_size_gb."
    }

    precondition {
      condition     = contains(data.aws_ec2_instance_type.this.supported_architectures, "x86_64")
      error_message = "The collector image is x86_64 only; ${var.instance_type} is not."
    }
  }

  depends_on = [
    aws_iam_role_policy.collector,
    aws_secretsmanager_secret_version.collector_token,
    aws_secretsmanager_secret_version.quay,
  ]
}

# --- Health ----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "system_recover" {
  alarm_name          = "${var.name}-system-status-recover"
  alarm_description   = "Recover the Forward collector onto healthy hardware (keeps instance ID, IP and disk)."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions       = concat(["arn:${data.aws_partition.current.partition}:automate:${data.aws_region.current.region}:ec2:recover"], var.alarm_actions)
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "instance_reboot" {
  alarm_name          = "${var.name}-instance-status-reboot"
  alarm_description   = "Reboot the Forward collector when the OS stops responding."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions       = concat(["arn:${data.aws_partition.current.partition}:automate:${data.aws_region.current.region}:ec2:reboot"], var.alarm_actions)
  tags                = local.tags
}
