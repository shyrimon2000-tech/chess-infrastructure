output "cluster_arn" {
  description = "ARN of the ECS cluster hosting the runner"
  value       = aws_ecs_cluster.runner.arn
}

output "task_definition_arn" {
  description = "ARN of the ECS task definition for the runner"
  value       = aws_ecs_task_definition.runner.arn
}

output "security_group_id" {
  description = "Security group ID to attach to the runner task at launch"
  value       = aws_security_group.runner.id
}

output "run_task_command" {
  description = "AWS CLI command to launch one ephemeral runner (paste into terminal or workflow step)"
  value       = <<-EOT
    aws ecs run-task \
      --cluster ${aws_ecs_cluster.runner.arn} \
      --task-definition ${aws_ecs_task_definition.runner.arn} \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", var.private_subnet_ids)}],securityGroups=[${aws_security_group.runner.id}],assignPublicIp=DISABLED}"
  EOT
}
