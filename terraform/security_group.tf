resource "aws_security_group" "n8n" {
  name        = "${var.project_name}-sg"
  description = "n8n server: SSH (restricted) + HTTP/HTTPS only. n8n's own port is never exposed."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (your CIDR and the current CI runner's IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = distinct(compact([var.allowed_ssh_cidr, var.deploy_runner_cidr]))
  }

  ingress {
    description = "HTTP (Caddy - ACME challenge or redirect to HTTPS or plain mode if no domain)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (Caddy)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}
