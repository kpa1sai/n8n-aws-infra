data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "n8n" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.n8n.key_name
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.n8n.id]

  # Enforce IMDSv2 (mitigates SSRF-to-credential-theft attacks).
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Without this, every new Canonical AMI release would make the next apply
  # destroy and recreate the instance — wiping the Docker volumes that hold
  # n8n workflows and the Postgres data. The AMI is only read at first create.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.project_name}"
  }
}

resource "aws_eip" "n8n" {
  instance = aws_instance.n8n.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}
