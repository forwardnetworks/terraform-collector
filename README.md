# Forward Networks collector on AWS

Terraform that runs the Forward Networks collector container
(`quay.io/forwardnetworks/cloud-collector`) on a single EC2 instance, following
Forward's Docker install and upgrade procedure and automating the parts that
are easy to get wrong: secrets, sizing the heap, and upgrades. It can also
create the collector in Forward, so a deployment needs no Forward UI step.

## Before you start: what you need from Forward

The deployment cannot pull or register the collector without these:

| Credential | What it is | Where it comes from |
|---|---|---|
| **quay.io login** | Username and password of a pull-only robot account for `quay.io/forwardnetworks/cloud-collector` | Ask your Forward Networks contact (support or your account team) |
| **Collector auth token** | `collector-xxxxxxxx:<32 hex>`, the identity this collector uses with your Forward organization | Either Terraform creates it (`examples/end-to-end`, needs a Forward API token that is an org admin or can manage collection sources), or Forward UI: **Settings → Collectors**, add a collector and copy its token |

Treat them as secrets. Terraform stores them in AWS Secrets Manager; they never
appear in EC2 user data.

About the collector token:

- **One token per collector.** It is one collector identity in Forward. Do not
  run two collectors with the same token; create one per instance.
- **No expiry.** It stays valid until the collector is deleted in Forward.
  Rotate by creating a new collector (or `terraform apply -replace` on the
  `forward_collector` resource in `examples/end-to-end`).
- **Shown once.** Forward returns the token only when the collector is
  created; it cannot be read back later.

You also need:

- An AWS account, Terraform 1.5 or later, AWS provider 6.x.
- A VPC subnet with outbound HTTPS to `fwd.app` (NAT gateway or proxy), and
  routes to the devices the collector will reach over SSH, SNMP and HTTPS.

## What gets built

```
 private subnet                         Secrets Manager
┌────────────────────────────────┐      ├─ collector token
│ EC2 (Amazon Linux 2023)        │◄────►├─ quay.io login
│  systemd: fwdcollector.service │      └─ proxy password (optional)
│   └─ docker: cloud-collector   │
│  no inbound rules, SSM access  │──► NAT ──► fwd.app (HTTPS)
└────────────────────────────────┘──► devices (SSH/SNMP/HTTPS)
```

- **EC2 instance** with Docker, the collector run as a systemd service
  (`docker run --name fwdcollector ...`), host networking, encrypted gp3 root
  volume, IMDSv2 only.
- **Security group** with no inbound rules. Shell access is through SSM
  Session Manager; no SSH key or bastion.
- **Secrets Manager** secrets for the token and the quay.io login. The
  instance role can read only these.
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

## Deploy end to end (no Forward UI step)

`examples/end-to-end` adds the Forward Terraform provider
(`forwardnetworks/forward`, 0.7.0 or later). One `terraform apply`:

1. creates the collector in Forward (`forward_collector`) and takes its token,
2. stores the token in Secrets Manager and starts the collector on EC2,
3. attaches the collector to the Forward networks listed in `network_ids`.

### Install the Forward provider (manual, no registry)

The Forward provider is not on the Terraform Registry yet, so `terraform init`
cannot download it by itself. Install its GitHub release once per machine,
then `terraform init` finds it locally. Nothing else in the workflow changes.

**Linux or macOS** (amd64 or arm64; needs `curl`, `unzip`, `shasum`):

```sh
scripts/install-forward-provider.sh
```

