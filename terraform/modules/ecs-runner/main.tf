locals {
  github_owner         = split("/", var.github_repo)[0]
  ssm_app_id_arn       = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name}/github-runner/app-id"
  ssm_app_private_key_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name}/github-runner/app-private-key"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── ECS Cluster ────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "runner" {
  name = "${var.name}-github-runner"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/ecs/${var.name}-github-runner"
  retention_in_days = 7
}

# ── IAM — Execution Role (ECS pulls image, writes logs, reads SSM) ─────────────

resource "aws_iam_role" "execution" {
  name = "${var.name}-runner-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_standard" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_ssm" {
  name = "ssm-runner-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "ssm:GetParameters"
      Resource = [
        local.ssm_app_id_arn,
        local.ssm_app_private_key_arn,
      ]
    }]
  })
}

# ── IAM — Task Role (what the runner can do in AWS while executing jobs) ────────
# AdministratorAccess used because the runner applies Terraform across all modules.
# Scope this down once the full module list is stable.

resource "aws_iam_role" "task" {
  name = "${var.name}-runner-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_admin" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── Security Group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "runner" {
  name        = "${var.name}-github-runner"
  description = "GitHub Actions Fargate runner — egress HTTPS only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to GitHub API and AWS APIs"
  }
}

# ── ECS Task Definition ────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "runner" {
  family                   = "${var.name}-github-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name  = "github-runner"
    image = var.runner_image

    environment = [
      { name = "RUNNER_SCOPE",        value = "repo" },
      { name = "REPO_URL",            value = "https://github.com/${var.github_repo}" },
      { name = "APP_LOGIN",           value = local.github_owner },
      { name = "LABELS",              value = "self-hosted,fargate,linux,x64" },
      { name = "RUNNER_NAME_PREFIX",  value = "${var.name}-fargate" },
      { name = "EPHEMERAL",           value = "true" },
      { name = "DISABLE_AUTO_UPDATE", value = "true" },
    ]

    secrets = [
      { name = "APP_ID",          valueFrom = local.ssm_app_id_arn },
      { name = "APP_PRIVATE_KEY", valueFrom = local.ssm_app_private_key_arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.runner.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "runner"
      }
    }
  }])
}
