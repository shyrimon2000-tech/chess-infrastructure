# chess-infrastructure

Kubernetes infrastructure for a chess web application. This repository is the final deployment layer that unifies four microservices into a running cluster.

## Architecture

Four microservices deployed on Kubernetes:

| Service | Image | Replicas | Description |
|---|---|---|---|
| `chess-auth-service` | `ghcr.io/shyrimon2000-tech/chess-auth-service` | 1 | Authentication, JWT, user management |
| `chess-room-service` | `ghcr.io/shyrimon2000-tech/chess-room-service` | 2 | Matchmaking, room lifecycle |
| `chess-game-service` | `ghcr.io/shyrimon2000-tech/chess-game-service` | 3 | Game logic, WebSocket, move processing |
| `chess-frontend-service` | `ghcr.io/shyrimon2000-tech/chess-frontend-service` | 1 | React/static frontend |

Each backend service runs on port `8000`. MySQL 8.0 per service (no shared database). Redis for game state pub/sub.

## Environments

| | Dev | Staging | Prod |
|---|---|---|---|
| Cluster | EKS shared | EKS shared | EKS dedicated |
| Namespace | `dev` | `staging` | `default` |
| Frontend | container | container | S3 + CloudFront |
| Database | in-cluster MySQL | in-cluster MySQL | RDS |
| Redis | in-cluster | in-cluster | ElastiCache |
| DB Storage | EBS gp3 | EBS gp3 | managed (RDS) |
| HPA | disabled | enabled | enabled |
| Replicas | 1 per service | minReplicas (HPA) | minReplicas (HPA) |
| ResourceQuota | low (1 replica) | based on maxReplicas | based on maxReplicas |
| Ingress | nginx | nginx | ALB |
| Secrets | plain Secret | plain Secret | ESO → AWS Secrets Manager |

### Network Policy egress

Service pods (auth, game, room) have egress rules that adapt to the environment:

- **Dev / Staging** (`db.enabled: true`) — egress to database and Redis pods is restricted by `podSelector`, allowing traffic only to the specific in-cluster pods.
- **Prod** (`db.enabled: false`) — egress uses `ipBlock` with a configurable VPC CIDR (`db.cidr` for RDS on port 3306, `redisCidr` for ElastiCache on port 6379), restricting outbound traffic to the VPC private subnets only. Default placeholder is `10.0.0.0/16` — replace with the actual subnet CIDRs once the VPC is provisioned by Terraform.

This is controlled automatically via the `db.enabled` flag — no manual NetworkPolicy changes needed when switching environments.

### HPA Configuration (Staging / Prod)

| Service | Min Replicas | Max Replicas | Target CPU |
|---|---|---|---|
| auth | 1 | 3 | 70% |
| room | 2 | 4 | 65% |
| game | 3 | 6 | 60% |

Game has the lowest CPU threshold (60%) because it handles real-time WebSocket connections — scaling earlier avoids latency spikes under load.

### ResourceQuota

| | Dev | Staging | Prod |
|---|---|---|---|
| requests.cpu | 1300m | 3100m | 2300m |
| requests.memory | 2900Mi | 5000Mi | 2700Mi |
| limits.cpu | 2700m | 6500m | 4900m |
| limits.memory | 4200Mi | 8200Mi | 5300Mi |

Prod quota is lower than staging despite having HPA enabled — no in-cluster MySQL pods (3 × 200m CPU / 600Mi each) since databases run on RDS.

### Access

**Dev / Staging** — internal only, not exposed to the internet.

- **CI/CD access** — self-hosted ECS Fargate runner in private subnet (runs `terragrunt apply`, `helm`, `kubectl`)
- **Admin/developer access** — WireGuard VPN into the VPC (`vpn-shared.<domain>` / `vpn-prod.<domain>`, wg-easy + Caddy on EC2 in the public subnet, SSM-only — no SSH). Split-tunnel: only the VPC CIDR routes through the tunnel, not `0.0.0.0/0`.

Hostnames (Route53 private hosted zone `chess.internal`, associated with the shared VPC):
- `dev.chess.internal` → dev namespace
- `staging.chess.internal` → staging namespace
- `argocd.chess.internal` → ArgoCD UI (shared instance)

