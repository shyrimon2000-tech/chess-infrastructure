variable "name" {
  description = "Name prefix for this ArgoCD instance (e.g. chess-shared) — used to derive its SSM parameter path"
  type        = string
}

variable "argocd_version" {
  description = "ArgoCD Helm chart version (verify current release before apply — see argo-helm releases)"
  type        = string
  default     = "7.7.11"
}

variable "repo_url" {
  description = "Git repository ArgoCD watches for the chess-chart Helm chart"
  type        = string
  default     = "https://github.com/shyrimon2000-tech/chess-infrastructure.git"
}

variable "gitops_dir" {
  description = "Subfolder under helm/git-ops/ this instance's root Application watches (e.g. \"shared\", \"prod\") — contains the hand-written ApplicationSet YAML for this instance's sync-policy buckets."
  type        = string
}

variable "gitops_target_revision" {
  description = "Git branch the root Application (and everything it generates) tracks — dev for shared (dev+staging), main for prod. Matches the per-environment targetRevision already hardcoded inside each bucket's ApplicationSet YAML."
  type        = string
  default     = "dev"
}

variable "ingress_enabled" {
  description = "Whether to create an Ingress for the ArgoCD server (requires an ingress controller already installed, e.g. ingress-nginx)"
  type        = bool
  default     = false
}

variable "ingress_class_name" {
  description = "IngressClassName for the ArgoCD server Ingress"
  type        = string
  default     = "nginx"
}

variable "ingress_hostname" {
  description = "Hostname for the ArgoCD server Ingress"
  type        = string
  default     = "argocd.chess.internal"
}

variable "app_projects" {
  description = "Map of AppProject name suffix -> namespaces it's allowed to deploy chess-chart Applications into. Each key becomes an AppProject named \"<name>-<key>\" (name = var.name). E.g. shared: { \"apps-dev\" = [\"dev\"], \"apps-staging\" = [\"staging\"] } — split per namespace so a bug in the auto-syncing dev bucket can't land in staging. prod: { \"apps\" = [\"production\"] } — single namespace, no split needed."
  type        = map(list(string))
}
