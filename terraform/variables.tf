variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix used for tagging/naming resources."
  type        = string
  default     = "n8n-server"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22. Restrict this to your own IP/32 via the SSH_ALLOWED_CIDR secret."
  type        = string
  default     = "0.0.0.0/0"
}

variable "deploy_runner_cidr" {
  description = <<-EOT
    CIDR of the CI runner executing this deploy, also allowed on port 22 —
    the pipeline itself connects over SSH to run Ansible, and GitHub-hosted
    runners get a fresh IP each run. Refreshed (replaced, not accumulated)
    on every apply. Empty = no extra CIDR (local runs).
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 20
}
