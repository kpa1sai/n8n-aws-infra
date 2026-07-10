# Terraform generates a fresh SSH keypair for this environment. The public
# key is registered with AWS; the private key is never written to the repo
# or terraform state in plaintext-on-disk — it's pushed straight into
# Secrets Manager, and the CI job pulls it from there for the Ansible step.

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "n8n" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_secretsmanager_secret" "ssh_private_key" {
  name                    = "${var.project_name}-ssh-private-key"
  description             = "Auto-generated SSH private key for the n8n EC2 instance."
  recovery_window_in_days = 0 # allow immediate deletion on `terraform destroy`
}

resource "aws_secretsmanager_secret_version" "ssh_private_key" {
  secret_id     = aws_secretsmanager_secret.ssh_private_key.id
  secret_string = tls_private_key.ssh.private_key_pem
}
