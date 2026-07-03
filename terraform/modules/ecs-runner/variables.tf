variable "name" {
  description = "Name prefix for runner resources (e.g. chess-shared)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the runner task will run"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used in the run-task command output"
  type        = list(string)
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. shyrimon2000-tech/chess-infrastructure)"
  type        = string
}

variable "runner_image" {
  description = "Docker image for the GitHub Actions runner — pin to a specific tag, not latest"
  type        = string
  default     = "myoung34/github-runner:latest"
}

variable "cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 2048
}
