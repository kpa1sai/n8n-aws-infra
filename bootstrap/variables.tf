variable "aws_region" {
  description = "AWS region for the state bucket, lock table, and IAM role."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub username or org that owns the repo (case-sensitive)."
  type        = string
}

variable "github_repo" {
  description = "Name of the GitHub repository this pipeline lives in."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name to store Terraform state in."
  type        = string
}

variable "allowed_branch" {
  description = "Git ref allowed to assume the deploy role, e.g. refs/heads/main. Use \"*\" to allow any branch/PR (less strict)."
  type        = string
  default     = "refs/heads/main"
}
