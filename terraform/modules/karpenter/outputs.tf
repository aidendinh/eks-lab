output "queue_name" {
  description = "Interruption queue name, passed to the controller as settings.interruptionQueue."
  value       = aws_sqs_queue.interruption.name
}

output "controller_role_arn" {
  description = "IAM role assumed by the Karpenter controller via Pod Identity."
  value       = aws_iam_role.controller.arn
}
