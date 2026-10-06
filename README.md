# Forward Networks collector on AWS

Terraform that runs the Forward Networks collector container
(`quay.io/forwardnetworks/cloud-collector`) on a single EC2 instance, following
Forward's Docker install and upgrade procedure and automating the parts that
are easy to get wrong: keeping the encryption key, sizing the heap, and
upgrades.

## Before you start: what you need from Forward

Ask your Forward Networks contact for **both** of these. The deployment cannot
pull or register the collector without them.

| Credential | What it is | Where it comes from |
|---|---|---|
| **quay.io login** | Username and password of a pull-only robot account for `quay.io/forwardnetworks/cloud-collector` | Forward Networks (support or your account team) |
| **Collector auth token** | `username:password` string that ties this collector to your Forward organization | Forward UI: **Settings → Collectors**, add a collector and copy its token (or ask Forward) |

Treat both as secrets. Terraform stores them in AWS Secrets Manager; they never
appear in EC2 user data.

You also need:

- An AWS account, Terraform 1.5 or later, AWS provider 6.x.
- A VPC subnet with outbound HTTPS to `fwd.app` (NAT gateway or proxy), and
  routes to the devices the collector will reach over SSH, SNMP and HTTPS.

## What gets built

```
 private subnet                         Secrets Manager
┌────────────────────────────────┐      ├─ collector token
│ EC2 (Amazon Linux 2023)        │◄────►├─ quay.io login
│  systemd: fwdcollector.service │      └─ customer_key.pb backup
│   └─ docker: cloud-collector   │
│  no inbound rules, SSM access  │──► NAT ──► fwd.app (HTTPS)
└────────────────────────────────┘──► devices (SSH/SNMP/HTTPS)
```

- **EC2 instance** with Docker, the collector run as a systemd service
  (`docker run --name fwdcollector ...`), host networking, encrypted gp3 root
  volume, IMDSv2 only.
- **Security group** with no inbound rules. Shell access is through SSM
  Session Manager; no SSH key or bastion.
- **Secrets Manager** secrets for the token, the quay.io login and the
  encryption key backup. The instance role can read only these.
- **Encryption key backup.** Forward's instructions warn that losing
  `/collector/private/customer_key.pb` means re-entering every collection
  secret. The instance copies the key to Secrets Manager as soon as the
  collector creates it, and restores it before the collector starts on any
  rebuilt instance.
- **CloudWatch Logs** for the container output, plus alarms that recover the
  instance on hardware failure and reboot it if the OS hangs.

## Sizing

The collector reserves its entire heap at start (`COLLECTOR_HEAP_SIZE`,
default 32 GiB), so the instance needs the heap plus about 4 GiB. Terraform
refuses an instance type that is too small.

| Instance | Memory | Heap | Notes |
|---|---|---|---|
| `r6i.2xlarge` | 64 GiB | 32 | Forward's default heap (module default) |
| `r6i.xlarge` | 32 GiB | 24 | Smaller networks |
| `r6i.large` | 16 GiB | 8 | Labs and testing only |

## Deploy into an existing VPC

```sh
cd examples/existing-vpc
cp terraform.tfvars.example terraform.tfvars   # region, vpc_id, subnet_id, size

export TF_VAR_collector_token='collector-xxxx:yyyy'   # from Forward
export TF_VAR_quay_username='forwardnetworks+...'     # from Forward
export TF_VAR_quay_password='...'                     # from Forward

terraform init
terraform apply
```

The collector registers with Forward a few minutes after the instance boots.
Check **Settings → Collectors** in Forward for the connected status.

To build a fresh VPC with a NAT gateway as well, use `examples/new-vpc`.

### Keeping secrets out of Terraform state

Values passed as variables end up in Terraform state. To avoid that, create
the secrets yourself and pass their ARNs instead:

```hcl
collector_token_secret_arn = "arn:aws:secretsmanager:...:secret:fwd-token"   # plain string user:password
quay_secret_arn            = "arn:aws:secretsmanager:...:secret:fwd-quay"    # {"username":"...","password":"..."}
```

## Operating the collector

Open a shell (the `connect_command` output):

```sh
aws ssm start-session --target <instance-id>
```

On the instance, `fwdcollector` wraps the Docker commands from Forward's guide:

| Command | Does |
|---|---|
| `sudo fwdcollector status` | Service state, `docker ps`, key backup state, recent logs |
| `sudo fwdcollector logs -f` | `docker logs -f fwdcollector` |
| `sudo fwdcollector upgrade` | Back up the key, `docker pull`, restart only if the image changed |
| `sudo fwdcollector restart` | Stop, remove, pull and start the container |

Collector log files are also kept on the host in `/var/log/fwdcollector`.

**Upgrades.** Forward's procedure (back up key, kill, rm, pull, run) is
`sudo fwdcollector upgrade`. To upgrade on a schedule instead, set
`auto_upgrade_schedule = "Sun *-*-* 03:00:00"`. To control versions, pin
`collector_image_tag`.

**Rotating the token.** Put the new value in the token secret and restart:

```sh
aws secretsmanager put-secret-value --secret-id <collector_token_secret_arn> --secret-string 'collector-xxxx:yyyy'
sudo fwdcollector restart
```

**Proxy.** If outbound traffic must go through a proxy, set
`proxy = { host = "proxy.example.com", port = 3128 }` (and `username`,
`proxy_password` if needed).

## Destroying

`terraform destroy` schedules the secrets, including the encryption key
backup, for deletion after `secret_recovery_window_days` (default 30). Within
that window a secret can be restored with
`aws secretsmanager restore-secret`.

## Inputs

See `variables.tf` for the full list. The ones most deployments set:

| Variable | Default | Purpose |
|---|---|---|
| `vpc_id`, `subnet_id` | required | Where the collector runs |
| `collector_token` / `collector_token_secret_arn` | — | Forward collector auth token |
| `quay_username`, `quay_password` / `quay_secret_arn` | — | quay.io pull credentials |
| `instance_type` | `r6i.2xlarge` | EC2 size |
| `collector_heap_size_gb` | `32` | `COLLECTOR_HEAP_SIZE` |
| `forward_app_host` | `fwd.app` | Forward instance the collector registers with |
| `private_ip` | — | Fixed IP, if device ACLs allow the collector by address |
| `collector_image_tag` | `latest` | Pin for controlled upgrades |
| `auto_upgrade_schedule` | — | systemd `OnCalendar` for scheduled upgrades |
| `kms_key_arn` | — | Customer-managed KMS key for EBS, secrets and logs |
| `additional_iam_policy_arns` | `[]` | e.g. read-only access if the collector should also collect this AWS account |