All three point to the same internal NLB (ingress-nginx on Fargate). Traffic stays within the VPC — resolvable only once connected to the VPN, since the DNS server pushed to VPN peers is the VPC resolver.

**Prod** — public via ALB + Route53 public hosted zone. TLS terminated at the ALB.

## Project Roadmap

- [x] Kubernetes manifests — secrets, configmaps, statefulsets, deployments, services, ingress, network policies, resource quota, limit range
- [x] Helm charts — packaging manifests for reusable deployment
- [x] Terraform — cloud infrastructure provisioning (VPC, EKS, Karpenter, NodePools, ECS runner)
- [ ] GitHub Actions — CD pipeline (3-layer architecture, ECS runner written)

## Terraform

Cloud infrastructure provisioned with Terraform + Terragrunt. State stored in S3 (`chess-terraform-state-221556121262`, us-east-1, versioning enabled).

### Prerequisites (anyone reusing this repo, read this first)

None of the values below are committed — the repo is safe to fork/publish, but `terragrunt apply` will fail (or silently skip an optional feature) until you provide them yourself.

**Environment variable — set before every apply:**

| Variable | Purpose | How to get it |
|---|---|---|
| `ADMIN_PRINCIPAL_ARN` | Your personal IAM principal — granted an EKS access entry (`AmazonEKSClusterAdminPolicy`) so `kubectl` keeps working once applies move to CI and `enable_cluster_creator_admin_permissions` no longer covers you | `aws sts get-caller-identity --query Arn --output text` |

Not committed on purpose: it pairs your AWS account ID with a specific IAM username — more targeted information than the account ID alone (which is already visible in the state bucket name, see below).