It downloads `terraform-provider-forward` v0.7.1 from the
[release](https://github.com/forwardnetworks/terraform-provider-forward/releases/tag/v0.7.1),
checks it against the release's SHA-256 sums, and unzips it into
`~/.terraform.d/plugins/registry.terraform.io/forwardnetworks/forward/0.7.1/<os>_<arch>/`.
`VERSION=<x.y.z>` installs another release.

**Windows**: download `terraform-provider-forward_0.7.1_windows_amd64.zip`
from the release and unzip it into
`%APPDATA%\terraform.d\plugins\registry.terraform.io\forwardnetworks\forward\0.7.1\windows_amd64\`.

**CI runners, or one copy for a team**: install into a shared directory and
point Terraform at it with a CLI config file. Only the Forward provider comes
from the directory; everything else still comes from the registry.

```sh
PLUGIN_DIR=/opt/terraform/plugins scripts/install-forward-provider.sh

cat > /opt/terraform/forward.tfrc <<'EOF'
provider_installation {
  filesystem_mirror {
    path    = "/opt/terraform/plugins"
    include = ["registry.terraform.io/forwardnetworks/forward"]
  }
  direct {
    exclude = ["registry.terraform.io/forwardnetworks/forward"]
  }
}
EOF
export TF_CLI_CONFIG_FILE=/opt/terraform/forward.tfrc
```

**Air-gapped hosts**: run the script on a connected machine with
`PLUGIN_DIR=./plugins`, copy `./plugins` across, and use the CLI config above
with its path.

`terraform init` then prints `Installed forwardnetworks/forward v0.7.1
(unauthenticated)`. That is expected: Terraform verifies signatures only for
providers it downloads from a registry, which is why the script checks the
release's SHA-256 sums first. To check the GPG signature too, import the
release's `terraform-provider-forward_signing_key.asc` and run
`gpg --verify terraform-provider-forward_0.7.1_SHA256SUMS.sig terraform-provider-forward_0.7.1_SHA256SUMS`.

When the provider is published on the registry, this step goes away and
`terraform init` downloads it like any other provider.

### Deploy

```sh
cd examples/end-to-end
cp terraform.tfvars.example terraform.tfvars   # region, VPC, networks, size

export TF_VAR_forward_username='<Forward API token access key>'
export TF_VAR_forward_password='<Forward API token secret>'
export TF_VAR_quay_username='forwardnetworks+...'   # from Forward
export TF_VAR_quay_password='...'                   # from Forward

terraform init
terraform apply
```

`terraform destroy` deletes the collector in Forward as well. Forward has no
detach, so networks it was attached to keep pointing at the deleted collector
until another one is attached.

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
| `sudo fwdcollector status` | Service state, `docker ps`, recent logs |
| `sudo fwdcollector logs -f` | `docker logs -f fwdcollector` |
| `sudo fwdcollector upgrade` | `docker pull`, restart only if the image changed |
| `sudo fwdcollector restart` | Stop, remove, pull and start the container |

Collector log files are also kept on the host in `/var/log/fwdcollector`.

**Upgrades.** Forward's procedure (kill, rm, pull, run) is
`sudo fwdcollector upgrade`. To upgrade on a schedule instead, set
`auto_upgrade_schedule = "Sun *-*-* 03:00:00"`.

Image tags are Forward release numbers (`26.9.0-18`, ...), and `latest` follows
the current release of Forward SaaS. Keep the collector on the same release as
your Forward instance: track `latest` on fwd.app, or pin `collector_image_tag`
to your on-premises release and change it when Forward is upgraded (changing
it rebuilds the instance).

**The encryption key step in Forward's Docker guide.** Older instructions say
to save `/collector/private/customer_key.pb` before every upgrade. Collectors
from release 26.7 on no longer create that file: device credentials are
encrypted on the Forward side. The module therefore does not mount or back up
a key. If you pin `collector_image_tag` to 26.6 or older, follow Forward's key
step by hand.

**Upgrading a deployment of this module made before the key backup was
removed.** The next `terraform apply` rebuilds the instance and deletes the
key backup secret. On collector 26.7 or later there is no key, so nothing is
lost. If you pinned 26.6 or older, copy the key out first
(`docker cp fwdcollector:/collector/private/customer_key.pb .`) and keep it.

**Rotating the token.** Tokens do not expire; rotating means a new collector
identity. With `examples/end-to-end`, run
`terraform apply -replace=forward_collector.this`: Forward gets a new
collector, its token goes to Secrets Manager and the attachments follow the
new username. The instance reads the token when the collector starts, so then
run `sudo fwdcollector restart` on it (the old collector is deleted, so until
then it cannot connect). Without the end-to-end example, add a collector in
Forward, then put its token in the secret and restart:

```sh
aws secretsmanager put-secret-value --secret-id <collector_token_secret_arn> --secret-string 'collector-xxxx:yyyy'
sudo fwdcollector restart
```

Delete the old collector in Forward afterwards.

**Proxy.** If outbound traffic must go through a proxy, set
`proxy = { host = "proxy.example.com", port = 3128 }` (and `username`,
`proxy_password` if needed).

## Destroying

`terraform destroy` schedules the secrets for deletion after
`secret_recovery_window_days` (default 30). Within
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
| `kms_key_arn` | — | Customer-managed KMS key for EBS, secrets and logs (its key policy must allow the CloudWatch Logs service principal) |
| `additional_iam_policy_arns` | `[]` | e.g. read-only access if the collector should also collect this AWS account |
