# n8n on AWS — Terraform + Ansible + GitHub Actions

Provisions a single EC2 box on AWS, installs Docker, and runs n8n + Postgres behind a
Caddy reverse proxy — all triggered by a GitHub Actions pipeline. No long-lived AWS
keys are stored anywhere; the pipeline authenticates via OIDC. Every fork gets its own
isolated instance, reachable over HTTPS from anywhere, with its own AWS account, its
own credentials, and its own login.

This is step one of migrating scheduled Claude tasks over to a self-hosted n8n
instance. Today's scope: stand up the server securely and get n8n reachable from the
internet. Workflow migration is a separate, later step.

## Quick Start for Forks

**Prerequisites:** a GitHub account, an AWS account (free tier is enough), and
Terraform + the AWS CLI installed locally — only for the one-time bootstrap step
below. Everything after that runs entirely in GitHub Actions; no local tooling needed
to deploy or manage your instance.

1. **Fork this repo.**
2. **Bootstrap your own AWS account** (once, locally, with your own AWS
   credentials) — see [One-time setup](#one-time-setup-do-this-before-the-first-pipeline-run)
   below. This creates an IAM role that trusts *only your fork* (scoped by
   `github_org`/`github_repo` in `bootstrap/main.tf` to your repo's OIDC subject) — it
   cannot be assumed by anyone else's fork or workflow.
3. **Add the repo secrets** from the table below (Settings → Secrets and variables →
   Actions).
4. **Run the pipeline:** Actions tab → **Deploy n8n** → Run workflow.

Takes about 5–8 minutes end to end. Cost is free-tier eligible on a new AWS account,
otherwise roughly $7–8/month (see [Cost](#cost)). When it finishes, the job summary
prints an HTTPS URL you can open from any device — log in with the
`N8N_OWNER_EMAIL`/`N8N_OWNER_PASSWORD` secrets you set. No public "create account"
screen to race against; the owner account is pre-provisioned before the server is ever
reachable.

## Architecture

```
GitHub Actions (OIDC, no stored keys)
        │
        ▼
Terraform ── creates ──▶  EC2 (Ubuntu 22.04, t3.micro)
        │                    │  IMDSv2 enforced, encrypted root volume
        │                    │  Elastic IP (stable public IP)
        │                    │  Security group: 22 (restricted), 80, 443 only
        ▼                    ▼
Secrets Manager         Ansible ── installs ──▶ Docker + docker compose stack:
  (SSH private key)                                ├─ Postgres   (internal only)
                                                     ├─ n8n        (internal only,
                                                     │              owner account
                                                     │              pre-provisioned)
                                                     └─ Caddy      (exposes 80/443,
                                                                    reverse-proxies to n8n,
                                                                    auto-HTTPS always —
                                                                    your domain if set,
                                                                    otherwise a free
                                                                    <ip>.sslip.io host)
```

n8n itself is never exposed directly — only Caddy is reachable from the internet, and
it proxies to n8n over the private Docker network, always over HTTPS.

## Repo layout

```
bootstrap/     One-time setup: state bucket, lock table, GitHub OIDC provider + IAM role.
               Run manually, once, with your own AWS credentials. Not part of CI.
terraform/     The actual infrastructure (VPC lookup, security group, keypair, EC2, EIP).
               Applied by CI on every pipeline run.
ansible/       Configures the box: Docker, swap file, n8n/Postgres/Caddy via docker compose.
.github/workflows/
  deploy.yml   Main pipeline: preflight checks + terraform apply + ansible-playbook + health check.
  destroy.yml  Manual, confirmation-gated teardown.
```

## One-time setup (do this before the first pipeline run)

### 1. Bootstrap AWS (run locally, once)

You need AWS credentials on your own machine for this one step only — after this, CI
never needs your keys again.

```bash
cd bootstrap
terraform init
terraform apply \
  -var="github_org=<your-github-username-or-org>" \
  -var="github_repo=<this-repo-name>" \
  -var="state_bucket_name=<globally-unique-bucket-name, e.g. pavan-n8n-tfstate>" \
  -var="aws_region=us-east-1"
```

Note the outputs: `role_arn`, `state_bucket`, `lock_table`. You'll need all three below.

### 2. Add GitHub repository secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | `role_arn` output from bootstrap |
| `AWS_REGION` | e.g. `us-east-1` |
| `TF_STATE_BUCKET` | `state_bucket` output from bootstrap |
| `TF_STATE_DYNAMODB_TABLE` | `lock_table` output from bootstrap |
| `SSH_ALLOWED_CIDR` | Your IP in CIDR form, e.g. `203.0.113.5/32` (find yours at `curl ifconfig.me`). Leave unset only if you accept SSH open to the world — the pipeline will warn you if so. |
| `N8N_OWNER_EMAIL` | Email for the n8n owner account (used to log in) |
| `N8N_OWNER_FIRST_NAME` | First name for the owner account |
| `N8N_OWNER_LAST_NAME` | Last name for the owner account |
| `N8N_OWNER_PASSWORD` | Strong password for the owner account. Hashed in CI before it ever reaches the server — never stored or logged in plaintext. |
| `N8N_ENCRYPTION_KEY` | Random 32+ char string (`openssl rand -hex 32`) — n8n uses this to encrypt stored credentials. Keep it stable across runs or you'll lose access to saved credentials. |
| `POSTGRES_PASSWORD` | Strong password for the Postgres container |
| `N8N_DOMAIN` | *(optional)* A domain/subdomain you'll point at the server, e.g. `n8n.example.com`. Leave empty to get automatic HTTPS on a free `<public-ip>.sslip.io` hostname instead — no domain purchase required. |

The pipeline checks these are all set before touching AWS and fails fast with a clear
list of what's missing if not — see [Troubleshooting](#troubleshooting).

### 3. Run the pipeline

Actions tab → **Deploy n8n** → Run workflow. On completion, the job summary prints the
HTTPS URL (and IP) — reachable and usable from any device, anywhere.

## Using your own domain instead of sslip.io

1. Point an A record at the Elastic IP shown in the job summary (`terraform output public_ip`).
2. Add/update the `N8N_DOMAIN` repo secret with that hostname.
3. Re-run the **Deploy n8n** workflow. Caddy will automatically request and renew a
   Let's Encrypt certificate for your domain instead — no other changes needed.

## Destroying the environment

Actions tab → **Destroy n8n infra** → Run workflow → type `DESTROY` in the confirmation
input. This tears down the EC2 instance, EIP, security group, and the SSH key secret.
The Terraform state bucket/lock table from bootstrap are left in place (destroy them
manually if you want to fully clean up).

## Cost

`t3.micro` is free-tier eligible for new AWS accounts (750 hrs/month for 12 months);
outside free tier it's roughly $7-8/month. The Elastic IP is free while attached to a
running instance. S3/DynamoDB state storage is a few cents/month. Set a billing alarm
in your AWS account if you want a safety net — this repo doesn't manage AWS billing
alerts for you.

## Troubleshooting

- **"Deploy blocked — missing secrets" in the job summary:** one or more required
  secrets aren't set. The summary lists exactly which ones — add them and re-run.
- **Health check step fails after Ansible completes:** infrastructure and the docker
  compose stack came up, but n8n isn't answering HTTP requests yet. The workflow dumps
  `docker compose logs` from the server automatically in the step right after the
  failed health check — check that output first. Often just needs another run (the
  pipeline is idempotent — re-running "Deploy n8n" is safe).
- **You land on n8n's own "set up your instance" / create-account screen instead of a
  login form:** the owner pre-provisioning secrets (`N8N_OWNER_EMAIL`/`FIRST_NAME`/
  `LAST_NAME`/`PASSWORD`) weren't picked up — double-check they're set and re-run.
- **SSH doesn't work:** the private key lives only in AWS Secrets Manager
  (`terraform output ssh_private_key_secret_name` in `terraform/`), not in this repo.
  Fetch it with `aws secretsmanager get-secret-value` using your own AWS credentials.

## Security notes

- **No stored AWS keys** — GitHub Actions assumes an IAM role via OIDC, scoped (by the
  bootstrap step) to only this repo's OIDC subject — other forks get their own,
  mutually isolated roles.
- **SSH key never touches the repo** — Terraform generates a fresh keypair per
  environment; the private key lives only in AWS Secrets Manager and briefly in the CI
  runner's memory to hand off to Ansible.
- **IMDSv2 enforced, root volume encrypted**, security group only opens 22 (restrict
  via `SSH_ALLOWED_CIDR`), 80, and 443 — n8n's port 5678 is never exposed publicly.
- **n8n's owner account is pre-provisioned from a bcrypt hash generated in CI** — the
  plaintext password is never written to disk or logged; there's no window where the
  instance is reachable but unclaimed.
- **HTTPS is always on** — either your own domain or a free `sslip.io` hostname, so
  credentials are never sent in cleartext, even from the public IP.
- Rotate `N8N_ENCRYPTION_KEY` only if you're OK losing saved n8n credentials — treat it
  like a master password.
