output "role_arn" {
  description = "Put this in the AWS_ROLE_ARN GitHub secret."
  value       = aws_iam_role.github_actions_deploy.arn
}

output "state_bucket" {
  description = "Put this in the TF_STATE_BUCKET GitHub secret."
  value       = aws_s3_bucket.tf_state.bucket
}

output "lock_table" {
  description = "Put this in the TF_STATE_DYNAMODB_TABLE GitHub secret."
  value       = aws_dynamodb_table.tf_lock.name
}
