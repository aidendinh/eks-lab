output "file_system_id" {
  description = "EFS filesystem id; the StorageClass needs it to provision access points dynamically."
  value       = aws_efs_file_system.this.id
}

output "security_group_id" {
  description = "Security group attached to the mount targets."
  value       = aws_security_group.this.id
}
