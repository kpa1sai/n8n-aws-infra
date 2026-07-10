output "public_ip" {
  description = "Elastic IP of the n8n server."
  value       = aws_eip.n8n.public_ip
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.n8n.id
}

output "ssh_private_key_secret_arn" {
  description = "Secrets Manager ARN holding the SSH private key. Ansible pulls the key from here."
  value       = aws_secretsmanager_secret.ssh_private_key.arn
}

output "ssh_private_key_secret_name" {
  description = "Secrets Manager secret name holding the SSH private key."
  value       = aws_secretsmanager_secret.ssh_private_key.name
}
