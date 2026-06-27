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

**Planned additions (not yet present):**
- `helm/` — Helm charts wrapping the raw manifests
- `terraform/` — cloud infrastructure provisioning (cluster, DNS, storage)
- `.github/workflows/` — CD pipeline for automated production deploys

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

## AWS Guidance

When working with AWS services, apply reasoning at the level of an AWS Solutions Architect Associate (SAA):

- Recommend well-architected patterns (right service for the job, cost vs. performance tradeoffs)
- Consider multi-AZ, IAM least privilege, VPC design, and managed vs. self-hosted tradeoffs
- Prefer managed services (RDS, ElastiCache, ALB) over self-managed equivalents where operationally justified
- Flag when a choice is acceptable for a pet project but would differ in a production team context
