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

**Prerequisites:** a GitHub account and an AWS account (free tier is enough). No local
software to install — bootstrapping, deploying, and managing your instance all run
entirely in GitHub Actions and the AWS Console, from any device.

1. **Fork this repo.**
2. **Create a temporary IAM key in AWS** and **bootstrap via GitHub Actions** — see
   [One-time setup](#one-time-setup-do-this-before-the-first-pipeline-run) below. This
   creates an IAM role that trusts *only your fork* (scoped to your repo's OIDC
   subject) — it cannot be assumed by anyone else's fork or workflow. Then delete the
   temporary key — it's not needed again.
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
               A CloudFormation template, applied once via the "Bootstrap n8n infra"
               GitHub Actions workflow — not part of the regular deploy pipeline.
terraform/     The actual infrastructure (VPC lookup, security group, keypair, EC2, EIP).
               Applied by CI on every pipeline run.
ansible/       Configures the box: Docker, swap file, n8n/Postgres/Caddy via docker compose.
.github/workflows/
  bootstrap.yml One-time: creates the state bucket/lock table/OIDC role via CloudFormation.
  deploy.yml   Main pipeline: preflight checks + terraform apply + ansible-playbook + health check.
  destroy.yml  Manual, confirmation-gated teardown.
```

## One-time setup (do this before the first pipeline run)

### 1. Bootstrap AWS (via GitHub Actions, once)

GitHub Actions can't authenticate to a brand-new AWS account with zero credentials —
something has to make the first API call that creates the OIDC trust. That's the one
and only place this repo needs a real AWS key, and only temporarily:

1. In the AWS Console, create an IAM user for one-time use, attach this minimal
   policy (narrow on purpose — everything `Bootstrap n8n infra` needs, nothing more),
   and generate an access key for it:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "CloudFormation",
         "Effect": "Allow",
         "Action": "cloudformation:*",
         "Resource": "*"
       },
       {
         "Sid": "OidcProvider",
         "Effect": "Allow",
         "Action": [
           "iam:CreateOpenIDConnectProvider",
           "iam:GetOpenIDConnectProvider",
           "iam:UpdateOpenIDConnectProviderThumbprint",
           "iam:TagOpenIDConnectProvider",
           "iam:ListOpenIDConnectProviders",
           "iam:DeleteOpenIDConnectProvider"
         ],
         "Resource": "*"
       },
       {
         "Sid": "DeployRole",
         "Effect": "Allow",
         "Action": [
           "iam:CreateRole",
           "iam:GetRole",
           "iam:DeleteRole",
           "iam:UpdateRole",
           "iam:UpdateAssumeRolePolicy",
           "iam:PutRolePolicy",
           "iam:GetRolePolicy",
           "iam:DeleteRolePolicy",
           "iam:ListRolePolicies",
           "iam:ListAttachedRolePolicies",
           "iam:TagRole"
         ],
         "Resource": "*"
       },
       {
         "Sid": "StateBucket",
         "Effect": "Allow",
         "Action": [
           "s3:CreateBucket",
           "s3:PutBucketVersioning",
           "s3:PutEncryptionConfiguration",
           "s3:PutBucketPublicAccessBlock",
           "s3:GetBucketVersioning",
           "s3:GetEncryptionConfiguration",
           "s3:GetBucketPublicAccessBlock",
           "s3:GetBucketPolicy",
           "s3:PutBucketTagging",
           "s3:DeleteBucket"
         ],
         "Resource": "*"
       },
       {
         "Sid": "LockTable",
         "Effect": "Allow",
         "Action": [
           "dynamodb:CreateTable",
           "dynamodb:DescribeTable",
           "dynamodb:DeleteTable",
           "dynamodb:TagResource"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

2. Add the key as two temporary repo secrets: `AWS_BOOTSTRAP_ACCESS_KEY_ID` and
   `AWS_BOOTSTRAP_SECRET_ACCESS_KEY`.
3. Actions tab → **Bootstrap n8n infra** → Run workflow. Takes under a minute.
4. The job summary prints `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`, and
   `TF_STATE_DYNAMODB_TABLE` — copy these into the permanent repo secrets below.
5. **Delete the temporary credentials** — in AWS, delete the access key (and the IAM
   user if you made one just for this); in GitHub, delete the
   `AWS_BOOTSTRAP_ACCESS_KEY_ID`/`AWS_BOOTSTRAP_SECRET_ACCESS_KEY` secrets. Nothing
   after this point ever needs a stored AWS key again — `deploy.yml`/`destroy.yml`
   authenticate via the OIDC role you just created.

Safe to re-run **Bootstrap n8n infra** if it fails partway or you need to change the
allowed branch — it's a CloudFormation stack update, not a create-from-scratch, so it
won't error on "already exists."

### 2. Add GitHub repository secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | From the **Bootstrap n8n infra** job summary |
| `AWS_REGION` | Same region you bootstrapped into, e.g. `us-east-1` — also from the job summary |
| `TF_STATE_BUCKET` | From the **Bootstrap n8n infra** job summary |
| `TF_STATE_DYNAMODB_TABLE` | From the **Bootstrap n8n infra** job summary |
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
The bootstrap resources (state bucket, lock table, OIDC role — the `n8n-bootstrap`
CloudFormation stack) are left in place; delete that stack manually in the AWS Console
if you want to fully clean up (empty the state bucket first — it's versioned and
retained on stack deletion by design, so CloudFormation won't delete it for you).

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
- **`Bootstrap n8n infra` fails with `EntityAlreadyExists` on the OIDC provider:**
  your AWS account already has a `token.actions.githubusercontent.com` OIDC provider
  from another project (AWS allows only one per account). Edit
  `bootstrap/template.yaml`, remove the `GithubOidcProvider` resource, and change
  `GithubActionsDeployRole`'s trust policy `Federated` value to your existing
  provider's ARN instead.
- **Ran `Bootstrap n8n infra` a second time by mistake:** harmless — CloudFormation
  updates the existing `n8n-bootstrap` stack instead of failing on duplicate
  resources.

## Security notes

- **No stored AWS keys for ongoing use** — `deploy.yml`/`destroy.yml` assume an IAM
  role via OIDC, scoped by the bootstrap stack to only this repo's OIDC subject —
  other forks get their own, mutually isolated roles. The only AWS key that ever
  exists is the temporary one used once by `Bootstrap n8n infra`, scoped to a minimal
  custom policy and deleted immediately after (see
  [One-time setup](#one-time-setup-do-this-before-the-first-pipeline-run)).
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
