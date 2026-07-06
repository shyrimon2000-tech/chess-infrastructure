# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the infrastructure repository for a chess web application composed of four microservices. It is the final deployment layer that unifies all services into a running Kubernetes cluster.

**Microservices (images hosted on ghcr.io/shyrimon2000-tech/):**
- `chess-auth-service` — authentication, JWT issuance, user management
- `chess-room-service` — matchmaking, room lifecycle (2 replicas)
- `chess-game-service` — game logic, move processing (3 replicas — stateful game sessions)
- `chess-frontend-service` — React/static frontend

All backend services run on port `8000` and expose a `/health` endpoint used by both readiness and liveness probes.

**Completed layers:**
- `k8s/` — raw Kubernetes manifests (deployments, statefulsets, secrets, configmaps)
- `helm/` — Helm charts wrapping the raw manifests
- `terraform/` — cloud infrastructure provisioning via Terragrunt (VPC + EKS modules, shared/prod environments)

**Planned additions:**
- `.github/workflows/` — CD pipeline (3-layer architecture, see GitHub Actions section below)

## Secrets & Config Management

**Pattern:** actual files are gitignored; templates live in `*.example` directories.

| Gitignored (real values) | Tracked (templates) |
|---|---|
| `k8s/secrets/` | `k8s/secrets.example/` |
| `k8s/configmaps/` | `k8s/configmaps.example/` |

To bootstrap a new environment, copy templates and fill in real values:
```bash
cp k8s/secrets.example/<name>.yaml k8s/secrets/<name>.yaml
cp k8s/configmaps.example/<name>.yaml k8s/configmaps/<name>.yaml
# then edit the copies with real credentials
```

**Secrets per service:**
- `<service>-secret` — `DATABASE_URL`, `JWT_SECRET_KEY`
- `<service>-db-secret` — MySQL root password, user, password, database name
- `ghcr-secret` — `kubernetes.io/dockerconfigjson` for pulling images from ghcr.io

**ConfigMaps per service:**
- `<service>-configmap` — `JWT_ALGORITHM`, `ACCESS_TOKEN_EXPIRE_MINUTES`, `REFRESH_TOKEN_EXPIRE_DAYS`

## Applying Manifests

Apply in this order (dependencies first):

```bash
# 1. Registry pull secret (required by all deployments)
kubectl apply -f k8s/secrets/ghcr-secret.yaml

# 2. Per-service: secret → db-secret → configmap → statefulset → deployment
kubectl apply -f k8s/secrets/auth-secret.yaml
kubectl apply -f k8s/secrets/auth-db-secret.yaml
kubectl apply -f k8s/configmaps/auth-configmap.yaml
kubectl apply -f k8s/statefulsets/auth-db.yaml
kubectl apply -f k8s/deployments/auth-deployment.yaml

# Or apply an entire directory at once (order within dir is not guaranteed)
kubectl apply -f k8s/secrets/ -f k8s/configmaps/ -f k8s/statefulsets/ -f k8s/deployments/
```

Check rollout status:
```bash
kubectl rollout status deployment/<name>-deployment
kubectl get pods -l app=chess-<name>-service
kubectl logs -l app=chess-<name>-service --tail=50
```

## Architecture Conventions

**StatefulSets** are used only for databases (MySQL 8.0). Each DB gets its own StatefulSet with a headless service and a 5Gi PVC. Services connect to their own dedicated DB — there is no shared database.

**Deployments** reference secrets and configmaps exclusively via `envFrom` — no hardcoded env vars in manifests. Any new env var must go into a Secret or ConfigMap.

**Image tags** in deployments are pinned to explicit versions (e.g., `1.1.0`), not `latest`. When bumping a service version, update the tag in the corresponding deployment manifest.

**Replica counts reflect expected load:**
- `chess-auth-service`: 1 (low frequency, stateless)
- `chess-room-service`: 2 (moderate traffic)
- `chess-game-service`: 3 (high frequency, each pod handles active game sessions)
- `chess-frontend-service`: to be defined

## Git Workflow

- Every task starts on a new feature branch off `dev`
- Merges into `dev` happen only with explicit user approval
- **Never create commits autonomously.** When work is ready, suggest what to stage and propose a commit message — the user runs the command themselves
- Never push without explicit instruction

## Collaboration Style

The user is learning infrastructure engineering hands-on. The goal is to build their mental model, not deliver finished solutions.

- Ask guiding questions instead of writing solutions unless the user explicitly asks ("покажи", "сгенерируй", "напиши")
- Explain *why* a pattern exists, not just what it does
- Point out when something is fine for a personal project but would differ in a production team context

## Terraform / AWS Architecture Decisions

### Environments

| Environment | VPC CIDR | EKS Cluster | Database |
|-------------|----------|-------------|----------|
| shared (dev+staging) | 10.0.0.0/16 | chess-shared | MySQL StatefulSet in-cluster on EBS |
| prod | 192.168.0.0/16 | chess-prod | RDS MySQL Multi-AZ (1-year RI) |

### EKS Compute Strategy

Two-tier compute model:

**Tier 1 — Fargate (system components, no DaemonSets needed):**
- Karpenter controller
- ArgoCD
- Grafana

**Tier 2 — EC2 via Karpenter (app workloads):**
- All chess microservices
- Prometheus (on minimum on-demand node — bin-packed with app services)
- node-exporter DaemonSet (metrics collection — no `/metrics` endpoints on chess services)

Rationale: eliminates the `infra` node group (t3.medium × 3 = ~$90/mo), saving ~$65–75/mo via Fargate for system components.

### Karpenter NodePool

Single `general` NodePool — all chess services bin-packed on the same nodes.