**SSM SecureString parameters — create manually per environment before apply** (Terraform only reads these, never creates them — same reasoning as the state bucket: bootstrap secrets can't be managed by the tool that needs them to authenticate):

| Path | Used by |
|---|---|
| `/chess-shared/github-runner/app-id`, `/chess-shared/github-runner/app-private-key` | ecs-runner (GitHub App credentials) |
| `/chess-prod/github-runner/app-id`, `/chess-prod/github-runner/app-private-key` | ecs-runner (GitHub App credentials) |
| `/chess-shared/vpn/wg-easy-password-hash` | vpn (wg-easy admin panel login) |
| `/chess-prod/vpn/wg-easy-password-hash` | vpn (wg-easy admin panel login) |
| `/chess-shared/argocd/admin-password-hash` | argocd (`admin` login for the ArgoCD UI) |
| `/chess-prod/argocd/admin-password-hash` | argocd (`admin` login for the ArgoCD UI) |

Generate a wg-easy password hash with: `docker run ghcr.io/wg-easy/wg-easy wgpw '<password>'`

Generate an ArgoCD admin password hash with: `argocd account bcrypt --password '<password>'` (requires the `argocd` CLI)

**Domain you must own:** the `vpn` module assumes a public Route53 hosted zone already exists (`alexit.online` by default, override via `public_domain` input) — it only adds `vpn-shared`/`vpn-prod` A records into it, it does not create the zone itself.

### Bootstrap (one-time, per AWS account)

These resources must exist before the first `terragrunt apply`. They store Terraform state and locks — they cannot be managed by Terraform itself (chicken-and-egg).

```bash
# S3 bucket for state (versioning enabled, encryption at rest)
aws s3api create-bucket \
  --bucket chess-terraform-state-221556121262 \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket chess-terraform-state-221556121262 \
  --versioning-configuration Status=Enabled
```

State locking uses native S3 conditional writes (`use_lockfile = true` in `terraform/root.hcl`) — no DynamoDB table required. Requires Terraform ≥ 1.10.

**One-time: EC2 Spot Service-Linked Role** (needed by Karpenter to launch Spot instances — one per AWS account):

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

Skip if the role already exists — the command returns an error but that is harmless.

### Structure

```
terraform/
├── root.hcl                        # S3 backend + AWS provider (generated per environment)
├── modules/
│   ├── vpc/                        # VPC module
│   ├── eks/                        # EKS cluster + Fargate profiles + personal access entry
│   ├── karpenter/                  # Karpenter IAM + SQS + Helm chart
│   ├── nodepools/                  # EC2NodeClass + NodePool CRDs
│   ├── ecs-runner/                 # Self-hosted GitHub Actions runner on ECS Fargate
│   ├── ingress-nginx/              # Internal NLB ingress controller (shared only)
│   ├── route53/                    # Private hosted zone (chess.internal) — dev/staging/argocd records
│   ├── vpn/                        # WireGuard (wg-easy + Caddy) — SSM-only EC2, public subnet
│   └── argocd/                     # ArgoCD + chess-chart ApplicationSet (GitOps bootstrap)
└── environments/
    ├── shared/                     # dev + staging (one cluster, separate namespaces)
    │   ├── vpc/                    # 10.0.0.0/16
    │   ├── eks/                    # chess-shared cluster
    │   ├── karpenter/              # Karpenter on Fargate
    │   ├── nodepools/              # Spot instances
    │   ├── ecs-runner/             # Fargate runner in shared VPC — excluded from run-all, building last
    │   ├── ingress-nginx/          # internal NLB
    │   ├── route53/                # chess.internal private zone
    │   ├── vpn/                    # vpn-shared.<domain>
    │   └── argocd/                 # dev (automated+prune) + staging (manual)
    └── prod/
        ├── vpc/                    # 192.168.0.0/16
        ├── eks/                    # chess-prod cluster
        ├── karpenter/              # Karpenter on Fargate
        ├── nodepools/              # on-demand instances
        ├── ecs-runner/             # Fargate runner in prod VPC — excluded from run-all, building last
        ├── vpn/                    # vpn-prod.<domain>
        └── argocd/                 # prod (manual sync)
```

Apply order (Layer 0 — GitHub-hosted runner): `vpc → ecs-runner` — **deferred**: `ecs-runner` units have `exclude { if = true, actions = ["all"] }` in their terragrunt.hcl and are skipped by `run-all`. Building it last, once everything else is stable and applying manually stops being enough.

Apply order (Layer 1 — self-hosted Fargate runner): `eks → vpn → karpenter → nodepools → ingress-nginx → route53 → argocd`

EKS API endpoint is currently `endpoint_public_access = true` — temporary, while still applying from a laptop and before the VPN module has actually been applied and connected. `vpc`, `eks`, and `vpn` only call AWS APIs, so they can be applied from anywhere regardless. `karpenter`, `nodepools`, `ingress-nginx`, and `argocd` use the `helm`/`kubectl` Terraform providers, which need a live connection to the cluster's Kubernetes API — once the VPN is applied and connected, flip `endpoint_public_access` to `false` and apply those only through the tunnel (or from the ECS runner, which already sits inside the VPC).

### Architectural Decisions

**VPC**
- Two VPCs: `shared` (10.0.0.0/16) for dev+staging, `prod` (192.168.0.0/16) for production
- 3 public + 3 private subnets across 3 AZs in each VPC
- `prod` additionally has 3 database subnets for RDS
- Single NAT gateway per VPC (cost optimization — acceptable for this project scale)

**EKS — two-tier compute model**

No managed node groups. System components run on Fargate, app workloads on EC2 provisioned by Karpenter.

| Tier | Components | Compute |
|------|-----------|---------|
| Fargate | Karpenter controller, ArgoCD, Grafana, CoreDNS, ingress-nginx (shared only) | Fargate micro-VM per pod |
| EC2 (Karpenter) | All chess microservices, Prometheus | Spot (shared) / on-demand (prod) |

- API endpoint: currently `endpoint_public_access = true` (temporary, still applying from a laptop). Will be set to private-only once the VPN is applied and connected — or the ECS runner is in place, whichever comes first.
- IRSA used for Karpenter and EBS CSI Driver (pod identity agent not available on Fargate at time of writing)
- Addons: CoreDNS (Fargate), kube-proxy, VPC CNI, EBS CSI Driver
  - CoreDNS runs on Fargate via `kube-system` Fargate profile (label: `k8s-app=kube-dns`) — bootstraps DNS before Karpenter provisions EC2 nodes
  - EBS CSI Driver: IRSA role with `AmazonEBSCSIDriverPolicy`; controller anti-affinity disabled so both replicas bin-pack on one node
  - VPC CNI (`aws-node`): `nodeSelector: eks.amazonaws.com/compute-type=ec2` — prevents DaemonSet pods from going Pending on Fargate virtual nodes

**Karpenter**
- Single `general` NodePool — all chess services bin-packed on the same nodes
- Instance types: t3/t3a medium+large (x86, amd64 only)
- **shared**: Spot instances — cost optimized, interruptions acceptable in dev/staging
- **prod**: on-demand instances — no interruptions for active game sessions and room state (Redis)
- Consolidation: `WhenEmptyOrUnderutilized` + 30s (shared), `WhenEmpty` + 5m (prod)
- Node limits: 8 CPU / 32Gi per cluster (parametrized via `cpu_limit` / `memory_limit` inputs)
- `time_sleep` (90s) on NodePool destroy — gives Karpenter time to drain and terminate EC2 nodes before Karpenter itself is uninstalled; without this, instances are orphaned and block Security Group deletion
  - Karpenter's NodeClaim/Node objects do carry a finalizer that blocks deletion until the instance is actually terminated, and `kubectl_manifest` (provider `alekc/kubectl`) waits on that finalizer rather than firing-and-forgetting — but the exact wait timeout wasn't verifiable from provider source, so it isn't a guaranteed substitute for the sleep
  - `time_sleep` is a fixed guess, not a real wait condition — acceptable for a pet project, but in production this should be a `null_resource` + `local-exec` (`when = destroy`) polling `aws ec2 describe-instances` for the actual termination state instead of trusting a duration

**Frontend**
- Prod: S3 + CloudFront (static assets, no pod in cluster)
- Dev / Staging: container in EKS (shared cluster)

**ArgoCD / GitOps**
- One `ApplicationSet` per ArgoCD instance (`chess-chart`), `list` generator + `goTemplate: true` — each environment is one entry (name, namespace, values file, branch, sync policy), not a hand-written `Application` per env
- Bootstrap (the `ApplicationSet` itself) is created by Terraform (`kubectl_manifest`), not a manual one-time `kubectl apply` — keeps `terragrunt apply` alone sufficient to rebuild the whole GitOps loop from zero. Everything downstream (image tags, replicas, values) still flows through git only.
- Branch mapping: dev + staging watch the `dev` branch, prod watches `main`
- Sync policy: dev = automated + prune (no selfHeal — keeps live `kubectl` debugging possible without instant revert), staging + prod = manual
- `server.insecure = true` when ingress is enabled — argocd-server's own self-signed TLS would otherwise mismatch nginx's plain-HTTP proxy to the backend; acceptable since traffic is already inside the VPN tunnel + private VPC
- No verified community Terraform module exists for ArgoCD — installed via raw `helm_release` (argo-helm chart), same as Karpenter

### Progress

| Module | Status |
|---|---|
| S3 state bucket | done (manual) |
| VPC (shared + prod) | applied ✓ |
| EKS (shared + prod) | applied ✓, smoke-tested on shared |
| Karpenter (shared + prod) | applied ✓, smoke-tested on shared |
| NodePools (shared + prod) | applied ✓, smoke-tested on shared |
| ECS runner (shared + prod) | written, **deferred on purpose** (`exclude` in terragrunt.hcl) — building last |
| ingress-nginx (shared) | written, validate ✓, not yet applied |
| Route53 private zone (shared) | written, validate ✓, not yet applied |
| VPN — WireGuard (shared + prod) | written, validate ✓, not yet applied |
| ArgoCD (shared + prod) | written, validate ✓, not yet applied |
| RDS (prod) | not started |
| ElastiCache / Redis (prod) | not started |
| ALB Ingress Controller (prod) | not started |
| Route53 public zone (prod) | not started |
| S3 + CloudFront (prod frontend) | not started |

> Shared environment was applied and smoke-tested, then torn down. Prod environment not yet applied. Full apply will run via GitHub Actions CD once the pipeline is wired up.

## GitHub Actions CD

Three-layer deployment model. Each layer is independent — no circular dependencies.

| Layer | Workflow | Runner | Does |
|---|---|---|---|
| 0 — Bootstrap | `bootstrap-infrastructure.yml` | GitHub-hosted (`ubuntu-latest`) | `terragrunt apply` for VPC + ECS runner |
| 1 — Cluster | `deploy-cluster.yml` | Self-hosted ECS Fargate (private subnet) | `terragrunt apply` for EKS → Karpenter → NodePools |
| 2 — App delivery | ArgoCD (git push trigger) | ArgoCD pod on Fargate | Syncs chess microservices |

Layer 0 uses a standard GitHub-hosted runner because VPC and ECS runner do not require access to the EKS private API. Once the ECS runner is provisioned, Layer 1 runs inside the VPC where the private EKS endpoint is reachable.

Auth: AWS OIDC — no long-lived credentials stored in GitHub secrets.

---

## Repository Structure

```
k8s/
├── secrets/            # gitignored — real values
├── secrets.example/    # tracked — templates
├── configmaps/         # gitignored — real values
├── configmaps.example/ # tracked — templates
├── statefulsets/       # MySQL per service + Redis
├── deployments/        # four microservices
├── services/           # ClusterIP + headless services
├── ingress/            # nginx ingress rules
├── networkpolices/     # per-pod egress/ingress rules
├── persistentvolumes/  # hostPath PVs for local cluster
├── resourcequotas/     # namespace resource cap
└── limitranges/        # per-container default limits
```

## Applying Manifests

```bash
kubectl apply -f k8s/secrets/
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/persistentvolumes/
kubectl apply -f k8s/statefulsets/
kubectl apply -f k8s/deployments/
kubectl apply -f k8s/services/
kubectl apply -f k8s/networkpolices/
kubectl apply -f k8s/resourcequotas/
kubectl apply -f k8s/limitranges/
kubectl apply -f k8s/ingress/
```

Order matters: secrets and configmaps before deployments, PVs before statefulsets.

## Local Cluster Setup (kubeadm)

### Node labels for database placement

```bash
kubectl label node wn1 db-group=group-1   # auth-db, room-db
kubectl label node wn2 db-group=group-2   # game-db, redis
```

### Required directories on worker nodes

On `wn1`:
```bash
mkdir -p /mnt/data/auth-db /mnt/data/room-db
```

On `wn2`:
```bash
mkdir -p /mnt/data/game-db /mnt/data/redis
```

### Ingress controller

```bash
helm/install-ingress-controller.sh
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec": {"type": "NodePort"}}'
```

### Metrics server

```bash
helm/install-metrics-server.sh
```

Enables `kubectl top pods` and `kubectl top nodes` for real-time resource consumption. Required for HorizontalPodAutoscaler.

The script patches metrics-server with `--kubelet-insecure-tls` to handle self-signed kubelet certificates common in kubeadm clusters.


### External Access via VPN + Caddy

After the local cluster is running, external HTTPS access was set up without a cloud load balancer:

**Stack:** WireGuard VPN + Caddy reverse proxy (running on a separate VPS).

**Traffic flow:**
```
Browser → HTTPS → Caddy (VPS) → WireGuard tunnel → cp:31857 → nginx ingress → services
```

**Setup steps:**

1. Install WireGuard on control plane:
```bash
yum install wireguard-tools -y
```

2. Configure `/etc/wireguard/wg0.conf` — set `AllowedIPs = 10.8.0.0/24` (VPN subnet only, not `0.0.0.0/0`) and add `PersistentKeepalive = 25` to keep the tunnel alive.

3. Enable WireGuard on startup:
```bash
systemctl enable wg-quick@wg0
```

4. Pin Calico to the physical interface so it doesn't pick up the WireGuard IP:
```bash
kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=interface=ens160 -n kube-system
```

5. Add Caddy reverse proxy block on the VPS:
```
chess.yourdomain.com {
    reverse_proxy <cp-vpn-ip>:31857
}
```

Caddy handles TLS termination automatically via Let's Encrypt. The cluster only receives plain HTTP on the NodePort.

**Warning:** Using `AllowedIPs = 0.0.0.0/0` on the control plane will route all traffic through the WireGuard tunnel, breaking Calico BGP and taking down pod networking. Always use the VPN subnet only.

---

## Troubleshooting

### Tables do not exist on first deploy

**Symptom:** `ProgrammingError: Table 'x_db.users' doesn't exist` in service logs.

**Cause:** Alembic migrations have not run. The service starts before the database schema is initialized.

**Solution:** Each deployment (auth, room, game) has an `initContainer` that runs `alembic upgrade head` before the main container starts. If migrations fail, check the init container logs:
```bash
kubectl logs <pod-name> -c migrate
```

---

### Static assets (CSS/JS) return 404

**Symptom:** Frontend loads as unstyled HTML, CSS and JS files return 404.

**Cause:** The ingress regex pattern `/(/|$)(.*)` only matches `/` and `//something`, not paths like `/css/style.css`.

**Solution:** Frontend ingress path changed to `/(.*)` with `rewrite-target: /$1`.

---

### API routes return 404 or wrong path

**Symptom:** Room service returns 404 on `/api/rooms/rooms`.

**Cause:** `API.ROOMS = '/api/rooms'` in the frontend, so calls like `${API.ROOMS}/rooms` produce `/api/rooms/rooms`. The ingress must account for this double segment.

**Solution:** Ingress path for rooms set to `/api/rooms/(rooms.*)` → rewrite `/$1` → service receives `/rooms`.

---

### WebSocket connection lost immediately

**Symptom:** Game page shows "connection lost" on load.

**Cause:** WebSocket connects to `/api/game/ws/games/{id}` but the ingress path `/api/game/(game.*)` does not match paths starting with `ws/`.

**Solution:** Ingress path changed to `/api/game/(.*)` to cover both REST (`/games/...`) and WebSocket (`/ws/games/...`) routes.

---

### PersistentVolume not binding

**Symptom:** StatefulSet pod stuck in `Pending` with `unbound PersistentVolumeClaims`.

**Cause:** `hostPath` PVs are node-local. Without `nodeAffinity` on the PV and `nodeSelector` on the StatefulSet, the pod may be scheduled on a node where the directory does not exist.

**Solution:** Each PV has `nodeAffinity` matching `db-group` label. Each StatefulSet has a matching `nodeSelector`.

---

### Redis memory pressure

**Symptom:** Redis pod is scheduled correctly but evicts neighbor pods under load.

**Cause:** Redis configured with `--maxmemory 256mb` but `requests.memory` was set to `128Mi`, so the scheduler underestimates actual usage.

**Solution:** `requests.memory` set to `280Mi` (256mb data + ~24Mi overhead). `limits.memory` set to `300Mi`.

---

### Fewer replicas running than desired (quota exceeded)

**Symptom:** `kubectl get pods` shows fewer running replicas than declared. `kubectl get events --field-selector reason=FailedCreate` shows quota errors with memory values much higher than declared in the manifest.

**Cause:** initContainers in auth, room, and game deployments had no explicit `resources` block. The namespace LimitRange auto-injects default values into any container without explicit resources (in this cluster: `410Mi` request / `478Mi` limit for memory). The effective pod resource is `max(initContainer, mainContainer)`, so pods consumed significantly more quota than what the main container declared.

**Solution:** Add explicit `resources` to all initContainers. For `alembic upgrade head`, lean values are sufficient:
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "50m"
  limits:
    memory: "256Mi"
    cpu: "150m"
```

Always declare `resources` on every container you control — including initContainers. LimitRange defaults are a safety net for unknown containers, not a substitute for explicit declarations.

---

### Rolling update stuck after fixing initContainer resources

**Symptom:** After fixing initContainer resources and running `kubectl apply`, the deployment stays at partial replicas. New pods fail with quota exceeded despite the fix.

**Cause:** The existing pod was created before the fix and still holds quota based on old resource specs. Rolling update cannot proceed: it needs to create a new pod first (maxUnavailable=0 by default), but quota is blocked by the old pod's inflated reservation.

**Solution:** Scale to 0, then back to the desired replica count:
```bash
kubectl scale deployment/<name> --replicas=0
kubectl scale deployment/<name> --replicas=<desired>
```
