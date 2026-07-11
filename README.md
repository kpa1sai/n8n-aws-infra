# n8n on AWS — Terraform + Ansible + GitHub Actions

Provisions a single EC2 box on AWS, installs Docker, and runs n8n + Postgres behind a
Caddy reverse proxy — all triggered by a GitHub Actions pipeline. Fork it, add an AWS
key and a handful of secrets, run one workflow, and you get an HTTPS URL reachable from
anywhere. Every fork gets its own isolated instance in its own AWS account, with its
own login preset via environment variables — there is never a public "create account"
screen to race against.

This is step one of migrating scheduled Claude tasks over to a self-hosted n8n
instance. Today's scope: stand up the server securely and get n8n reachable from the
internet. Workflow migration is a separate, later step.

## Quick Start for Forks

**Prerequisites:** a GitHub account and an AWS account (free tier is enough). No local
software to install — everything runs in GitHub Actions and the AWS Console, from any
device.

1. **Fork this repo.**
2. **Create an IAM user + access key in AWS** (see [One-time setup](#one-time-setup) below).
3. **Add the repo secrets** from the table below (Settings → Secrets and variables →
   Actions).
4. **Run the pipeline:** Actions tab → **Deploy n8n** → Run workflow.

Takes about 5–8 minutes end to end. Cost is free-tier eligible on a new AWS account,
otherwise roughly $7–8/month (see [Cost](#cost)). When it finishes, the job summary
prints an HTTPS URL you can open from any device — log in with the
`N8N_OWNER_EMAIL`/`N8N_OWNER_PASSWORD` secrets you set.

## Architecture

```
GitHub Actions (AWS access key from repo secrets)
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
                                                     │              preset via env vars)
                                                     └─ Caddy      (exposes 80/443,
                                                                    reverse-proxies to n8n,
                                                                    auto-HTTPS always —
                                                                    your domain if set,
                                                                    otherwise a free
                                                                    <ip>.sslip.io host)
```

n8n itself is never exposed directly — only Caddy is reachable from the internet, and
it proxies to n8n over the private Docker network, always over HTTPS.

Terraform state lives in an S3 bucket (`n8n-tf-state-<your-account-id>`) that the
pipeline creates automatically on the first run — versioned, encrypted, public access
blocked. No bootstrap step, no state secrets to copy around.

## Repo layout

```
terraform/     The infrastructure (VPC lookup, security group, keypair, EC2, EIP).
               Applied by CI on every pipeline run.
ansible/       Configures the box: Docker, swap file, n8n/Postgres/Caddy via docker compose.
.github/workflows/
  deploy.yml   Main pipeline: preflight checks + terraform apply + ansible-playbook + health check.
  destroy.yml  Manual, confirmation-gated teardown.
```

## One-time setup

### 1. Create an IAM user and access key

In the AWS Console → IAM → Users → Create user (no console access needed). Attach this
policy (IAM → Policies → Create policy → JSON) — it covers everything the pipeline
does and nothing more:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Ec2AndNetworking",
      "Effect": "Allow",
      "Action": "ec2:*",
      "Resource": "*"
    },
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::n8n-tf-state-*",
        "arn:aws:s3:::n8n-tf-state-*/*"
      ]
    },
    {
      "Sid": "SshKeySecret",
      "Effect": "Allow",
      "Action": "secretsmanager:*",
      "Resource": "arn:aws:secretsmanager:*:*:secret:n8n-*"
    }
  ]
}
```

Then: your new user → Security credentials → Create access key → "Third-party
service". Copy the **Access key ID** and **Secret access key** — they go into the repo
secrets below.

### 2. Add GitHub repository secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | The access key ID from step 1 |
| `AWS_SECRET_ACCESS_KEY` | The secret access key from step 1 |
| `AWS_REGION` | Region to deploy into, e.g. `us-east-1` |
| `SSH_ALLOWED_CIDR` | Your IP in CIDR form, e.g. `203.0.113.5/32` (find yours at `curl ifconfig.me`). The pipeline additionally allows the GitHub runner's own IP on port 22 during each run (it needs SSH to run Ansible), refreshed on every deploy. Leave unset only if you accept SSH open to the world — the pipeline will warn you if so. |
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
The Terraform state bucket (`n8n-tf-state-<account-id>`) is left in place so you can
redeploy later; for a full cleanup, empty and delete it in the S3 console and delete
the IAM user.

## Cost

`t3.micro` is free-tier eligible for new AWS accounts (750 hrs/month for 12 months);
outside free tier it's roughly $7-8/month. The Elastic IP is free while attached to a
running instance. S3 state storage is a few cents/month at most. Set a billing alarm
in your AWS account if you want a safety net — this repo doesn't manage AWS billing
alerts for you.

## Troubleshooting

- **"Deploy blocked — missing secrets" in the job summary:** one or more required
  secrets aren't set. The summary lists exactly which ones — add them and re-run.
- **`AccessDenied` / `UnauthorizedOperation` errors:** the IAM user's policy is
  missing something — double-check you attached the policy from
  [One-time setup](#one-time-setup) verbatim.
- **Health check step fails after Ansible completes:** infrastructure and the docker
  compose stack came up, but n8n isn't answering HTTP requests yet. The workflow dumps
  `docker compose logs` from the server automatically in the step right after the
  failed health check — check that output first. Often just needs another run (the
  pipeline is idempotent — re-running "Deploy n8n" is safe).
- **You land on n8n's own "set up your instance" / create-account screen instead of a
  login form:** the owner preset secrets (`N8N_OWNER_EMAIL`/`FIRST_NAME`/
  `LAST_NAME`/`PASSWORD`) weren't picked up — double-check they're set and re-run.
- **SSH doesn't work:** the private key lives only in AWS Secrets Manager
  (`terraform output ssh_private_key_secret_name` in `terraform/`), not in this repo.
  Fetch it with `aws secretsmanager get-secret-value` using your own AWS credentials.

## Security notes

- **The AWS access key never leaves GitHub's encrypted secrets** — it's scoped by the
  IAM policy above to EC2, the Terraform state bucket, and the `n8n-*` Secrets Manager
  entries. Rotate it in IAM → Security credentials whenever you like; just update the
  two repo secrets afterwards.
- **SSH key never touches the repo** — Terraform generates a fresh keypair per
  environment; the private key lives only in AWS Secrets Manager and briefly in the CI
  runner's memory to hand off to Ansible.
- **IMDSv2 enforced, root volume encrypted**, security group only opens 22 (restrict
  via `SSH_ALLOWED_CIDR`), 80, and 443 — n8n's port 5678 is never exposed publicly.
  Port 22 also admits the CI runner's IP (SSH is how Ansible configures the box);
  each deploy replaces the previous runner IP with the current one, and the instance
  only accepts key auth, so a stale runner CIDR is not a practical exposure.
- **n8n's owner account is preset from environment variables** — the password is
  bcrypt-hashed in CI, so plaintext is never written to disk or logged, and there's no
  window where the instance is reachable but unclaimed.
- **HTTPS is always on** — either your own domain or a free `sslip.io` hostname, so
  credentials are never sent in cleartext, even from the public IP.
- Rotate `N8N_ENCRYPTION_KEY` only if you're OK losing saved n8n credentials — treat it
  like a master password.
