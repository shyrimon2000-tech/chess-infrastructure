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
| Namespace | `dev` | `staging` | `production` |
| Frontend | container | container | S3 + CloudFront |
| Database | in-cluster MySQL | in-cluster MySQL | RDS |
| Redis | in-cluster | in-cluster | ElastiCache |
| DB Storage | EBS gp3 | EBS gp3 | managed (RDS) |
| HPA | disabled | enabled | enabled |
| Replicas | 1 per service | minReplicas (HPA) | minReplicas (HPA) |
| ResourceQuota | low (1 replica) | based on maxReplicas | based on maxReplicas |
| Ingress | nginx | nginx | ALB |
| Secrets | plain Secret (ExternalSecret on `feature/helm`, pending merge) | plain Secret (ExternalSecret on `feature/helm`, pending merge) | ESO → SSM Parameter Store |

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
| `ADMIN_PRINCIPAL_ARN` | Your personal IAM principal — granted an EKS access entry (`AmazonEKSClusterAdminPolicy`) via `access_entries.personal`, created unconditionally whenever this is set. `enable_cluster_creator_admin_permissions` is `false` (see EKS section — there's no implicit "whoever applies becomes admin" fallback, confirmed via `aws eks list-access-entries` that no such grant actually materializes here) — **without this variable set, `kubectl`/`helm`/`terragrunt apply` against the cluster's K8s API will fail with "the server has asked for the client to provide credentials," even though the AWS API calls themselves succeed** | `aws sts get-caller-identity --query Arn --output text` |

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
│   ├── argocd/                     # ArgoCD + chess-chart ApplicationSet (GitOps bootstrap)
│   └── eso/                        # External Secrets Operator + ClusterSecretStore (SSM Parameter Store)
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
    │   ├── argocd/                 # dev (automated+prune) + staging (manual)
    │   └── eso/                    # IRSA scoped to /chess-shared/*
    └── prod/
        ├── vpc/                    # 192.168.0.0/16
        ├── eks/                    # chess-prod cluster
        ├── karpenter/              # Karpenter on Fargate
        ├── nodepools/              # on-demand instances
        ├── ecs-runner/             # Fargate runner in prod VPC — excluded from run-all, building last
        ├── vpn/                    # vpn-prod.<domain>
        ├── argocd/                 # prod (manual sync)
        └── eso/                    # IRSA scoped to /chess-prod/*
```

Apply order (Layer 0 — GitHub-hosted runner): `vpc → ecs-runner` — **deferred**: `ecs-runner` units have `exclude { if = true, actions = ["all"] }` in their terragrunt.hcl and are skipped by `run-all`. Building it last, once everything else is stable and applying manually stops being enough.

Apply order (Layer 1 — self-hosted Fargate runner): `eks → vpn → karpenter → nodepools → ingress-nginx → route53 → argocd → eso`

**`nodepools` must apply before `eso`, `argocd`, `ingress-nginx` can safely apply** — not a hard Terraform dependency for those three, but karpenter/nodepools existing means real EC2 nodes can actually be provisioned once something needs one. `eks` itself must not create anything whose pods can only schedule on EC2 (see EBS CSI Driver note below) for exactly this reason.

EKS API endpoint is currently `endpoint_public_access = true` — temporary, while still applying from a laptop and before the VPN module has actually been applied and connected. `vpc`, `eks`, and `vpn` only call AWS APIs, so they can be applied from anywhere regardless. `karpenter`, `nodepools`, `ingress-nginx`, `argocd`, and `eso` use the `helm`/`kubectl` Terraform providers, which need a live connection to the cluster's Kubernetes API — once the VPN is applied and connected, flip `endpoint_public_access` to `false` and apply those only through the tunnel (or from the ECS runner, which already sits inside the VPC).

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
- Addons created in the `eks` module: CoreDNS, kube-proxy, VPC CNI
  - CoreDNS runs on Fargate via `kube-system` Fargate profile (label: `k8s-app=kube-dns`) — bootstraps DNS before Karpenter provisions EC2 nodes
  - VPC CNI (`aws-node`) pinned off Fargate via `affinity.nodeAffinity` on `eks.amazonaws.com/compute-type NotIn ["fargate"]`
- **Design rule: anything whose pod needs a real EC2 node doesn't belong in `eks`.** `eks` only creates what can run on Fargate or needs no compute at all (cluster, core addons, IAM). The EBS CSI Driver addon + its IRSA role live in `nodepools` instead, applied only once Karpenter has a `NodePool` to actually provision from. Same rule extended to `argocd`/`eso` via ordering-only terragrunt dependencies (`argocd → ingress-nginx`, `eso → nodepools`) rather than moving those modules themselves, since they don't own compute-dependent *resources*, just need something else's compute to exist first. Learned the hard way — see **Troubleshooting → "Addons stuck waiting for compute that doesn't exist yet"**.
- Access entries: `enable_cluster_creator_admin_permissions = false`; `access_entries.personal` created unconditionally from `ADMIN_PRINCIPAL_ARN` (see Prerequisites) — no implicit "whoever applies becomes admin" fallback
- Fargate↔EC2 security group bridge (`cluster_primary_security_group_id` ↔ `node_security_group_id`) — see **Troubleshooting → "No DNS resolution on EC2-hosted pods"**

**Karpenter**
- Single `general` NodePool — all chess services bin-packed on the same nodes
- Instance types: t3/t3a medium+large (x86, amd64 only)
- **shared**: Spot instances — cost optimized, interruptions acceptable in dev/staging
- **prod**: on-demand instances — no interruptions for active game sessions and room state (Redis)
- Consolidation: `WhenEmptyOrUnderutilized` + 30s (shared), `WhenEmpty` + 5m (prod)
- Node limits: 8 CPU / 32Gi per cluster (parametrized via `cpu_limit` / `memory_limit` inputs)
- `null_resource.wait_for_node_termination` (destroy-time `local-exec`) polls `aws ec2 describe-instances` for actual node termination instead of trusting a fixed `time_sleep` duration — see **Troubleshooting → "`terragrunt destroy` fails with `DependencyViolation` deleting the node security group"**

**Frontend**
- Prod: S3 + CloudFront (static assets, no pod in cluster)
- Dev / Staging: container in EKS (shared cluster)

**VPN**
- WireGuard (wg-easy) + Caddy on a single EC2 instance, SSM-only management (no SSH, no port 22)
- `aws_security_group.vpn`'s `description` must stay plain ASCII (AWS EC2 `GroupDescription` rejects em-dashes/smart quotes/etc.)
- The wg-easy `PASSWORD_HASH` (bcrypt, from SSM) is `replace(..., "$", "$$")`-escaped before going into `docker-compose.yml` — `docker-compose` re-parses `$VAR` syntax in the file at `up` time, independent of the shell that wrote it, and a bcrypt hash's literal `$` separators get silently mangled otherwise

**ArgoCD / GitOps**
- **Two `ApplicationSet`s per ArgoCD instance** (`chess-chart-automated`, `chess-chart-manual`), split by sync mode — not one ApplicationSet with a Go-template `{{if}}` for conditional sync policy, see **Troubleshooting → "Strictly-typed CRD fields can't hold unrendered Go-template placeholders"**. Each is a `list` generator + `goTemplate: true`, filtered in Terraform (`local.automated_environments` / `local.manual_environments`) — `count = length(...) > 0 ? 1 : 0` so an empty split (e.g. prod, 100% manual) doesn't create an ApplicationSet with a null `elements` list.
- Bootstrap (both `ApplicationSet`s) is created by Terraform (`kubectl_manifest`), not a manual one-time `kubectl apply` — keeps `terragrunt apply` alone sufficient to rebuild the whole GitOps loop from zero. Everything downstream (image tags, replicas, values) still flows through git only.
- Branch mapping: dev + staging watch the `dev` branch, prod watches `main`
- Sync policy: dev = automated + prune (no selfHeal — keeps live `kubectl` debugging possible without instant revert), staging + prod = manual
- `server.insecure = true` when ingress is enabled — argocd-server's own self-signed TLS would otherwise mismatch nginx's plain-HTTP proxy to the backend; acceptable since traffic is already inside the VPN tunnel + private VPC. See **Troubleshooting → "Helm/Terraform state can look fine while the cluster disagrees"** for why this setting didn't actually take effect on the first few applies.
- No verified community Terraform module exists for ArgoCD — installed via raw `helm_release` (argo-helm chart), same as Karpenter
- `argocd` has an ordering-only terragrunt dependency on `ingress-nginx` (output unused) — see **Troubleshooting → "Addons stuck waiting for compute that doesn't exist yet"**, same class of race, different trigger (admission webhook, not compute)

**ESO — External Secrets Operator**
- `helm_release` (chart `external-secrets/external-secrets`) + `kubectl_manifest` for `ClusterSecretStore`, same bootstrap pattern as ArgoCD's `ApplicationSet`
- One IRSA role per environment, scoped to `ssm:GetParameter[s][ByPath]` on `arn:...:parameter/${var.name}/*` — shared's role can only read `/chess-shared/*`, prod's only `/chess-prod/*`, no cross-environment access even by mistake
- `ClusterSecretStore` (fixed name `cluster-secret-store` — hardcoded in every chess-chart `values.yaml` `secretStoreRef.name`, must match exactly) has **no explicit `auth` block** — ESO falls back to the credentials of its own controller pod, i.e. the IRSA role above via the AWS SDK's default credential chain. Simpler than `auth.jwt.serviceAccountRef` (which would need extra RBAC for cross-namespace service account references) since there's only one ESO controller per cluster.
- `terraform/modules/eso/` intentionally has no `outputs.tf` — nothing consumes an ESO output yet; added back if/when something needs `role_arn`
- `eso` has an ordering-only terragrunt dependency on `nodepools` (output unused) — its controller pod isn't covered by any Fargate profile, same root cause as the EBS CSI Driver, see Troubleshooting

### Progress

| Module | Status |
|---|---|
| S3 state bucket | done (manual) |
| VPC (shared + prod) | applied ✓ (shared) |
| EKS (shared + prod) | **applied ✓ (shared)** — see Troubleshooting for the DNS/security-group bug |
| Karpenter (shared + prod) | applied ✓ (shared) |
| NodePools (shared + prod) | **applied ✓ (shared)** — owns EBS CSI Driver addon + `gp3` StorageClass |
| ECS runner (shared + prod) | written, **deferred on purpose** (`exclude` in terragrunt.hcl) — building last |
| ingress-nginx (shared) | **applied ✓** |
| Route53 private zone (shared) | **applied ✓** — `dev`/`staging`/`argocd`.chess.internal all resolve and route correctly |
| VPN — WireGuard (shared + prod) | **applied ✓ (shared)** |
| ArgoCD (shared + prod) | **applied ✓ (shared)** — see Troubleshooting for the ApplicationSet/ConfigMap bugs |
| ESO — External Secrets (shared + prod) | **applied ✓ (shared)** — `ClusterSecretStore` valid, `ExternalSecret`s synced (`ghcr-secret`, `auth-secret`, etc. all `SecretSynced: True`) |
| RDS (prod) | not started — not required by interview task, deferred indefinitely |
| ElastiCache / Redis (prod) | not started — not required by interview task, deferred indefinitely |
| ALB Ingress Controller (prod) | not started — **required by interview task**, next up |
| ArgoCD RBAC per environment | not started — **required by interview task** |
| Route53 public zone (prod) | not started |
| S3 + CloudFront (prod frontend) | not started — not required by interview task |

> **2026-07-02: full shared environment applied cleanly** — all 9 non-deferred units succeeded in one `terragrunt run --all apply`, zero errors. PVCs bound, EBS CSI active, ArgoCD UI reachable over the VPN, ESO syncing real secrets from SSM. The one remaining failure is **application-level, not infrastructure**: `chess-auth-service`/`chess-room-service`/`chess-game-service` pods crash-loop in their `alembic upgrade head` init container with `ModuleNotFoundError: No module named 'MySQLdb'` — the Docker images are missing the `mysqlclient` Python package SQLAlchemy needs for its MySQL driver. Out of scope for this repo — needs a dependency fix in each microservice's own `requirements.txt`/Dockerfile, not in Terraform/Helm/K8s config. Prod environment not yet applied.

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

### Infrastructure (Terraform / EKS) — found during the first full `run --all apply`, 2026-07-02

#### No DNS resolution on EC2-hosted pods

**Symptom:** EBS CSI Driver controller pod `CrashLoopBackOff`, logs show `AssumeRoleWithWebIdentity ... dial tcp: lookup sts.us-east-1.amazonaws.com: i/o timeout`. Looks like an IAM/IRSA problem.

**Cause:** CoreDNS runs on Fargate (deliberate — see two-tier compute model); everything else runs on Karpenter-provisioned EC2 nodes. `terraform-aws-modules/eks/aws` creates **three** distinct security groups: the AWS-native "primary" cluster SG (`cluster_primary_security_group_id` — what Fargate pods actually get attached to), the module's own separately-managed "additional" cluster SG (`cluster_security_group_id`, used only for specific control-plane webhook rules — the first fix attempt targeted this one and would have been a no-op), and the node SG. Nothing bridges the primary cluster SG and the node SG by default, so **no pod on an EC2 node could reach CoreDNS at all** — not just this one workload, every EC2-hosted pod's DNS was broken, including basic name resolution to AWS's own `sts.us-east-1.amazonaws.com`.

**Debugging path:** spun up a throwaway debug pod pinned to the affected node (`kubectl run netdebug --image=busybox --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<node>"}}}'`). `nslookup sts.us-east-1.amazonaws.com` (in-cluster resolver) timed out ("no servers could be reached"); `nslookup amazonaws.com 8.8.8.8` (bypassing CoreDNS entirely) worked — proved NAT/internet egress was fine and the gap was specifically pod-to-Fargate-pod traffic inside the VPC. Compared the security group actually attached to CoreDNS's Fargate ENI (`aws ec2 describe-network-interfaces --filters Name=private-ip-address,Values=<coredns-pod-ip>`) against `module.eks.cluster_security_group_id` — different IDs entirely; the real one Fargate uses is `cluster_primary_security_group_id`.

**Solution:** two `aws_security_group_rule` resources (both directions, all ports/protocols — cheap to open since it's already intra-VPC-only traffic) bridging `cluster_primary_security_group_id` ↔ `node_security_group_id`.

---

#### Addons stuck waiting for compute that doesn't exist yet

**Symptom:** `aws-ebs-csi-driver` and the ESO controller's `helm_release` both hung during `terraform apply` — the addon sat in `DEGRADED` health (`InsufficientNumberOfReplicas ... 0/N nodes are available`) until its 20-minute create timeout expired (`CREATE_FAILED`), and ESO's `helm_release` failed with `context deadline exceeded`.

**Cause:** both need a real EC2 node (the CSI driver for privileged/hostPath access unsupported on Fargate; ESO because no Fargate profile covers its namespace at all), but their Terraform resources originally lived in modules that only depended on `eks` — nothing forced them to wait until Karpenter actually had a `NodePool` to act on, so they could apply in parallel with `karpenter`/`nodepools` and poll against zero available nodes.

**Solution:** moved the EBS CSI Driver addon + its IRSA role from the `eks` module into `nodepools` (`depends_on = [kubectl_manifest.nodepool]`), and added ordering-only terragrunt `dependency` blocks (output deliberately unused — the block's presence alone forces DAG ordering) for `eso → nodepools` and `argocd → ingress-nginx` (same shape of problem, different trigger — an admission webhook, not compute). Once nodes can actually be provisioned before the addon's create call starts, Karpenter picks up the unschedulable pod and provisions a node inside the addon's own timeout window.

**Follow-ons on the same bug:** a stuck `CREATE_FAILED` addon object doesn't get fixed by a Terraform code change alone — `CreateAddon` won't re-apply new parameters (like `resolve_conflicts_on_create = "OVERWRITE"`) to an addon that already exists in some state; needed a one-time manual `aws eks delete-addon` + `aws eks wait addon-deleted` before the corrected config could create it cleanly. Also needed a `gp3` StorageClass added explicitly (`kubectl_manifest.gp3_storage_class` in `nodepools`) — installing the addon only gives you the *provisioner* (`ebs.csi.aws.com`), not any `StorageClass` that uses it, and EKS's shipped default is `gp2`.

---

#### Strictly-typed CRD fields can't hold unrendered Go-template placeholders

**Symptom:** ArgoCD's `ApplicationSet` `kubectl_manifest` failed two different ways in sequence: first a raw YAML parse error (`did not find expected key`), then — after fixing that — a Kubernetes admission error: `spec.template.spec.syncPolicy.automated.prune: Invalid value: "string": ... must be of type boolean`.

**Cause:** `kubectl_manifest` (provider `alekc/kubectl`) parses `yaml_body` with a strict YAML decoder *before* the object ever reaches ArgoCD's own Go-template engine. An unquoted `{{` at the start of a scalar is a YAML flow-mapping indicator, so a bare `{{- if .automated }}...{{- end }}` spanning multiple keys isn't valid YAML at all. Quoting it (`prune: '{{ .prune }}'`) fixes the YAML parse but then fails admission, because the *rendered* value kube-apiserver validates is the literal string `"{{ .prune }}"`, and the field is typed `boolean`. There's no quoting strategy that's simultaneously valid YAML and satisfies a strict boolean schema for an unrendered placeholder.

**Solution:** `env.automated`/`env.prune`/`env.self_heal` are already known at `terraform apply` time (`var.environments` is static) — moved the decision out of ArgoCD's runtime templating entirely. Split into two `kubectl_manifest` resources (`chess-chart-automated`, `chess-chart-manual`), filtered via Terraform locals (`[for env in var.environments : env if env.automated]`), with `prune`/`selfHeal` hardcoded as real YAML booleans instead of Go-template placeholders.

---

#### Helm/Terraform state can look fine while the cluster disagrees

**Symptom:** ArgoCD UI redirect-looped (`ERR_TOO_MANY_REDIRECTS`) even after adding the ingress-nginx annotations that should have stopped it (`ssl-redirect: false`).

**Cause:** `curl -v` showed the redirect coming from **argocd-server itself** (Go's default `http.Redirect` response body, no nginx framing) — meaning `server.insecure = true` never reached the running process. This chart applies that setting via the `argocd-cmd-params-cm` ConfigMap (read once at pod startup), not a CLI flag. `helm get values` confirmed `insecure: true` was in the latest release's user-supplied values, and `helm history` showed the latest revision as `STATUS: deployed` — but every one of its 4 revisions carried a failure description from the ingress-nginx admission-webhook race above, meaning each `helm upgrade` kept dying partway through applying the chart's resources, before ever reaching the ConfigMap.

**Solution:** patched the ConfigMap directly (`kubectl patch cm argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'`) and `kubectl rollout restart deployment/argocd-server` (ConfigMap changes aren't hot-reloaded). The same underlying class of issue also showed up separately as `helm_release` resources failing with `cannot re-use a name that is still in use`: an earlier interrupted `terraform apply` had gotten far enough for `helm install` to actually create and stabilize the release in-cluster, but the Terraform process was killed before persisting that resource to state. Fixed with `terraform import <namespace>/<release>` rather than deleting a genuinely healthy release.

**Lesson:** `STATUS: deployed` on the latest Helm revision, or a resource simply existing, doesn't guarantee its values fully landed — check the live resource against what you actually expect, not just release/state metadata.

---

#### `terragrunt destroy` fails with `DependencyViolation` deleting the node security group

**Symptom:** tearing down the whole shared environment (`terragrunt run --all destroy`) failed on the `eks` unit: `deleting Security Group (sg-...): ... DependencyViolation: resource sg-... has a dependent object`. The EKS cluster itself had already been destroyed successfully (its API endpoint no longer resolved) — only the security group deletion failed.

**Cause:** `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg-id>` showed 3 EC2 instances still `running`, ENIs still attached — Karpenter-provisioned nodes that hadn't finished terminating. The existing safeguard (`time_sleep(90s)` on the NodePool's destroy) wasn't just "too short" — it was structurally unable to guarantee anything: `run --all destroy` tears down `karpenter` (the only thing that can gracefully drain and terminate Karpenter-provisioned nodes) in the same overall run, so if node termination takes longer than the guessed sleep, the nodes can outlive the controller that would have terminated them and become **orphaned** — nothing left in the cluster to finish the job, ever, no matter how long you wait.

**Solution:** manually `aws ec2 terminate-instances` on the 3 leftover instances, `aws ec2 wait instance-terminated`, then re-ran destroy — it completed cleanly once the ENIs were gone. Fixed at the code level too: replaced `time_sleep(90s)` with `null_resource` + a destroy-time `local-exec` provisioner that actually polls `aws ec2 describe-instances` (filtered on the Karpenter node IAM instance profile) every 10s for up to 10 minutes instead of trusting a fixed duration. Doesn't fully eliminate the orphaning risk (if Karpenter is already gone, polling just times out instead of hanging forever) — but removes the "guessed 90s, hoped for the best" failure mode for the common case of termination simply taking longer than expected.

---

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

---

### `alembic upgrade head` init container crash-loops with `ModuleNotFoundError: No module named 'MySQLdb'`

**Symptom:** auth/room/game init containers `CrashLoopBackOff` even though the DB pod and image pull are both fine.

**Cause:** `DATABASE_URL` used the bare `mysql://` scheme, which makes SQLAlchemy default to the `MySQLdb` DBAPI (the `mysqlclient` package, needs a compiled C extension). The actual Docker images only have `PyMySQL` installed (`docker run <image> pip show pymysql mysqlclient`) — a pure-Python driver that needs the scheme spelled out explicitly.

**Solution:** fixed entirely on the infra side, no app code change needed — updated the `DATABASE_URL` in the relevant SSM parameters (`/chess-shared/{auth,room,game}`) from `mysql://` to `mysql+pymysql://`, then forced ESO to re-sync (`kubectl annotate externalsecret <name> force-sync=$(date +%s) --overwrite` — the default `refreshInterval: 1h` won't pick up an SSM change on its own) and restarted the deployments. Applies per-environment: dev and staging share the same SSM parameters, so both needed the force-sync; each namespace's `ExternalSecret` is a separate object even when pointed at the same underlying key.