| Environment | Capacity type | Instance families |
|-------------|--------------|-------------------|
| shared (dev+staging) | Spot | t3, t3a (medium + large, x86 only) |
| prod | on-demand | t3, t3a (medium + large, x86 only) |

- ARM instances (t4g) excluded — chess service images are amd64 only
- Consolidation: `WhenEmptyOrUnderutilized`, consolidateAfter 30s
- Node limits: 8 CPU / 32Gi memory
- room-service uses Redis → cannot tolerate Spot interruptions → prod on-demand
- game-service → prod on-demand. Game state itself is persisted to the DB, so a Spot interruption wouldn't lose data — but the client's reconnect window is a hard 30s timeout: if the pod isn't back up and ready (new node provisioned + scheduled + started + passed readiness) within that window, the player is disconnected and recorded as a loss. A Spot interruption's full notice-to-reschedule cycle can easily exceed 30s, so the risk isn't data loss, it's a real, scored game loss for the player.

### Networking

- **EKS endpoint:** public (`endpoint_public_access = true`), no CIDR restriction — GitHub-hosted runners have no fixed IP range to allowlist, so access control is enforced entirely via EKS access entries scoped to specific IAM principal ARNs (same mechanism as personal admin access), not network reachability.
- **Access to cluster:** GitHub-hosted Actions runner, authenticated via AWS OIDC federation — no self-hosted runner needed now that the endpoint is public (see GitHub Actions section)
- **Node access:** SSM Session Manager — no SSH, no port 22, sessions logged to CloudTrail
- **NAT Gateway:** single NAT (known SPOF, acceptable for current stage)
- **Security Groups:** created automatically by `terraform-aws-modules/eks/aws` — no manual SG resources needed
- **VPC Endpoints:** to evaluate — S3 Gateway (free) reduces NAT traffic for ECR image layers

### Ingress

Single ALB for all services with path-based routing:
- `/api/auth/*` → auth-service
- `/api/room/*` → room-service
- `/api/game/*` → game-service (WebSocket supported natively by ALB)
- `/` → frontend-service

NLB rejected: 1ms latency difference not meaningful for chess; ALB simplifies routing.

### Monitoring

- **node-exporter DaemonSet** on EC2 nodes — sole metrics source (chess services have no `/metrics` endpoints)
- **Prometheus** on compute-pool EC2 node with PVC (EBS) for metric retention
- **Grafana** on Fargate

### Storage

EBS CSI Driver required in both clusters:
- Dev/Staging: PVC for in-cluster MySQL StatefulSets
- Prod: PVC for Prometheus and Grafana

### Database

- **Dev/Staging:** MySQL 8.0 StatefulSet in-cluster, 5Gi EBS PVC per service
- **Prod:** RDS MySQL Multi-AZ, 1-year Reserved Instance (~$40–50/mo)
- Aurora Serverless v2 rejected for prod: more expensive under predictable steady load

## GitHub Actions CD Architecture

Two independent pieces: infra apply (Terraform/Terragrunt, this section) and app delivery (ArgoCD, its own pipeline below).

### Infra apply — GitHub-hosted runner + OIDC
- **Runner:** standard `ubuntu-latest` (GitHub-hosted, public internet) — no self-hosted runner. A self-hosted in-VPC runner (previously ECS Fargate) was only ever needed to reach a *private* EKS endpoint; once the endpoint is public, a GitHub-hosted runner can reach it directly.
- **Auth:** AWS OIDC federation (`token.actions.githubusercontent.com`), no long-lived credentials. Trust policy scoped per branch — one IAM role trusted only for `ref:refs/heads/dev` (shared environment permissions) and a separate role trusted only for `ref:refs/heads/main` (prod environment permissions), so a workflow run on one branch can never assume the other environment's credentials.
- **Trigger flow:** `pull_request` into `dev`/`main` runs a `terragrunt plan` job, required as a passing branch-protection status check before merge is allowed. Merging (`push` to `dev`/`main`) runs `terragrunt apply`. Plan never applies unreviewed changes; apply never runs without a passing plan on the merged commit.
- **State isolation:** shared and prod are separate Terraform state files (S3 backend, distinct `key` per terragrunt unit) — a plan/apply on one environment can't race with or corrupt the other's state.
- **State locking:** S3 backend native locking (`use_lockfile = true` in `root.hcl`) — no DynamoDB table needed; this is the current S3-backend locking mechanism, replacing the older DynamoDB-table pattern.

### App delivery — ArgoCD
- **Trigger:** git push → ArgoCD watches repo
- **Does:** syncs chess microservices, configs, secrets
- **Runs on:** ArgoCD pod on Fargate (already inside the cluster)

### Key decisions
- No self-hosted runner: once the EKS endpoint is public, the ECS Fargate runner's only reason to exist (private-VPC network access) no longer applies — dropping it also removes an entire category of bootstrap problems (custom runner image with terraform/kubectl/helm baked in, an EKS access entry + security-group rule for the runner, GitHub App runner-registration permissions). `terraform/modules/ecs-runner` and its `environments/{shared,prod}/ecs-runner` units (dead code left over from the earlier design) have been removed.
- Public endpoint is a network-reachability change only, not an authorization change — access is still gated by EKS access entries scoped to specific IAM principal ARNs, same mechanism as before.
- ArgoCD replaces any per-service apply workflow — Terraform only provisions infrastructure

## AWS Guidance

When working with AWS services, apply reasoning at the level of an AWS Solutions Architect Associate (SAA):

- Recommend well-architected patterns (right service for the job, cost vs. performance tradeoffs)
- Consider multi-AZ, IAM least privilege, VPC design, and managed vs. self-hosted tradeoffs
- Prefer managed services (RDS, ElastiCache, ALB) over self-managed equivalents where operationally justified
- Flag when a choice is acceptable for a pet project but would differ in a production team context
