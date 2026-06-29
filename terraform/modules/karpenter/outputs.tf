output "node_iam_role_name" {
  description = "IAM role name for nodes provisioned by Karpenter"
  value       = module.karpenter.node_iam_role_name
}

output "queue_name" {
  description = "SQS queue name for Karpenter interruption handling"
  value       = module.karpenter.queue_name
}
