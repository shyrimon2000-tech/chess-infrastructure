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
| Secrets | ESO → SSM (`/chess-shared/*`, shared with staging) | ESO → SSM (`/chess-shared/*`, shared with dev) | ESO → SSM (`/chess-prod/*`) |

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

### Rolling Update Strategy

| Service | maxUnavailable | maxSurge |
|---|---|---|
| auth | 0 | 1 |
| room | 0 | 1 |
| game | 0 | 1 |
| frontend | *(unset — Kubernetes default: 25%/25%)* | |

`auth`/`room`/`game` all set explicit `strategy.rollingUpdate` (`values.yaml`'s new `rollingUpdate.maxUnavailable`/`maxSurge`, read by each service's `deployment.yaml`) rather than relying on the Kubernetes default (`25%` for both). `maxUnavailable: 0` means an old pod is never terminated until its replacement has passed `readinessProbe` and is `Ready` — zero-downtime, one pod swapped at a time (`maxSurge: 1` caps how many extra pods can exist mid-rollout). This matters most for `game`: a rollout that took down an active game-session pod before its replacement was ready would risk the same 30s-reconnect-timeout scored-loss scenario documented for Spot interruptions (see Terraform Karpenter NodePool section) — just triggered by a deploy instead of a node eviction. `frontend` is left at the Kubernetes default since it's stateless static content (and only runs as a container Deployment at all in dev/staging — prod serves it from S3 + CloudFront, no Deployment involved).

### ResourceQuota

| | Dev | Staging | Prod |
|---|---|---|---|
| requests.cpu | 1300m | 3100m | 2350m |
| requests.memory | 2900Mi | 5000Mi | 2828Mi |
| limits.cpu | 2700m | 6500m | 5050m |
| limits.memory | 4200Mi | 8200Mi | 5556Mi |

Prod quota is lower than staging despite having HPA enabled — no in-cluster MySQL pods (3 × 200m CPU / 600Mi each) since databases run on RDS. Prod's numbers include the `rds-bootstrap` Helm hook Job's own footprint (50m/128Mi request, 150m/256Mi limit) added explicitly on top of auth/room/game's worst-case (all three at HPA `maxReplicas` simultaneously) — not left to incidental headroom, which happened to already be just enough but wasn't intentionally sized for it.

### Access

**Dev / Staging** — internal only, not exposed to the internet.

- **CI/CD access** — self-hosted ECS Fargate runner in private subnet (runs `terragrunt apply`, `helm`, `kubectl`)
- **Admin/developer access** — WireGuard VPN into the VPC (`vpn-shared.<domain>` / `vpn-prod.<domain>`, wg-easy + Caddy on EC2 in the public subnet, SSM-only — no SSH). Split-tunnel: only the VPC CIDR routes through the tunnel, not `0.0.0.0/0`.

Hostnames (Route53 private hosted zone `chess.internal`, associated with the shared VPC):
- `dev.chess.internal` → dev namespace
- `staging.chess.internal` → staging namespace
- `argocd.chess.internal` → ArgoCD UI (shared instance)

All three point to the same internal NLB (ingress-nginx on Fargate). Traffic stays within the VPC — resolvable only once connected to the VPN, since the DNS server pushed to VPN peers is the VPC resolver.

**Prod** — chess services public via ALB + Route53 public hosted zone (TLS terminated at the ALB). **ArgoCD stays admin-only, VPN-gated** — same pattern as shared (its own `ingress-nginx`, its own private zone), not on the public ALB. Private zone is `chess-prod.internal`, not `chess.internal` — private zones are VPC-scoped already so there's no real collision risk either way, but the distinct name makes it obvious which environment's ArgoCD a given URL points at. Only the `argocd` record exists here (`route53` module's `records` variable, default `["dev", "staging", "argocd"]`, overridden to `["argocd"]` for prod — no dev/staging namespaces exist in prod).

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
| `/chess-prod/rds/master-password` | rds (`admin` login for the RDS instance — used by chess-chart's `rds-bootstrap` Helm hook Job to create the three per-service databases/users, and by you directly for manual DB admin access over the VPN) |
| `/chess-prod/jwt-secret-key` | rds (written into `/chess-prod/auth`'s `JWT_SECRET_KEY`, and re-exposed as an output for the future `elasticache` module to reuse for `/chess-prod/room`/`/chess-prod/game` — all three services must share one signing key) |

Generate a wg-easy password hash with: `docker run ghcr.io/wg-easy/wg-easy wgpw '<password>'`

Generate an ArgoCD admin password hash with: `argocd account bcrypt --password '<password>'` (requires the `argocd` CLI)

The RDS master password and JWT secret don't need any special hashing — plain values, unlike the bcrypt hashes above. Manual creation here isn't about avoiding Terraform state (any resource attribute ends up in state regardless of where its value originated — a `data` source read is no different from a `random_password` in that respect); it's about *source of truth* — these two are credentials you choose/rotate yourself, matching the ArgoCD/wg-easy pattern, rather than Terraform-generated values with no human-readable record outside state.

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
│   ├── argocd/                     # ArgoCD + root app-of-apps Application (GitOps bootstrap)
│   ├── eso/                        # External Secrets Operator + ClusterSecretStore (SSM Parameter Store)
│   ├── frontend/                   # S3 + CloudFront + ACM (prod only, no EKS dependency)
│   ├── rds/                        # MySQL 8.0 Multi-AZ, 3 databases + scoped users (prod only)
│   ├── elasticache/                # Redis 7.x single-node, shared by room+game (prod only)
│   ├── alb-controller/             # AWS Load Balancer Controller (IRSA + Helm), prod only
│   └── external-dns/               # ExternalDNS (IRSA + Helm), prod only
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
        ├── ecs-runner/             # not wired up — see GitHub Actions CD section
        ├── ingress-nginx/          # internal NLB, ArgoCD-only (chess services use the public ALB instead)
        ├── route53/                # chess-prod.internal private zone, argocd record only
        ├── vpn/                    # vpn-prod.<domain>
        ├── argocd/                 # prod (manual sync), VPN-only ingress
        ├── eso/                    # IRSA scoped to /chess-prod/*
        ├── frontend/               # chess.alexit.online — no dependency block, applies standalone
        ├── rds/                    # depends only on vpc (not eks) — applies in parallel with the cluster
        ├── elasticache/            # depends on vpc + rds — writes /chess-prod/room and /chess-prod/game
        ├── alb-controller/         # depends only on vpc + eks — own Fargate profile, no nodepools wait
        └── external-dns/           # depends only on eks — watches Ingress, writes Route53 records
```

Apply order (Layer 0 — GitHub-hosted runner): `vpc → ecs-runner` — **not built**. `ecs-runner` (`exclude { if = true, actions = ["all"] }`, skipped by `run-all`) exists in this repo as a documented *concept* for the eventual self-hosted-runner CD pipeline (see GitHub Actions CD section), not as a near-term deliverable — deprioritized given the deadline, since nothing in the actual requirements depends on *how* Terraform gets applied, only on the resulting infrastructure state.

Apply order (Layer 1 — self-hosted Fargate runner, or a laptop while `endpoint_public_access = true`): `eks → vpn → karpenter → nodepools → ingress-nginx → route53 → argocd` (`eso` only depends on `eks` now that it runs on its own Fargate profile — see ESO section — so it can apply any time after `eks`, not necessarily last) — same shape for both shared and prod now; prod's `ingress-nginx`/`route53` exist solely to keep ArgoCD VPN-only, not for app traffic (that's the public ALB, applied independently).

**`nodepools` must apply before `argocd`, `ingress-nginx` can safely apply** — not a hard Terraform dependency for those two, but karpenter/nodepools existing means real EC2 nodes can actually be provisioned once something needs one. `eks` itself must not create anything whose pods can only schedule on EC2 (see EBS CSI Driver note below) for exactly this reason. (`eso` used to be in this list too, before it moved to its own Fargate profile.)

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
| Fargate | Karpenter controller, ArgoCD, Grafana, CoreDNS, ingress-nginx (shared only), ESO, AWS Load Balancer Controller + ExternalDNS (prod only) | Fargate micro-VM per pod |
| EC2 (Karpenter) | All chess microservices, Prometheus | Spot (shared) / on-demand (prod) |

- API endpoint: currently `endpoint_public_access = true` (temporary, still applying from a laptop). Will be set to private-only once the VPN is applied and connected — or the ECS runner is in place, whichever comes first.
- IRSA used for Karpenter and EBS CSI Driver (pod identity agent not available on Fargate at time of writing)
- Addons created in the `eks` module: CoreDNS, kube-proxy, VPC CNI
  - CoreDNS runs on Fargate via `kube-system` Fargate profile (label: `k8s-app=kube-dns`) — bootstraps DNS before Karpenter provisions EC2 nodes
  - VPC CNI (`aws-node`) pinned off Fargate via `affinity.nodeAffinity` on `eks.amazonaws.com/compute-type NotIn ["fargate"]` — see **Troubleshooting → "VPC CNI's node-affinity matched zero real nodes"** for why it's `NotIn` and not the more obvious-looking `In ["ec2"]`
- **Design rule: anything whose pod needs a real EC2 node doesn't belong in `eks`.** `eks` only creates what can run on Fargate or needs no compute at all (cluster, core addons, IAM). The EBS CSI Driver addon + its IRSA role live in `nodepools` instead, applied only once Karpenter has a `NodePool` to actually provision from. Same rule extended to `argocd` via an ordering-only terragrunt dependency (`argocd → ingress-nginx`) rather than moving the module itself, since it doesn't own compute-dependent *resources*, just needs something else's compute (Fargate readiness, via the webhook) to exist first. Learned the hard way — see **Troubleshooting → "Addons stuck waiting for compute that doesn't exist yet"**. (`eso` used to need this same treatment — its controller wasn't covered by any Fargate profile — until it got its own dedicated one; see ESO section below.)
- Access entries: `enable_cluster_creator_admin_permissions = false`; `access_entries.personal` created unconditionally from `ADMIN_PRINCIPAL_ARN` (see Prerequisites) — no implicit "whoever applies becomes admin" fallback
- Fargate↔EC2 security group bridge (`cluster_primary_security_group_id` ↔ `node_security_group_id`) — see **Troubleshooting → "No DNS resolution on EC2-hosted pods"**

**Karpenter**
- Single `general` NodePool — all chess services bin-packed on the same nodes
- Instance types: t3/t3a small+medium+large (x86, amd64 only) — `small` added alongside medium/large: Karpenter always picks the cheapest instance that actually fits the pod(s) it's provisioning for, never force-fits a workload onto an undersized one, so this is a no-downside option for a cold cluster's first node or a lone leftover pod. Rarely wins once real chess-service load exists, since services are deliberately bin-packed and their combined `requests` usually exceed one small's capacity already.
- **shared**: Spot instances — cost optimized, interruptions acceptable in dev/staging
- **prod**: on-demand instances — room-service can't tolerate Spot interruptions (Redis). Game-service state is persisted to the DB, so a Spot interruption wouldn't lose data — but the client's reconnect window is a hard 30s timeout, and a Spot interruption's full notice-to-reschedule cycle can easily exceed that, turning into a real scored loss for the player, not just a data-loss risk.
- Consolidation: `WhenEmptyOrUnderutilized` + 30s (shared), `WhenEmpty` + 5m (prod)
- Node limits: 8 CPU / 32Gi per cluster (parametrized via `cpu_limit` / `memory_limit` inputs)
- `null_resource.wait_for_node_termination` (destroy-time `local-exec`) polls `aws ec2 describe-instances` for actual node termination instead of trusting a fixed `time_sleep` duration — see **Troubleshooting → "`terragrunt destroy` fails with `DependencyViolation` deleting the node security group"**
- **VPC CNI prefix delegation enabled** (`ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` on the `vpc-cni` addon's `configuration_values`, `terraform/modules/eks/main.tf`) — found during real debugging that `t3.medium`'s default one-IP-per-ENI-slot model caps out at **17 pods per node** (`3 ENIs × 5 secondary IPs − 1 + 2`), a ceiling that binds *before* CPU/memory ever do once ESO + the EBS CSI Driver + DaemonSets + chess services are all counted. Prefix delegation assigns a `/28` (16 IPs) per ENI slot instead of one at a time, raising the ceiling to the order of 100+ pods per node — high enough that CPU/RAM (plus the namespace `ResourceQuota` and each service's own HPA `maxReplicas`) become the actual binding constraints again, as originally intended. Karpenter computes node pod-capacity itself (AL2023 nodes, not the classic AMI `bootstrap.sh` script), so this needed no companion change in `nodepools`. Doesn't retroactively help already-running nodes — `max-pods` is fixed at node bootstrap, so the benefit only applies to nodes Karpenter launches *after* this change.

**Frontend**
- Prod: S3 + CloudFront (static assets, no pod in cluster) — `terraform/modules/frontend`
- Dev / Staging: container in EKS (shared cluster)
- **Fully independent of EKS/VPC** — no `dependency` blocks in `terraform/environments/prod/frontend/terragrunt.hcl` at all. Static hosting doesn't need a cluster, a VPC, or even prod's other units to exist first; it can apply/destroy on its own schedule.
- **Excluded from `run --all destroy` specifically** (`exclude { if = get_terraform_command() == "destroy", actions = ["all"] }`) — still fully included in `run --all apply`/`plan`. Unlike EKS/EC2/NAT (the actual cost drivers behind tearing `shared`/`prod` down between sessions), S3 + CloudFront cost cents to sit idle, so there's no cost reason to destroy it on the same cycle. It also isn't cheap to *redo* — CloudFront takes 15-30 minutes to propagate a new distribution to edge locations, so destroying and reapplying it on every cost-saving teardown would make `chess.alexit.online` unreachable for that whole window, every single cycle, for no benefit.
- **S3 is private, CloudFront reads via Origin Access Control (OAC)** — no S3 static website hosting, no public bucket policy. `aws_s3_bucket_public_access_block` blocks all four public-access vectors; the only allowed reader is this exact CloudFront distribution, enforced by an `AWS:SourceArn` condition in the bucket policy (not just "any CloudFront", a specific one). OAC is the current AWS-recommended approach — the older Origin Access Identity (OAI) is legacy.
- **ACM certificate in us-east-1** — a CloudFront hard requirement regardless of which region the distribution's origin lives in. Not a special case here since this whole project already runs in us-east-1 (see `root.hcl`); a project centered on another region would need a second, aliased `aws` provider just for this one certificate.
- **SPA routing via `custom_error_response`** — a direct hit on a client-side route (e.g. `/profile/123`) doesn't exist as an S3 object. A private bucket denies unknown keys with `403` (not `404` — it won't reveal whether the key exists at all), so both `403` and `404` are rewritten to `/index.html` with a real `200`, letting React Router take over client-side instead of the browser showing a raw CloudFront error page.
- **Terraform provisions infrastructure only, never uploads content** — same principle as ArgoCD/GitOps (infra vs. delivery stay separate). No `aws_s3_object` resources tracking build output in state; that would couple this repo to the frontend's build artifacts and cause a Terraform diff on every frontend deploy for content Terraform doesn't actually need to know about. Instead, Terraform writes the bucket name and CloudFront distribution ID to plain-`String` (not `SecureString` — neither is a secret) SSM parameters (`/chess-prod/frontend/s3-bucket`, `/chess-prod/frontend/cloudfront-distribution-id`) that the separate `chess-frontend-service` repo's own CI reads to run `aws s3 sync` + a cache invalidation after each build — works identically whether triggered locally or from a future GitHub Actions runner, without hardcoding either value into that repo. Both params set `overwrite = true` — `aws_ssm_parameter` defaults to `false` on create specifically to avoid clobbering a parameter it doesn't already own, but a stale value left behind by a prior destroy/apply cycle that never made it into *this* state should always just be replaced with what the current apply actually produced (same failure class as the Helm "name still in use" and EKS "addon already exists" bugs — see Troubleshooting — neither of these two params is a secret needing manual bootstrap, so there's nothing worth preserving).
- **CloudFront is multi-origin: S3 (default) + two ALB origins** (`/api/*` with origin mTLS, `/api/game/ws/*` without — same ALB, different port, see ALB/ExternalDNS section and Troubleshooting for why) — one public hostname (`chess.alexit.online`) for static assets and the entire backend API including WebSocket, chosen specifically to avoid a cross-origin (CORS) setup between frontend and backend. See the ALB / ExternalDNS section below for why the ALB origin can reference a hostname that doesn't resolve to anything at the moment this distribution is created.

**ALB / ExternalDNS (prod only — dev/staging use ingress-nginx internally, no public ALB)**
- **Terraform does not create the ALB.** It only installs two Kubernetes controllers (IRSA + Helm, same shape as `ingress-nginx`/`karpenter`): the **AWS Load Balancer Controller** (watches `Ingress` resources, creates/manages the actual ALB, target groups, and listener rules) and **ExternalDNS** (watches the same `Ingress` resources, creates the matching Route53 record). Confirmed against the controller's own official docs: it always creates and fully owns the ALB's lifecycle — there is no supported way to pre-create an ALB in Terraform and have the controller "adopt" it. The real ALB only exists after ArgoCD deploys chess-chart's `Ingress` objects (`main-ingress.yaml`, `game-ingress.yaml`, `ingressClassName: alb`) — an async step outside this repo's `terraform apply` entirely.
- **This creates a real sequencing problem for CloudFront**, which needs to know the ALB's origin domain *at the moment the distribution is created* — but the ALB doesn't exist yet at that point. **ExternalDNS is what resolves this without a second `terraform apply`:** CloudFront's ALB origin is configured with a stable, pre-decided hostname (`api-origin.alexit.online`, `frontend` module's `api_origin_hostname` input) that doesn't resolve to anything the moment `terraform apply` runs — CloudFront only needs an origin to resolve when an actual request routes there, not at distribution-creation time. Once chess-chart's `Ingress` applies later and the ALB Controller creates the real ALB, ExternalDNS notices the same `Ingress` object and automatically creates the Route53 A/ALIAS record for `api-origin.alexit.online` pointing at it — fully autonomously, the same GitOps-reconciliation shape as ArgoCD/ESO already use elsewhere in this project.
- **For `Ingress` resources specifically, ExternalDNS reads the target hostname straight from `spec.rules[].host`** (`ingress.host` in `values-prod.yaml`) — not from an `external-dns.alpha.kubernetes.io/hostname` annotation, which is a Service-only mechanism. Confirmed against ExternalDNS's own AWS integration docs after an initial wrong assumption here (see git history) — worth calling out since the two mechanisms look similar but apply to different resource kinds.
- **`ingress.host` in `values-prod.yaml` is `api-origin.alexit.online`, not `chess.alexit.online`.** The public hostname end users hit is CloudFront's; the ALB never receives direct public traffic under its own name — it only receives proxied requests from CloudFront for the `/api/*` path, and its host-based listener rule (generated from `ingress.host`) must match the `Host` header CloudFront actually sends, which is the origin's `domain_name` (`api_origin_hostname`), not the viewer's original `Host`. These two values are set independently in two different repos/files and must stay in sync by hand — the `frontend` module's `api_origin_hostname` variable and `values-prod.yaml`'s `ingress.host` — there's no single source of truth linking them yet.
- **`alb.ingress.kubernetes.io/group.name: chess-prod`** on `main-ingress.yaml`, `game-ingress.yaml`, and `game-ws-ingress.yaml` — without it, separate `Ingress` objects get separate ALBs from the controller, not the "single ALB" CLAUDE.md describes. Same annotation value on all three merges them into one ALB with combined listener rules.
- **ALB has its own HTTPS:443 listener with a DNS-validated ACM certificate** (`aws_acm_certificate.alb`, lives in `terraform/modules/origin-mtls` — see below for why not `alb-controller`). TLS for end users still terminates at CloudFront first (which holds the separate cert for `chess.alexit.online`, see Frontend section) — this is a second, independent, re-encrypted TLS session for the CloudFront→ALB hop specifically, not a pass-through of the viewer's own TLS session.
- **This hop was originally plain HTTP** (`origin_protocol_policy = "http-only"`), relying on AWS's internal backbone alone for confidentiality — changed to `https-only` + origin mTLS (next bullet) once it became clear the old `X-Origin-Verify` shared-secret header (see below) travelled in that same unencrypted hop, meaning a readable network path could leak the exact secret meant to prove authenticity.
- **Second listener, port 8443, no mutual-authentication — same ALB, same server certificate, one specific exception to the mTLS rule above.** CloudFront cannot present a client certificate for a WebSocket upgrade at all (a hard, AWS-documented platform limitation, found live — see Troubleshooting), so `game-ws-ingress.yaml` (a separate `Ingress` object, since `mutual-authentication` is listener-scoped, not per-path) gets its own listener without it. Same security group (same CloudFront-only prefix list, just one more port) — the only thing actually dropped is the client-certificate check; network restriction and the WebSocket handshake's own JWT check both still apply.
- **AWS Load Balancer Controller and ExternalDNS each get their own dedicated namespace + Fargate profile** (`aws-load-balancer-controller`, `external-dns`) in the `eks` module, not `kube-system` — the existing `kube_system` Fargate profile is scoped only to CoreDNS (`k8s-app=kube-dns`), so a pod merely living in `kube-system` wouldn't actually match it and would need a real EC2 node instead. Same reasoning as the existing `karpenter`/`argocd`/`grafana`/`ingress-nginx` profiles: these controllers only watch the K8s API and call AWS APIs, no real compute needed. Defined unconditionally in the shared `eks` module (used by both `shared` and `prod`) — harmless for `shared`, which never runs these controllers at all.
- **IAM policy for the ALB Controller is AWS's own published JSON** (`terraform/modules/alb-controller/iam_policy.json`, fetched verbatim from `kubernetes-sigs/aws-load-balancer-controller`'s `docs/install/iam_policy.json`), not hand-written — the controller needs a genuinely large set of EC2/ELB permissions to create and manage load balancers, target groups, listeners, and security groups on its own.
- **ExternalDNS's Route53 write permission (`route53:ChangeResourceRecordSets`) is scoped to exactly the one hosted zone ARN** (`alexit.online`), not account-wide — same least-privilege reasoning as ESO's per-environment SSM path scoping. The read-only discovery actions (`ListHostedZones`, `ListResourceRecordSets`, `ListTagsForResources`) have to stay account-wide since Route53's API doesn't expose a per-zone ARN for those calls.
- **`policy = "upsert-only"`** on the ExternalDNS Helm release — it will create and update records it owns, but never delete a record just because the matching `Ingress` disappeared. Safer default for a shared public hosted zone that also holds unrelated records (the `vpn` module's `vpn-prod.alexit.online`, etc.) than `policy = "sync"`, which would actively reconcile-by-deletion.
- **Well-Architected angle (Operational Excellence pillar): ExternalDNS exists specifically to remove a manual step, not just to be "more automated" for its own sake.** Without it, wiring `api-origin.alexit.online` → the real ALB after every deploy would be a human task — someone has to notice the ALB was (re)created, copy its DNS name, and update a Route53 record by hand, a step that's easy to forget, easy to get stale after the ALB is replaced (e.g. a listener/target-group change that forces ALB recreation), and easy to typo. ExternalDNS turns that into a reconciling control loop tied to the actual cluster state (the `Ingress` object), the same "operate via code, not manual runbook steps" principle already applied elsewhere in this project (ArgoCD for deploys, ESO for secrets) — one less place where a person is the thing keeping frontend↔backend connectivity correct.
- **The ALB is reachable from nowhere except CloudFront — two independent layers, not one.** By default the controller auto-creates a permissive security group open to the internet on the listener ports. Instead, `terraform/modules/alb-controller` creates its own `aws_security_group.alb`, referenced by the Ingress via `alb.ingress.kubernetes.io/security-groups` (matched by the SG's `Name` **tag**, not its AWS-generated `groupName` — easy to get wrong), which bypasses that auto-creation. `manage-backend-security-group-rules: "true"` keeps the controller still auto-managing the ALB→pod backend rules despite the custom frontend SG.
  1. **Network layer** — ingress restricted to AWS's managed prefix list `com.amazonaws.global.cloudfront.origin-facing`, covering both HTTPS listeners (443 and 8443 — see the WebSocket bullet above) as a single rule spanning that port range, not two separate rules. Authoritative, AWS-maintained source for "which IPs does CloudFront originate from" — hand-maintaining that CIDR list would go stale as AWS rotates edge IPs. (Two separate same-prefix-list rules would also have hit a real account quota — see Troubleshooting.)
  2. **Identity layer — origin mTLS, not a shared-secret header.** Originally an `X-Origin-Verify` header: CloudFront's origin config added a `custom_header` carrying a shared secret to every request, and each backend path's Ingress rule carried a matching `alb.ingress.kubernetes.io/conditions.<service>` HTTP-header condition. Replaced because that header travelled in plaintext over the same `http-only` CloudFront→ALB hop it was supposed to authenticate — a network-level read of that hop would hand over the exact secret meant to prove "this is really our CloudFront", collapsing the whole check. Origin mTLS closes that structurally instead of patching around it: CloudFront presents a client certificate at the TLS handshake itself, before any HTTP request (and thus before any header) is even sent, and the ALB verifies it against a trust store via `alb.ingress.kubernetes.io/mutual-authentication` (`mode: verify`). A forged or leaked header value can be replayed by anyone; a private key backing a client certificate can't be. Anyone who discovers `api-origin.alexit.online` (a normal, publicly-resolvable record once ExternalDNS creates it) and passes the IP-prefix-list check still fails the TLS handshake itself without this certificate — the check now happens one network layer lower than an HTTP header ever could.
  - **`terraform/modules/origin-mtls`** owns the whole mTLS chain: a self-signed CA (`tls_self_signed_cert`) — not AWS Private CA (ACM PCA charges ~$400/mo just for the CA to exist, unjustified when the only "client" ever presenting a certificate is CloudFront itself, an automated system with no real trust-chain value to lose by not chaining to a public CA); a client certificate signed by that CA and imported into ACM (`aws_acm_certificate.client`, must live in `us-east-1` — CloudFront's origin-mTLS requirement, same regional constraint as the frontend's own viewer-facing cert); and an `aws_lb_trust_store` backed by an S3-hosted CA bundle (the resource requires the bundle to already exist as an S3 object — it can't take inline PEM the way `aws_acm_certificate.certificate_body` can). The ALB's own server certificate (previous bullet) also lives in this module, not `alb-controller` — see next bullet for why.
  - **Why the entire `origin-mtls` module — including the ALB's server cert — is excluded from `run --all destroy`** (`exclude { if = get_terraform_command() == "destroy" }`, same mechanism as `frontend`): every resource in it is free or effectively free to leave idle (ACM certificates don't cost anything regardless of how many exist; the S3 trust-store object is one tiny PEM file; SSM `String` parameters are free), but every one of them gets a **brand-new ARN** if destroyed and recreated. Both `frontend` (`origin_mtls_client_certificate_arn`, via a terragrunt `dependency` block) and `helm/chess-chart/values-prod.yaml` (`certificate-arn`, `mutual-authentication`'s `trustStore`, both hand-copied) reference these ARNs. Since this project routinely runs `run --all destroy`/`apply` cycles on `shared`/`prod` between sessions purely to stop billing (see Progress table), *not* excluding this module would silently invalidate those references on every single cycle — turning what should be a one-time bootstrap paste into a recurring manual chore, and blocking any future automation of the destroy/apply cycle entirely. This is deliberately *not* the same module as `alb-controller`, whose IAM role and Helm release genuinely are tied to the EKS cluster's OIDC provider and correctly get destroyed/recreated with it — bundling the certs in there would have reintroduced the exact churn this split avoids.
  - ARNs are also written to SSM (`/chess-prod/origin-mtls/alb-certificate-arn`, `/chess-prod/origin-mtls/trust-store-arn`) for discoverability, same pattern as `frontend`'s bucket/distribution-id parameters — but still have to be copied into `values-prod.yaml` by hand once after the first apply, since Ingress annotations are static content rendered from `values.yaml` at Helm template time, not populated from an ESO-managed `Secret` at runtime the way `DATABASE_URL`/`JWT_SECRET_KEY`/etc. are.

**RDS (prod only — dev/staging keep the in-cluster MySQL StatefulSet)**
- **One Multi-AZ MySQL 8.0 instance, three logical databases** (`auth_db`, `room_db`, `game_db`) — not three separate RDS instances. Matches the ~$40-50/mo estimate in CLAUDE.md (a single Multi-AZ instance's ballpark, not 3x it) while still respecting "each service owns its own database, no shared database" — the isolation boundary is per-database credentials, not per-instance.
- **Dedicated MySQL user per database, not one shared master user** — `ALL PRIVILEGES`, scoped to exactly one database each, created by a Helm post-install/post-upgrade hook Job in chess-chart (`rds-bootstrap`), not by Terraform. `ALL PRIVILEGES` and not a narrower DML-only set because alembic's `upgrade head` init container (see Troubleshooting) needs DDL — `CREATE`/`ALTER`/`DROP TABLE` — not just row-level access; the isolation is "which database", not "which SQL statements". A leaked `room_user` credential can't touch `auth_db` or `game_db` at all.
- **Terraform never opens a live MySQL connection** — it only decides the desired database/user/password (`random_password` + a naming convention) and publishes that decision to SSM, same as always. Realizing it against the actual instance is the `rds-bootstrap` Job's job, which runs inside the cluster — see Troubleshooting for why this replaced an earlier `mysql`-Terraform-provider design that needed VPN/in-cluster connectivity at `apply`/`destroy` time.
- **Depends only on `vpc`** — same as before any live-MySQL-connection requirement ever existed. RDS provisioning (storage allocation, Multi-AZ standby setup, DNS propagation — 10-15+ minutes regardless of what else is happening) runs fully in parallel with `eks`/`karpenter`/`nodepools`, no dependency on either.
- **Master password and JWT secret are manually created SSM SecureStrings, read via `data`** — same pattern as the ArgoCD admin password hash and wg-easy VPN password (see Prerequisites table), not `random_password`. Reasoning changed from an earlier draft of this module: manual creation doesn't avoid Terraform state (an `aws_db_instance.password` attribute ends up in state regardless of whether its value came from `random_password` or a `data` source — Terraform state doesn't care about provenance), what it actually buys is *source of truth* — you choose and know the master password, so you can connect directly with any MySQL client over the VPN for manual admin access, instead of having to dig a Terraform-generated value out of state. JWT secret is manual for a second reason too: it must be identical across auth/room/game, and `/chess-shared/{auth,room,game}` for dev/staging are *already* fully manual (not Terraform-managed at all) — matching that existing convention rather than introducing a different pattern just for prod.
- **`/chess-prod/auth` is fully written by this module** (`SecureString`, `overwrite = true`, JSON `{DATABASE_URL, JWT_SECRET_KEY}`) — auth has no Redis dependency, so its secret is complete the moment RDS applies.
- **`/chess-prod/room` and `/chess-prod/game` are deliberately NOT written here** — only `DATABASE_URL` per service and the shared `JWT_SECRET_KEY` are exposed as (sensitive) Terraform outputs. Writing the full JSON in this module and having a later `elasticache` module overwrite the same SSM parameter would mean two different Terraform states both trying to own one AWS resource — instead, whichever module needs Redis in the mix (`elasticache`, next) reads these outputs via a terragrunt `dependency` block and writes those two parameters itself, as sole owner, combining them with its own `REDIS_URL`. The chess-chart's `ExternalSecret` still only ever reads one `remoteRef.key` per service either way — no Helm chart changes needed for this split.
- JWT secret is read **once** here (from `/${var.name}/jwt-secret-key`) and shared verbatim across auth/room/game outputs — auth issues tokens, room/game only verify them, so all three must agree on the same signing secret.

**ElastiCache / Redis (prod only — dev/staging keep the in-cluster Redis StatefulSet)**
- **Single-node `aws_elasticache_cluster`, `engine = "redis"`** — no `aws_elasticache_replication_group`, no multi-AZ failover. Room-service can't be on Spot (see Karpenter section), but that's an EC2/Karpenter concern already solved at the node level — this project doesn't additionally need HA at the cache tier for a personal project's traffic. A production team with real availability SLOs would use a replication group instead (multi-AZ, automatic failover, at-rest encryption — none of which `aws_elasticache_cluster` supports on its own).
- **`engine = "redis"` is the entire "make it act like Redis" configuration** — there's no extra layer or setting beyond picking the engine; ElastiCache for Redis *is* Redis, wire-compatible, not an emulation.
- **room and game share one `REDIS_URL`, not isolated per-service logical DBs** — Redis here backs cross-service game-state pub/sub (CLAUDE.md), so both services need the same keyspace/channels, not their own private slice (unlike RDS, where per-service isolation was the whole point).
- **Same private database subnets and VPC-CIDR security-group trust model as `rds`** — reuses `database_subnet_ids`, ingress on 6379 from the whole VPC CIDR (covers EKS pods and a VPN-connected apply client alike).
- **Depends on both `vpc` and `rds`** (not `eks`) — needs `rds`'s `database_urls`/`jwt_secret_key` outputs (via a terragrunt `dependency` block) to compose the complete `/chess-prod/room` and `/chess-prod/game` secrets, which `rds` deliberately left unwritten. This module is the sole owner of those two SSM parameters — see the `rds` module's Architectural Decisions entry above for why splitting ownership this way avoids two Terraform states fighting over one resource.

**VPN**
- WireGuard (wg-easy) + Caddy on a single EC2 instance, SSM-only management (no SSH, no port 22)
- `WG_ALLOWED_IPS` (the split-tunnel CIDR) comes from `dependency.vpc.outputs.cidr`, not a hand-typed literal — `vpc` now exports its own `cidr` output specifically so this can't drift. It used to be duplicated by hand in `vpn/terragrunt.hcl` (`vpc_cidr = "10.0.0.0/16"`) independently of the VPC module's own CIDR (in shared's case, not even set explicitly there — it was the module's default), which the `vpc` module didn't even export as an output at the time. Nothing checked the two matched; they just happened to.
- `aws_security_group.vpn`'s `description` must stay plain ASCII (AWS EC2 `GroupDescription` rejects em-dashes/smart quotes/etc.)
- The wg-easy `PASSWORD_HASH` (bcrypt, from SSM) is `replace(..., "$", "$$")`-escaped before going into `docker-compose.yml` — `docker-compose` re-parses `$VAR` syntax in the file at `up` time, independent of the shell that wrote it, and a bcrypt hash's literal `$` separators get silently mangled otherwise

**ArgoCD / GitOps**
- **App-of-apps: Terraform creates one root `Application` per instance, everything below it is hand-written git YAML.** Redesigned 2026-07-02 from an earlier version where Terraform generated the `ApplicationSet`s themselves via HCL `%{~for~}` templating over `var.environments`. That worked but meant the environment topology only existed as Terraform state — adding an environment meant editing HCL, not git. Now `terraform/modules/argocd` owns exactly one object per instance: a `kubectl_manifest.root_app` `Application` (`source.path: helm/git-ops/<shared|prod>`, `directory.recurse: true`, auto-sync + prune, no selfHeal). Same chicken-and-egg as any ArgoCD bootstrap — *something* non-GitOps has to create that first root object — but it's now the only thing Terraform still owns; the actual environment list lives in git like everything else.
- **`helm/git-ops/{shared,prod}/*.yaml`** — hand-written `ApplicationSet` manifests, one per sync-policy bucket: `chess-chart-automated` (dev only) and `chess-chart-manual` (staging; prod gets only this one bucket, no automated env exists there). Each is a `list` generator + `goTemplate: true` template that stamps out one `Application` per element (`{{.app}}`, `{{.env}}`, `{{.namespace}}`, `{{.path}}`, `{{.valuesFile}}`, `{{.targetRevision}}` all generator-driven) — deliberately includes an `app`/`path` pair even though only `chess-chart` exists today, so a second application can be added as a new `elements` entry with no template changes. `syncPolicy.automated.prune`/`selfHeal` stay hardcoded literals inside `template`, not `{{.field}}` — see **Troubleshooting → "Strictly-typed CRD fields can't hold unrendered Go-template placeholders"**, still the reason these two buckets are split rather than one `ApplicationSet` with a conditional sync policy.
- Bootstrap (the root `Application`) is created by Terraform (`kubectl_manifest`), not a manual one-time `kubectl apply` — keeps `terragrunt apply` alone sufficient to rebuild the whole GitOps loop from zero. Everything downstream of that — which buckets exist, which environments, image tags, replicas, values — now flows through git only, including the bucket topology itself (not just deploy content, like before).
- Root `Application`'s own `targetRevision` must match the same branch as everything it generates for that instance (`dev` for shared, `main` for prod) — if it didn't, a bucket change pushed to `dev` could apply into prod before ever being merged to `main`, defeating prod's manual-only discipline.
- Branch mapping: dev + staging watch the `dev` branch, prod watches `main`
- Sync policy: dev = automated + prune (no selfHeal — keeps live `kubectl` debugging possible without instant revert), staging + prod = manual
- Set via `configs.params.server\\.insecure` (not `server.insecure`, a nested key the chart never reads — see **Troubleshooting → "Helm `set` key silently pointed at a value nothing reads"**) when ingress is enabled — argocd-server's own self-signed TLS would otherwise mismatch nginx's plain-HTTP proxy to the backend; acceptable since traffic is already inside the VPN tunnel + private VPC.
- No verified community Terraform module exists for ArgoCD — installed via raw `helm_release` (argo-helm chart), same as Karpenter
- `argocd` (prod) has four ordering-only terragrunt dependencies, all output-unused, existing purely to fix apply order: `ingress-nginx` (its own Ingress needs that controller's admission webhook ready — see **Troubleshooting → "Addons stuck waiting for compute that doesn't exist yet"**), and `rds` + `elasticache` + `alb-controller` (chess-chart's `rds-bootstrap` Helm hook Job and ALB `Ingress` objects would otherwise be able to sync before their prerequisites exist — see **Troubleshooting → "RDS bootstrap without a VPN/private-VPC dependency"**). Structural mitigation, not a hard guarantee — prod's sync is manual, so a human could still trigger a sync too early once ArgoCD exists.

**ArgoCD RBAC**
- Three layers, all written now — same shape as Kubernetes RBAC, just without a literal cluster/namespace binding: AppProject ≈ `Role` (a named set of permissions, scoped to an object pattern instead of a namespace), the `g` policy line ≈ `RoleBinding` (binds a subject to that role), and a role with no object-pattern restriction (or `project: default`) ≈ `ClusterRole`/`ClusterRoleBinding`.
  1. **AppProject** — scopes *what* an `Application` is allowed to touch (source repo, destination namespace), enforced by ArgoCD itself at sync time. **Done.**
  2. **Local account (`viewer`)** — a login identity, declared in `configs.cm`, password (SSM-backed bcrypt hash, same pattern as admin) set via `set_sensitive`. **Done.**
  3. **RBAC policy (`configs.rbac.policy.csv` + `policy.default`)** — scopes *who* can do *what* against a given AppProject. **Done.**
- **Why AppProject exists on top of the git-folder/branch split that already separates environments:** `gitops_dir`/`gitops_target_revision` only control *which git content* an ArgoCD instance reads — they say nothing about what ArgoCD is allowed to *do* with that content once read. Every `Application`/`ApplicationSet` previously ran under `project: default`, which has no restrictions at all (any repo, any namespace, any resource kind). AppProject is a second, independent guardrail enforced by the ArgoCD controller at sync time, regardless of how the content got there — it catches mistakes the git-folder split can't, e.g. a typo'd `namespace:` in a generator template.
- **`kubectl_manifest.app_project_root`** (one per instance) — scopes `root_app` itself to destination `namespace: argocd` only, since that's the only place it ever needs to create `ApplicationSet` objects.
- **`kubectl_manifest.app_project_apps`** (`for_each` over `var.app_projects`, a `map(list(string))` set per-environment via terragrunt) — one AppProject per map entry, scoping the actual chess-chart `Application`s each bucket's `ApplicationSet` generates. Shared splits this **per namespace** (`apps-dev` → `[dev]`, `apps-staging` → `[staging]`) rather than one combined project covering both: dev's bucket is `automated: true` (auto-sync, no human review), so a bug in its generator template that emitted the wrong `namespace:` would otherwise sync straight into staging with no guardrail — splitting means staging simply isn't a valid destination for anything `apps-dev`-scoped, so ArgoCD rejects the sync outright. Prod has only one namespace (`production`), so no split is needed there (`var.app_projects = { "apps" = ["production"] }`).
- Both AppProject resources are Terraform-owned (`kubectl_manifest`, same as `root_app`) rather than hand-written git YAML — this is environment *topology* (which projects exist, their boundaries), the same category of thing `root_app` itself already is, not deploy content.
- `root_app`'s `depends_on` includes `app_project_root` (hard dependency — `root_app`'s own `spec.project` references it directly) and `app_project_apps` (soft — nothing Terraform-owned references these directly, only the hand-written `ApplicationSet` YAML in git does, applied later by ArgoCD's own controller — included anyway so a fresh apply brings up the whole topology in one pass instead of ArgoCD retrying past a transient "project does not exist" error).
- **`viewer` account** — `configs.cm.accounts\.viewer: "login"` (capability declaration, not a secret) plus `configs.secret.extra.accounts\.viewer\.password` (bcrypt hash from a new `/${var.name}/argocd/viewer-password-hash` SSM parameter, same manual-bootstrap pattern as the admin password). Both this and the admin password moved to `set_sensitive` (rather than plain `set`) for an explicit redaction guarantee independent of the SSM data source's own sensitivity marking.
- **RBAC policy** — one `configs.rbac.policy\.csv` value per instance: a `p` line for `${var.name}-root/*`, one more `p` line per `var.app_projects` key (generated via the same `%{ for %}` template pattern as the AppProject destinations, so it scales automatically with however many entries that map has), and a final `g, viewer, role:${var.name}-viewer` line binding the account to the role — without that last line the role would exist with no one holding it. `configs.rbac.policy\.default` is set to `""` explicitly (rather than left to the chart's own default) so any account added later without its own `g` line gets zero access rather than an unreviewed fallback.
- **Status:** `terragrunt validate` passes on both `shared` and `prod` for all three layers; the generated AppProject `yaml_body` was rendered and checked independently (outside the `kubectl` provider, which needs a real cluster CA cert to configure — the `eks` dependency's mock output isn't valid PEM, so a real `plan`/`apply` isn't possible pre-cluster). **Not yet applied against a live cluster** — unverified whether `viewer` can actually log in and see only its scoped projects until a real `helm_release`/`kubectl_manifest` apply happens against a live EKS cluster.

**ESO — External Secrets Operator**
- `helm_release` (chart `external-secrets/external-secrets`) + `kubectl_manifest` for `ClusterSecretStore`, same bootstrap pattern as ArgoCD's `ApplicationSet`
- One IRSA role per environment, scoped to `ssm:GetParameter[s][ByPath]` on `arn:...:parameter/${var.name}/*` — shared's role can only read `/chess-shared/*`, prod's only `/chess-prod/*`, no cross-environment access even by mistake
- `ClusterSecretStore` (fixed name `cluster-secret-store` — hardcoded in every chess-chart `values.yaml` `secretStoreRef.name`, must match exactly) has **no explicit `auth` block** — ESO falls back to the credentials of its own controller pod, i.e. the IRSA role above via the AWS SDK's default credential chain. Simpler than `auth.jwt.serviceAccountRef` (which would need extra RBAC for cross-namespace service account references) since there's only one ESO controller per cluster.
- `terraform/modules/eso/` intentionally has no `outputs.tf` — nothing consumes an ESO output yet; added back if/when something needs `role_arn`
- **Runs on its own dedicated Fargate profile** (`external_secrets` in `terraform/modules/eks/main.tf`'s `fargate_profiles`, namespace `external-secrets`) — same reasoning as the `aws_load_balancer_controller`/`external_dns` profiles above: controller + cert-controller + webhook only watch the K8s API and call the AWS SSM API, no real EC2 node needed. Previously required real EC2 (no Fargate profile covered its namespace), which meant `eso`'s terragrunt unit needed an ordering-only `dependency "nodepools"` just to have somewhere to schedule — removed once this profile was added, since Fargate doesn't need Karpenter/NodePools at all. Side benefit: frees up the EC2 NodePool's pod-density budget (see Karpenter's prefix-delegation note above) for actual application workload instead of ESO's 3 pods.
- **Webhook moved off its default port (`webhook.port: "9443"` Helm value, default is `10250`)** — Fargate-specific gotcha, found on the very next live apply after moving ESO onto Fargate: see **Troubleshooting → "ESO's ClusterSecretStore fails admission with a certificate hostname mismatch (Fargate only)"**.

### Progress

| Module | Status |
|---|---|
| S3 state bucket | done (manual) |
| VPC (shared + prod) | verified working (shared) — **currently torn down** for cost, code unchanged |
| EKS (shared + prod) | verified working (shared) — see Troubleshooting for the DNS/security-group bug — **currently torn down** |
| Karpenter (shared + prod) | verified working (shared) — **currently torn down** |
| NodePools (shared + prod) | verified working (shared) — owns EBS CSI Driver addon + `gp3` StorageClass — **currently torn down** |
| ECS runner (shared + prod) | **not built — documented concept only**, deprioritized given the deadline (see Apply order note above) |
| ingress-nginx (shared + prod) | verified working (shared) — prod unit newly written, not yet applied — **currently torn down** |
| Route53 private zone (shared + prod) | verified working (shared, `dev`/`staging`/`argocd.chess.internal`) — prod unit (`chess-prod.internal`, argocd-only) newly written, not yet applied — **currently torn down** |
| VPN — WireGuard (shared + prod) | verified working (shared) — **currently torn down** |
| ArgoCD (shared + prod) | Helm install + ingress + `configs.params.server\.insecure` fix **verified end-to-end** (shared 2026-07-02, prod 2026-07-02). App-of-apps redesign (root `Application` + hand-written `helm/git-ops/*` buckets) **verified against a real cluster 2026-07-03**: root app applied and synced both `ApplicationSet` buckets, generating `chess-chart-dev` and `chess-chart-staging` as real `Application` objects visible in the UI — confirms the git-driven topology actually works end-to-end, not just `terragrunt validate` |
| ESO — External Secrets (shared + prod) | verified working (shared) — `ClusterSecretStore` valid, `ExternalSecret`s synced — **currently torn down** |
| RDS (prod) | module written (`terraform/modules/rds`), `terragrunt validate` passes — not yet applied. No longer needs VPN/in-cluster connectivity at apply time (see Troubleshooting — database/user creation moved to a chess-chart Helm hook Job) |
| ElastiCache / Redis (prod) | module written (`terraform/modules/elasticache`), `terragrunt validate` passes — not yet applied |
| ALB Ingress Controller (prod) | module written (`terraform/modules/alb-controller`), `terragrunt validate` passes — controller itself not yet (re-)applied since the 2026-07-04 security-group fix (443, was 80) and Service-webhook race fix (`enableServiceMutatorWebhook = false`). Real ALB won't exist until chess-chart is deployed via ArgoCD (see ALB/ExternalDNS section) — end-to-end `/api/*` routing through CloudFront unverified until then |
| Origin mTLS (prod) | `terraform/modules/origin-mtls` — **applied 2026-07-04**. Self-signed CA + client cert + ALB trust store + ALB's own server cert, excluded from `run --all destroy` for ARN stability (see ALB/ExternalDNS section). ARNs copied into `values-prod.yaml`; not yet verified end-to-end against a live ALB |
| ExternalDNS (prod) | module written (`terraform/modules/external-dns`), `terragrunt validate` passes — not yet applied |
| ArgoCD RBAC per environment | All three layers written — **AppProject** (root + per-namespace apps projects, shared split dev/staging), **`viewer` local account** (SSM-backed password, same pattern as admin), **RBAC policy** (`policy.csv` + explicit empty `policy.default`) — `terragrunt validate` passes both envs. **Not yet applied against a live cluster** — required by interview task, see ArgoCD RBAC section above for what's unverified |
| Route53 public zone (prod) | not started |
| S3 + CloudFront (prod frontend) | `terraform/modules/frontend` — **applied 2026-07-04**, origin switched to `https-only` + origin mTLS (see ALB/ExternalDNS section) |

> **2026-07-02: full shared environment applied cleanly, then torn down.** All 9 non-deferred units succeeded in one `terragrunt run --all apply`, zero errors. PVCs bound, EBS CSI active, ArgoCD UI reachable over the VPN, ESO syncing real secrets from SSM, all three chess services healthy after the `mysql+pymysql://` driver fix (see Troubleshooting). Torn down afterward via `terragrunt run --all destroy` to stop billing — see Troubleshooting for the node security-group `DependencyViolation` hit during that teardown. Since then: prod gained its own VPN-only `ingress-nginx`/`route53` for ArgoCD (mirroring shared), and the `vpc_cidr` duplication between `vpc`/`vpn` modules was fixed (see Architectural Decisions → VPN) — neither has been applied yet on either environment, only `validate`d and `plan`ned against mocks. Prod environment not yet applied at all.

## GitHub Actions CD

**Design concept, not yet built.** Given the deadline, this stayed a documented architecture rather than a near-term deliverable — the actual application CI (build/test/push each microservice's image) already exists independently in each microservice's own repo (GitHub Actions → GHCR), which is what the interview task's CI requirement actually needs. This section describes how *infrastructure* deployment (`terragrunt apply`) would eventually move off a laptop and into CI, not something currently running.

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

#### VPC CNI's node-affinity matched zero real nodes

**Symptom:** freshly-provisioned Karpenter EC2 nodes sat `NotReady` for 40+ minutes, `kubectl describe node` showing `container runtime network not ready: cni plugin not initialized`. Every pod on those nodes — not just one workload — was unschedulable, because nothing could get network at all.

**Cause:** the VPC CNI addon's `affinity.nodeAffinity` used `eks.amazonaws.com/compute-type In ["ec2"]`, meant to keep the `aws-node` DaemonSet off Fargate (Fargate has its own built-in pod networking and doesn't need or support this DaemonSet at all). But real Karpenter-provisioned nodes carry an opaque per-node value for that label, not the literal string `"ec2"` — so the selector matched zero real nodes anywhere. `aws-node` sat at `DESIRED=0` cluster-wide, meaning no node — Fargate or EC2 — could ever report `NetworkReady`.

**Solution:** inverted the match: `NotIn ["fargate"]` instead of `In ["ec2"]` — matches everything that *isn't* Fargate, regardless of what the real EC2-side label value actually is, instead of trying to guess/enumerate it.

**Lesson (the interesting part):** this entire bug class only exists *because* of the Fargate+EC2 hybrid compute model. A pure-EC2 cluster would run `aws-node` on every node unconditionally — no affinity rule, no label-matching logic, no way for this specific mistake to happen at all. The hybrid model saves real money (see Design rule above — no dedicated always-on infra node group needed), but it isn't a free lunch: mixing two different compute backends inside one cluster adds a real class of "which components can/must run where" complexity that a simpler, single-backend cluster wouldn't have to think about. Worth being able to name that trade-off explicitly, not just the cost side of it.

---

#### Addons stuck waiting for compute that doesn't exist yet

**Symptom:** `aws-ebs-csi-driver` and the ESO controller's `helm_release` both hung during `terraform apply` — the addon sat in `DEGRADED` health (`InsufficientNumberOfReplicas ... 0/N nodes are available`) until its 20-minute create timeout expired (`CREATE_FAILED`), and ESO's `helm_release` failed with `context deadline exceeded`.

**Cause:** both need a real EC2 node (the CSI driver for privileged/hostPath access unsupported on Fargate; ESO because no Fargate profile covers its namespace at all), but their Terraform resources originally lived in modules that only depended on `eks` — nothing forced them to wait until Karpenter actually had a `NodePool` to act on, so they could apply in parallel with `karpenter`/`nodepools` and poll against zero available nodes.

**Solution:** moved the EBS CSI Driver addon + its IRSA role from the `eks` module into `nodepools` (`depends_on = [kubectl_manifest.nodepool]`), and added ordering-only terragrunt `dependency` blocks (output deliberately unused — the block's presence alone forces DAG ordering) for `eso → nodepools` and `argocd → ingress-nginx` (same shape of problem, different trigger — an admission webhook, not compute). Once nodes can actually be provisioned before the addon's create call starts, Karpenter picks up the unschedulable pod and provisions a node inside the addon's own timeout window. (`eso → nodepools` no longer exists in current code — removed once ESO got its own Fargate profile, see ESO section — the EBS CSI Driver still needs real EC2 for privileged/hostPath access, so its own fix here is unchanged.)

**Follow-ons on the same bug:** a stuck `CREATE_FAILED` addon object doesn't get fixed by a Terraform code change alone — `CreateAddon` won't re-apply new parameters (like `resolve_conflicts_on_create = "OVERWRITE"`) to an addon that already exists in some state; needed a one-time manual `aws eks delete-addon` + `aws eks wait addon-deleted` before the corrected config could create it cleanly. Also needed a `gp3` StorageClass added explicitly (`kubectl_manifest.gp3_storage_class` in `nodepools`) — installing the addon only gives you the *provisioner* (`ebs.csi.aws.com`), not any `StorageClass` that uses it, and EKS's shipped default is `gp2`.

**The mechanics of "Karpenter picks up the unschedulable pod" (worth spelling out — it's not obvious which pod does what):** Karpenter only reacts to ordinary `Pending` pods from a `Deployment`/`StatefulSet` (the EBS CSI Driver's *controller*, here) — a `DaemonSet` pod never triggers node provisioning by itself, it just rides along once a matching node already exists for any reason. So the actual sequence on a cold cluster is:

1. EBS CSI Driver controller pod: `Pending` (no node exists at all).
2. Karpenter sees it, sizes and launches an EC2 instance for it (factoring in expected DaemonSet overhead, but the DaemonSet pods aren't why the node was created).
3. The node registers, the controller pod gets *scheduled* onto it — but it does **not** immediately go `Running`. It moves to `ContainerCreating` (events show `network not ready` / `cni plugin not initialized`), because CNI hasn't started on this brand-new node yet.
4. `aws-node` (the VPC CNI `DaemonSet`) independently notices the new node matches its (fixed) affinity and schedules its own pod onto it.
5. Once `aws-node` initializes and starts handing out pod IPs, **every** pod on that node — including the original EBS CSI controller pod that caused the node to exist in the first place — transitions from `ContainerCreating` to `Running` at the same time, no special ordering for the "triggering" pod.

The self-referential part is the easy bit to miss: the pod that caused the node to be created doesn't get to skip the CNI wait just because it triggered the provisioning — it queues behind CNI exactly like every other pod that happens to land on that node.

---

#### Strictly-typed CRD fields can't hold unrendered Go-template placeholders

**Symptom:** ArgoCD's `ApplicationSet` `kubectl_manifest` failed two different ways in sequence: first a raw YAML parse error (`did not find expected key`), then — after fixing that — a Kubernetes admission error: `spec.template.spec.syncPolicy.automated.prune: Invalid value: "string": ... must be of type boolean`.

**Cause:** `kubectl_manifest` (provider `alekc/kubectl`) parses `yaml_body` with a strict YAML decoder *before* the object ever reaches ArgoCD's own Go-template engine. An unquoted `{{` at the start of a scalar is a YAML flow-mapping indicator, so a bare `{{- if .automated }}...{{- end }}` spanning multiple keys isn't valid YAML at all. Quoting it (`prune: '{{ .prune }}'`) fixes the YAML parse but then fails admission, because the *rendered* value kube-apiserver validates is the literal string `"{{ .prune }}"`, and the field is typed `boolean`. There's no quoting strategy that's simultaneously valid YAML and satisfies a strict boolean schema for an unrendered placeholder.

**Solution:** which environments are automated vs. manual is a fixed, known-in-advance split — moved the decision out of ArgoCD's runtime templating entirely. Split into two `ApplicationSet`s (`chess-chart-automated`, `chess-chart-manual`), one per sync-policy bucket, with `prune`/`selfHeal` hardcoded as real YAML booleans inside each `template` instead of Go-template placeholders. Originally implemented as two Terraform-generated `kubectl_manifest` resources (filtered via `[for env in var.environments : env if env.automated]`); after the 2026-07-02 app-of-apps redesign the same split is expressed as two hand-written files in `helm/git-ops/{shared,prod}/` instead — the underlying fix (literal booleans, not templated ones) didn't change, only which layer authors the YAML.

---

#### Helm `set` key silently pointed at a value nothing reads

**Symptom:** ArgoCD UI redirect-looped (`ERR_TOO_MANY_REDIRECTS`) even after adding the ingress-nginx annotations that should have stopped it (`ssl-redirect: false`), and even after re-applying. Reproduced identically on **shared** (many failed/retried revisions) and, later, on **prod** — a completely clean, single-revision, first-try `helm install` with no failures in its history at all. The fact that a from-scratch clean install hit the exact same symptom is what proved the real cause wasn't upgrade-related.

**First (wrong, but not unreasonable) theory:** `curl -v` showed the redirect coming from **argocd-server itself**, not nginx — meaning `server.insecure = true` never reached the running process. `kubectl get cm argocd-cmd-params-cm -o jsonpath='{.data}'` showed `"server.insecure":"false"`, while `helm history` on shared showed several revisions that had each failed partway through (the ingress-nginx admission-webhook race above) before reaching a `deployed` status. Concluded the ConfigMap patch was getting skipped by those partial failures — patched it directly as a workaround (`kubectl patch cm ... server.insecure=true` + `kubectl rollout restart`) and moved on.

**Real cause, found once prod reproduced it on a clean install:** the Terraform `set` block used `name = "server.insecure"` — which Helm's `--set` syntax parses as **nested** YAML (`server: { insecure: true }`). The chart doesn't read TLS mode from there at all; `helm show values argo-cd --version 7.7.11` shows it's actually a **flat key with a literal dot in its name**, `configs.params."server.insecure"`, which is what populates `argocd-cmd-params-cm`. Confirmed against the `hashicorp/helm` provider's own docs (via the Terraform MCP server) that escaping a literal dot inside a flat key needs a double backslash in HCL: `name = "configs.params.server\\.insecure"`. The old key set a value the chart simply never looked at — on every single apply, clean or not, regardless of how many revisions it took.

**Solution:** fixed the `set` block to `configs.params.server\\.insecure`. Confirmed working end-to-end on a real prod apply — ArgoCD came up reachable over the VPN with no manual ConfigMap patch needed.

**Lesson:** a plausible-sounding first theory that explains *some* of the evidence (failed revisions were real, the ConfigMap really was wrong) isn't the same as the actual root cause — the reproduction on a clean, unrelated install (different environment, zero failed revisions) is what falsified it. Also: Helm's `--set` dotted-path syntax is ambiguous by design — the same string can mean "nested key" or "flat key with a dot," and only the chart's own `values.yaml` tells you which one it actually reads.

---

#### Interrupted `terraform apply` leaves a real Helm release Terraform doesn't know about

**Symptom:** `helm_release` resources failing with `cannot re-use a name that is still in use`, even though Terraform's state shows no such resource yet.

**Cause:** an earlier interrupted `terraform apply` had gotten far enough for `helm install` to actually create and stabilize the release in-cluster, but the Terraform process was killed (or hit an unrelated error later in the same run) before persisting that resource to state. Terraform, seeing nothing in its own state, tries a fresh `helm install` and Helm refuses since a release with that name already exists.

**Solution:** `terraform import <namespace>/<release>` rather than deleting a genuinely healthy release and reinstalling.

**Lesson:** a resource existing, or `helm history` showing `STATUS: deployed`, doesn't guarantee Terraform's state agrees — check the live resource against what you actually expect, not just release/state metadata.

---

#### `helm_release` times out on a cold cluster, then blocks retry with the same "name still in use" symptom

**Symptom:** `terraform apply` on `ingress-nginx` failed with `Error: installation failed ... context deadline exceeded`. Re-running immediately failed differently: `cannot re-use a name that is still in use` — same symptom family as the entry above, but this time on the very first apply attempt against a freshly-created cluster, not after an interrupted process.

**Cause:** `helm_release`'s default `timeout` is 300s, and `wait` (also default `true`) blocks on both the controller pod reaching Ready **and** the Service's LoadBalancer getting an address. `kubectl get events -n ingress-nginx` showed the real timeline: `EnsuredLoadBalancer` fired 2 seconds after the Service was created (NLB provisioning was never the bottleneck) — but the controller pod hit `FailedScheduling: Pod provisioning timed out (will retry)` twice from the Fargate scheduler before finally landing, 7 minutes after creation. A documented, non-error Fargate behavior (it retries provisioning automatically and succeeded on its own) — but 7 minutes exceeds the 5-minute client-side timeout, so Terraform gave up first. That failed `helm install` left the release recorded `STATUS: failed` in-cluster; Terraform's state has no record of it (the resource never finished creating), so the retry attempts a fresh `install` and Helm refuses the name collision — the same downstream symptom as an interrupted-apply orphan, different root cause.

**Solution:** `helm uninstall ingress-nginx -n ingress-nginx` to clear the failed release (state has nothing to `import` here — unlike the entry above, there's no genuinely healthy resource to adopt), then raised `helm_release.timeout` to `900` in `terraform/modules/ingress-nginx/main.tf` to give real headroom for a cold-cluster Fargate retry cycle instead of racing a tight 5-minute default against it.

**Lesson:** confirmed via `git log -p` on every commit touched since the prior successful apply that no code in the create-path (`ingress-nginx`, `karpenter`, `nodepools`) had changed — ruling out a regression before reaching for "AWS was just slow" as the explanation. `kubectl get events --sort-by=.lastTimestamp` gave the actual timeline proving *which* async operation was slow (Fargate pod scheduling, not the NLB) rather than guessing.

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

### ALB / CloudFront path routing (prod) — found 2026-07-04/05

The two entries above fixed routing for nginx (dev/staging). ALB (prod) needed a completely different mechanism to solve the same underlying problem — documented separately because the failure mode, root cause, and fix all differ from the nginx case.

#### Why a CloudFront Function exists here at all

ALB's `path-pattern` listener-rule conditions only support literal characters plus `*`/`?` wildcards — no regex, no capture groups. nginx's `rewrite-target: /$1` (used for all three backend routes, see entries above) has no ALB equivalent: there's nothing on the ALB side that can both match a request *and* rewrite its path before forwarding. `terraform/modules/frontend/functions/strip-api-prefix.js` — a CloudFront Function attached to the `/api/*` cache behavior — exists to do that rewrite at the edge, one hop before the request ever reaches the ALB, so the ALB only ever sees plain, wildcard-free paths it's able to match.

This also changes *where* routing decisions get made compared to nginx. With nginx, the ALB — sorry, the *Ingress* — matches the request's **original** path, and the rewrite to a different forwarded path is a separate, later step. With CloudFront Function → ALB, there is no such two-step: the function's output is **simultaneously** (a) what ALB's `path-pattern` condition matches against to pick a target group, and (b) the exact path forwarded to the pod. One rewrite, one output, two jobs — which is exactly what made the next bug possible.

#### Naive uniform `/api` strip breaks room- and game-service routing

**Symptom:** After switching prod routing from nginx to ALB + this CloudFront Function, auth worked (`POST /api/auth/register` succeeded end-to-end), but room-service returned `422` on what the browser's Network tab showed as `GET /api/rooms/rooms`, and `POST /rooms/rooms` returned `405` — both against room-service's own logs, ruling out a frontend bug (the identical frontend code works fine against nginx in dev/staging).

**Cause:** the first version of `strip-api-prefix.js` stripped a flat, uniform 4 characters (`"/api"`) off every request, on the (wrong) assumption that this mirrors what nginx's `rewrite-target: /$1` does for every route. It doesn't — nginx's actual forwarded path depends on *where each route's own regex capture group starts*, and that differs per service:

| Route | nginx Ingress path (capture group in `()`) | Prefix actually consumed before forwarding | Naive 4-char `/api` strip | Correct? |
|---|---|---|---|---|
| auth | `/api/(auth/.*)` | `/api` (4 chars) | `/api` | ✅ correct, by coincidence only |
| rooms | `/api/rooms/(rooms.*)` | `/api/rooms` (10 chars) | `/api` | ❌ leaves `/rooms/rooms` (duplicated segment) instead of `/rooms` |
| game | `/api/game/(.*)` | `/api/game` (9 chars) | `/api` | ❌ leaves `/game/games/...` (extra `/game` segment) instead of `/games/...` |

Auth only "worked" because its capture group happens to start exactly 4 characters in — the same coincidence that made the bug invisible until rooms/game traffic was actually exercised.

**Solution:** rewrote `strip-api-prefix.js` to branch per route, most-specific prefix first, replicating nginx's real per-route behavior instead of one uniform strip:
- `/api/rooms/*` → strips `"/api/rooms"` (10 chars)
- `/api/game/*` → strips `"/api/game"` (9 chars)
- everything else starting `/api` → strips `"/api"` (4 chars) — this is the auth case

Concrete trace after the fix (query strings are handled separately by CloudFront Functions — `request.uri` never includes them, so the function doesn't need to touch `?token=...` at all):

| What the browser sends | Function output (= what ALB matches AND forwards) | ALB rule | What the pod receives |
|---|---|---|---|
| `/api/auth/register` | `/auth/register` | `path: /auth` | `/auth/register` |
| `/api/rooms/rooms` | `/rooms` | `path: /rooms` | `/rooms` |
| `/api/rooms/rooms/42/join` | `/rooms/42/join` | `path: /rooms` | `/rooms/42/join` |
| `/api/game/games/123/move` | `/games/123/move` | `path: /games` | `/games/123/move` |
| `/api/game/ws/games/123?token=...` | `/ws/games/123` (+ query preserved) | `path: /ws/games` | `/ws/games/123?token=...` |

Also fixed `helm/chess-chart/templates/game-ingress.yaml`'s ALB branch to match: the path was `/game` (`pathType: Prefix`), which is wrong once the function correctly drops the `/game` segment entirely — no `/game`-prefixed path ever reaches the ALB for game traffic, only `/games/...` and `/ws/games/...`. Changed to two separate `pathType: Prefix` rules, `/games` and `/ws/games`, both routed to `game-service`.

**Lesson:** the room/game double-segment quirk (`/api/rooms/rooms`, `/api/game/games`) is a real mismatch between what the frontend calls and what those two services' own routers expect — not something this repo controls or should "fix" by guessing at a cleverer rewrite. The CloudFront Function's job is only to reproduce nginx's existing, working behavior on a platform that can't run nginx-style regex rewrites — not to editorialize on whether that behavior is well-designed. Logged as accepted tech debt, not touched further.

#### Follow-on: no manual `/*` needed on ALB `pathType: Prefix` paths

Tempting to add a trailing `/games/*` by hand, matching how you'd write a path pattern directly in the ALB console — don't. With `pathType: Prefix` (AWS Load Balancer Controller v2.2.0+, the current default), the controller itself expands Kubernetes' Prefix semantics into the correct underlying ALB path-pattern condition(s) — `/games` alone already covers `/games` and everything nested under it. Manually adding a `*` character is rejected outright: `pathType: Prefix` explicitly disallows wildcard characters in the literal path field (`*`/`?` wildcards are only valid under `pathType: ImplementationSpecific` — which is what the nginx branch of this same chart uses instead, for an unrelated reason: real regex capture groups, not ALB-style wildcards).

#### Follow-on: does merging `main-ingress` + `game-ingress` into one ALB (`group.name`) risk ambiguous routing or duplicate DNS records?

Checked, not an issue here:

- **Routing:** `alb.ingress.kubernetes.io/group.name: chess-prod` merges both Ingress objects' rules into one ALB's rule set (standard AWS Load Balancer Controller behavior for `IngressGroup`, not a hack — see Architectural Decisions → ALB/ExternalDNS above). Ambiguity would only matter if merged rules had overlapping path prefixes; `/rooms`, `/auth`, `/games`, and `/ws/games` are fully disjoint, so evaluation order across the merged rule set never matters here. (This is also why the frontend's regex catch-all path being scoped strictly to the nginx branch, not the ALB branch, matters beyond just regex-syntax safety — a stray ALB catch-all would have collided with all four of these.)
- **DNS:** both Ingress objects declare the same `host` (`api-origin.alexit.online`, from the shared `.Values.ingress.host`) and, because they share one physical ALB via `group.name`, the AWS Load Balancer Controller writes the **same** ALB DNS name into both objects' `status.loadBalancer.ingress[].hostname`. ExternalDNS sees two sources converging on one identical (hostname, target) pair, not a conflict — and `policy: upsert-only` (`terraform/modules/external-dns/main.tf`) means it only ever creates/updates records it owns, never deletes, so even a redundant upsert of the same value is a no-op, not a risk.

---

### RDS bootstrap without a VPN/private-VPC dependency (prod) — redesigned 2026-07-05

**The problem:** the original `rds` module created the three per-service databases/users/grants with the `petoju/mysql` Terraform provider, which needs a live TCP:3306 connection to RDS at both `apply` and `destroy` time (RDS sits in private database subnets, `publicly_accessible = false`). In practice that meant `terraform apply` for this one module only worked from prod's VPN or from inside the VPC — fine for a human on a laptop, but this project also wants both local applies and a (GitHub-hosted, not self-hosted) CI runner to be able to run the same `terragrunt apply`, and a GitHub-hosted runner isn't inside the VPC by default.

**Options considered and rejected, in order:**
1. **A wrapper script that brings up the WireGuard tunnel before `terragrunt apply`/`destroy`, universal for local and CI** — works, but only relocates the dependency, doesn't remove it. Also surfaced a real fragility: the `vpn` module's EC2 instance has no persistent storage, so every time it's destroyed and rebuilt (this project routinely tears the whole environment down between sessions for cost — see Progress table), wg-easy generates a brand-new server keypair and peer database, silently invalidating any previously-saved client `.conf`. A durable fix would need either manual peer re-provisioning after every rebuild, or automating it against wg-easy's own REST API — which its own docs describe as "not yet stable... subject to change without notice."
2. **`aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost`** — narrower and more auditable than a full VPN (IAM-scoped access to a specific instance, no shared secret file that can leak, every session logged to CloudTrail, same trust model this project already uses for SSM-only node access, no SSH). Still just relocates the live-connection requirement rather than removing it.
3. **Building the real `ecs-runner`** (self-hosted, natively inside the VPC, no VPN needed for anything) — architecturally the industry-standard answer to "CI needs private network access," and already a documented (not-yet-built) module in this repo. Explicitly not the direction chosen here — no self-hosted runner is planned.

**The actual fix: remove the live-connection requirement instead of routing around it.** `terraform/modules/rds` no longer has a `mysql` provider or `mysql_database`/`mysql_user`/`mysql_grant` resources at all — it only ever *decided* the desired per-service database name/username/password (`random_password` + a naming convention) and *published* that decision to SSM (`auth_secret`; room/game via `elasticache`); it never actually needed to open a MySQL connection to do that part. What used to need a live connection — actually creating the database/user/grant against the real instance — moved to a new Helm hook Job in chess-chart:

- `helm/chess-chart/templates/rds-bootstrap-job.yaml` — runs as an ordinary pod on the existing Karpenter `general` NodePool (no new Fargate profile: chess-chart's other pods already run there and already reach RDS through the existing VPC-CIDR security group rule). Idempotent (`CREATE ... IF NOT EXISTS` + an explicit `ALTER USER` to keep the password in sync even if SSM's value ever changes), and re-runs on every `helm upgrade` via `helm.sh/hook-delete-policy: before-hook-creation` (deletes the prior run's Job right before creating the next one, so the same fixed name is safely reusable). **`pre-install,pre-upgrade` (ArgoCD `PreSync`), not `post-install,post-upgrade`** — see **Troubleshooting → "ArgoCD never creates the `rds-bootstrap` Job at all"** for why `PostSync` is a real deadlock here, not just a less-elegant choice.
- `helm/chess-chart/templates/rds-bootstrap-secret.yaml` — an `ExternalSecret` feeding the Job's credentials. Needs **zero new AWS IAM permissions**: it reuses the existing ESO controller's already-provisioned IRSA role (already scoped to `ssm:GetParameter*` on `/chess-prod/*`) instead of a dedicated role for the Job — a pod's own IRSA trust is locked to one exact namespace:ServiceAccount pair, so the Job couldn't assume ESO's role directly even if it wanted to; instead ESO (using its own role) reads SSM and materializes a plain Kubernetes `Secret`, and the Job just mounts that via `envFrom`, same as every other chess-chart deployment already does.
- The Job parses the *same* `DATABASE_URL` values already published for auth/room/game (`mysql+pymysql://user:pass@host:port/db` — plain bash parameter expansion, no `jq`/regex needed) plus the existing manually-created master password. **Deliberately not a new SSM parameter** — an earlier draft of this fix added a dedicated `bootstrap-credentials` blob duplicating values SSM already had; reverted once pointed out, since it added a second source of truth for the same passwords with no real benefit.

**Dependency graph changes:**
- `terraform/environments/prod/rds/terragrunt.hcl` — dropped its `dependency "vpn"` block (added originally only because the `mysql` provider needed a live connection on *destroy* too, to keep `vpn` alive until `rds` finished tearing down). Back to depending on `vpc` alone, restoring RDS's original apply-time parallelism with `eks`/`karpenter`/`nodepools`.
- `terraform/environments/prod/argocd/terragrunt.hcl` — added three ordering-only dependencies, all output-unused: `rds` (bootstrap Job needs `auth`'s `DATABASE_URL` + the master password), `elasticache` (same Job also needs `room`/`game`'s `DATABASE_URL`, which `elasticache` writes — `rds` deliberately doesn't, see its own SSM-ownership note above), and `alb-controller` (chess-chart's own `Ingress` objects use `ingressClassName: alb`, and the controller's Ingress-validating webhook must be up first — same race class as the existing `argocd → ingress-nginx` dependency, just a different controller). Prod's manual sync policy already gates all of this in practice (a human decides when to sync), but these dependencies make it structurally impossible for ArgoCD to even exist before its prerequisites do, rather than relying only on nobody syncing too early. Audited the full prod dependency graph afterward (`grep` across every `terraform/environments/prod/*/terragrunt.hcl`) to confirm no other gaps of this shape remain and no cycles were introduced.

**Result:** RDS's own `terraform apply`/`destroy` needs no VPN, no `ecs-runner`, and no SSM tunnel at all — it's pure AWS API, works identically from a laptop or a GitHub-hosted runner. The only remaining reason to want VPN access to RDS is optional, occasional human debugging (connect with any MySQL client using the master password), not automation.

---

### ESO's `ClusterSecretStore` fails admission with a certificate hostname mismatch (Fargate only)

**Symptom:** on the very first live `terragrunt apply` after moving ESO onto its own Fargate profile (see Architectural Decisions → ESO), the `eso` unit failed:
```
Error: cluster-secret-store failed to run apply: error when creating "...kubectl_manifest.yaml":
Internal error occurred: failed calling webhook "validate.clustersecretstore.external-secrets.io":
failed to call webhook: Post "https://external-secrets-webhook.external-secrets.svc:443/...":
tls: failed to verify certificate: x509: certificate is valid for
fargate-ip-192-168-11-206.ec2.internal, ip-192-168-11-206.ec2.internal,
not external-secrets-webhook.external-secrets.svc
```
Never happened while ESO ran on EC2 (Karpenter) nodes — confirmed it's specifically the Fargate move that introduced this.

**Cause:** not a webhook-readiness race (the class of bug already fixed for the ALB controller/`ingress-nginx`) — this is a **port conflict**. `external-secrets`' webhook defaults to port `10250`, which collides with Fargate's own internal kubelet-equivalent listener on that exact port (every Fargate pod's "node" is really a per-pod microVM with its own such listener, sharing the pod's IP). kube-apiserver's call to the webhook Service gets answered by that internal Fargate listener instead of ESO's real webhook process, and the certificate it presents is scoped to the Fargate node's own IP hostname — not the webhook's Service DNS name kube-apiserver actually expects, so TLS verification fails before the request is ever handled by ESO. A documented, known Fargate limitation (also hits `cert-manager`'s webhook for the same reason) — not specific to this project's config.

**Solution:** moved ESO's webhook off the conflicting port — added `webhook.port = "9443"` to `helm_release.eso`'s `set` block in `terraform/modules/eso/main.tf`. Same fix AWS's own `terraform-aws-eks-blueprints-addons` module landed on for this exact issue ([issue #55](https://github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/55), PR #373) — confirmed the value path (`webhook.port`, default `10250`) against the exact chart version this project pins (`external-secrets` `v0.10.7`).

**Lesson:** moving a controller onto Fargate isn't a purely additive, risk-free change just because the *reasoning* ("only watches the K8s API, no real EC2 node needed") is sound in the abstract — Fargate's per-pod microVM networking model has its own quirks (shared pod/node IP, a reserved port) that don't exist on EC2 nodes, and can surface as a hard failure only once something that actually depends on the affected mechanism (here: an admission webhook call) gets exercised for real. The ALB controller and ExternalDNS profiles didn't hit this because neither uses port `10250` for anything.

---

### ArgoCD never creates the `rds-bootstrap` Job at all

**Symptom:** after fixing the webhook-port issue above and getting a real ArgoCD sync of `chess-chart` in prod: the `rds-bootstrap-secret` `ExternalSecret`/`Secret` synced fine, but the `rds-bootstrap` Job **never appeared in the cluster at all** — not failed, not pending, just absent, in any namespace. Consequently no databases ever got created, and auth/room/game's own init containers (the Alembic migration ones) failed with the expected "table doesn't exist" symptom (see the earlier Troubleshooting entry) — except this time the actual root cause was one layer further back: the databases themselves didn't exist, not a missing migration step.

**Cause:** the Job's hook annotation was `helm.sh/hook: post-install,post-upgrade`, which ArgoCD maps to its own `PostSync` phase. **ArgoCD only fires `PostSync` hooks once every other resource in the sync has already reached a `Healthy` status** — confirmed against ArgoCD's own docs, not assumed. But auth/room/game's Deployments can never become `Healthy` without the databases this exact Job creates (their init containers crash-loop without them) — a genuine deadlock: ArgoCD waits for the Deployments to be healthy before running the Job, and the Job is the only thing that can make them healthy. Unlike a plain `helm install --wait`, which just runs hooks in order without gating `post-install` on the *health* of everything else, ArgoCD's hook-phase semantics are stricter — this is a documented "gotcha" specific to running Helm hooks through ArgoCD, not a bug in this repo's chart alone.

**Solution:** changed the hook to `pre-install,pre-upgrade` (ArgoCD `PreSync`) — runs *before* the rest of the chart's resources sync at all, so the databases exist by the time the Deployments' init containers ever run. Had to fix `rds-bootstrap-secret.yaml` at the same time: it was a plain (non-hook) resource, which ArgoCD applies during the normal `Sync` phase — after `PreSync` — so with the Job moved to `PreSync`, the Secret it reads via `envFrom` would no longer exist yet either. Made the `ExternalSecret` a `PreSync` hook too, at a lower `hook-weight` ("-1" vs the Job's "0") so it applies first within the same phase. Not a hard guarantee ESO has *finished* reconciling the real `Secret` by the time the Job's pod starts — but Kubernetes itself retries an unresolved `secretRef` at container-start rather than failing outright, so "applied first" is enough; it doesn't need to be "fully reconciled first."

**Lesson:** Helm hook phases don't mean the same thing under ArgoCD as under plain `helm install` — specifically, `post-install`/`post-upgrade` (`PostSync`) carries an implicit "and everything else is healthy first" condition that plain Helm doesn't enforce. Any hook whose job is to make *other* resources' health possible (bootstrapping a dependency they need to start successfully) belongs in `pre-install`/`pre-upgrade` (`PreSync`), not the intuitively-named-but-wrong post-install slot.

---

### Game's WebSocket disconnects immediately in prod (never in dev/staging)

**Symptom:** with everything above finally synced and databases bootstrapped, regular REST calls through the ALB worked end-to-end (`GET /api/game/games/1` → `200`), but opening the game's WebSocket (`wss://chess.alexit.online/api/game/ws/games/{id}?token=...`) failed immediately — no `player_reconnected`/`game_state` message, nothing in game-service's own logs for the `/ws/games/...` path at all (only the unrelated `/games/1` and `/health` lines were there). Never happened in dev/staging, which routes browser → nginx → game-service directly with no CloudFront in the path.

**Ruled out, in order (each took real evidence to eliminate, not assumption):**
1. **CloudFront's 30s default origin-read-timeout** — plausible first guess (idle game = no data on the socket for a while), but the disconnect happened *immediately*, not after ~30s, so this wasn't it. (Tried raising `origin_read_timeout`/`origin_keepalive_timeout` anyway on general principle — see the apply-time follow-up below for why that didn't end up sticking.)
2. **Stale/wrong CloudFront Function code** — checked the function's actual `LIVE` stage directly (`aws cloudfront get-function --stage LIVE`), not just assumed from git history — code matched exactly what should strip `/api/game` correctly. Not this.
3. **Room/game-service application code, or ElastiCache/Redis** — read every relevant file in both services end to end. `websocket.accept()` happens unconditionally, before any Redis call, and Uvicorn logs a WS connection attempt at the ASGI layer regardless of what the app does afterward. Zero log entries for `/ws/games/...` at all meant the request never reached the container — ruling out application code and Redis together in one pass.
4. **Routing/path-stripping bug** — reproduced directly with `curl` against the public CloudFront domain, manually crafting a WebSocket-upgrade-shaped request (`Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-*` headers). Got a `400` from CloudFront itself (`X-Cache: Error from cloudfront`, "This distribution is not configured to allow the HTTP request method... supports only cachable requests") — but critically, the **same 400 also happened on the normally-working REST path** the instant those headers were added. That ruled out routing/path-matching specifically (a routing bug would only break the WS path, not an unrelated working one) and pointed at something CloudFront does with upgrade-shaped requests in general, regardless of path.
5. **Confirmed conclusively by testing the ALB directly, bypassing CloudFront**, using the real client certificate extracted from `origin-mtls`'s Terraform state (`terraform show -json` + parsing the `tls_locally_signed_cert.client`/`tls_private_key.client` resources — ACM doesn't let you export a client cert's private key, but Terraform state still has the plaintext value used to create it) and a temporarily-opened security-group rule (one IP, revoked immediately after the test, verified via `describe-security-groups` that the SG returned to its exact prior state).

**Actual cause, confirmed against AWS's own documentation:** *"WebSocket protocol is not supported for origins with origin mTLS enabled."* This is a hard, documented CloudFront limitation — not a config mistake, not something fixable with headers/policies/timeouts. Origin mTLS (`terraform/modules/origin-mtls`, added earlier to replace the old `X-Origin-Verify` shared-secret header) and WebSocket are simply incompatible for the same CloudFront origin. Every other avenue investigated above was a legitimate, well-reasoned line of investigation that correctly turned out *not* to be the cause — this is what made it a hard bug, not a quick one.

**Why a same-ALB path split (no new mTLS SAN) couldn't just add a second cache behavior:** ALB's `mutual-authentication` setting applies to an entire *listener*, not per-path — with one shared HTTPS:443 listener for the whole merged ALB (`group.name: chess-prod`), there's no way to require mTLS for `/games`/`/auth`/`/rooms` while exempting `/ws/games` on that same listener.

**Solution:** a second ALB listener, same physical ALB, different port (**8443**), with no `mutual-authentication` annotation at all:
- `terraform/modules/alb-controller/main.tf` — a security-group ingress rule covering the **443–8443 port range** in one rule, not two separate port-443 and port-8443 rules (see the apply-time follow-up below for why).
- `terraform/modules/frontend/main.tf` — new CloudFront origin (`alb-game-ws`, same `domain_name`/ALB, `https_port = 8443`, deliberately no `origin_mtls_config`) and a new `ordered_cache_behavior` for `/api/game/ws/*`, positioned *before* the general `/api/*` behavior (CloudFront evaluates `ordered_cache_behavior` blocks in list order, first match wins) — same `strip_api_prefix` function association, same `CachingDisabled`/`AllViewerExceptHostHeader` policies, `compress = false` this time (avoids any risk of CloudFront's compression logic interfering with the upgrade response).
- `helm/chess-chart/templates/game-ws-ingress.yaml` (new) — a **separate Ingress object** for `/ws/games`, not just a second path on the existing `game-ingress.yaml`: since mTLS is listener-scoped, the only way to get one listener with mTLS and one without, on the same merged ALB, is two Ingress objects each declaring their own `listen-ports` (AWS Load Balancer Controller scopes each Ingress object's rules to whichever ports *that object* declares, even inside a shared `group.name`). `game-ingress.yaml`'s ALB branch now only has `/games`; nginx (dev/staging) is untouched — this whole problem is CloudFront-specific and doesn't exist there.
- No frontend/application changes needed at all — the browser still connects to the exact same public URL (`wss://chess.alexit.online/api/game/ws/games/{id}?token=...`); CloudFront's path-based behavior selection transparently routes it to the new mTLS-free origin.

**Two more real errors surfaced applying this fix — both AWS account-level quotas, not code mistakes:**
- `InvalidOriginReadTimeout: ... not within the valid range` on the `frontend` apply, **twice** — first at `origin_read_timeout = 180` (per AWS's own documented "up to 180s without a support request" guidance), then again at `60`. Checked the authoritative source (AWS's `CustomOriginConfig` API reference, not a blog/summary) to rule out a documentation-vs-reality mismatch: the API's own hard schema range is 1–120s for `OriginReadTimeout` (1–300s for `OriginKeepaliveTimeout`) — so 60 should have been valid by the API's own published constraints. Since it wasn't, this account carries a separate, lower, account-specific quota holding it at the literal default with no self-service headroom above it — not visible via the Service Quotas API either (`list-service-quotas --service-code cloudfront` returns nothing for this account). Reverted to leaving both fields unset (CloudFront's hard defaults: 30s response / 5s keep-alive) rather than guess a third value — raising this for real needs an actual AWS Support quota-increase request, not a Terraform change.
- `RulesPerSecurityGroupLimitExceeded` on the `alb-controller` apply — adding a second security-group ingress rule for port 8443 (alongside the existing port-443 rule, both referencing the same CloudFront-managed prefix list) failed. Root cause, confirmed directly: AWS counts a security-group rule that references a managed prefix list as **one quota "slot" per entry in that list**, not one slot per rule (`aws ec2 get-managed-prefix-list-entries` showed 45 entries in `com.amazonaws.global.cloudfront.origin-facing`; `aws service-quotas get-service-quota` confirmed this account's rules-per-security-group limit is 60). Two separate rules referencing the same 45-entry list would cost ~90 slots against a 60-slot budget — over the limit before counting anything else. Fixed by merging both ports into **one rule spanning the 443–8443 range**, so the prefix list is only "charged" once (~45 slots, well within budget). Incidentally allows ports 444–8442 too, but nothing listens there (the ALB itself only has listeners on 443 and 8443), so this isn't meaningfully wider than two precisely-scoped rules would have been.

**Known gap, not fixed here (application-level, not infra):** confirmed by reading the code that game-service has no periodic WebSocket ping/keepalive at all — every message is sent only in response to an actual event (move, resign, connect/disconnect), never on a timer, and neither FastAPI/Starlette nor the frontend do this automatically either. Combined with CloudFront's 30s default origin-read-timeout (now unchanged from default, see above), a sufficiently long pause with no moves and no other traffic on the socket risks a CloudFront-initiated disconnect independent of anything ALB/nginx-side — arguably more exposed now than if a quota increase had gone through. The durable fix is an application-level periodic ping (e.g. every 20–30s) from either end — flagged for the game-service/frontend teams, out of scope for this repo.

**Trade-off — what this decision actually gives up, and why it's still the right call:**

| | Port 443 (`/games`, `/auth`, `/rooms`) | Port 8443 (`/ws/games`) |
|---|---|---|
| Network layer (SG: CloudFront-only prefix list, TCP-only) | ✅ | ✅ unchanged — same SG, just one more port, still not `0.0.0.0/0`, no ICMP/ping |
| Identity layer (origin mTLS — proves *this specific* CloudFront distribution is calling) | ✅ | ❌ dropped — CloudFront cannot present a client cert during a WebSocket upgrade at all |
| Application layer (JWT required to do anything — `ws.py`'s `_decode_token`, closes `4001` otherwise) | ✅ | ✅ unchanged — untouched by any of this |

**What's actually being given up:** only the guarantee that the caller is *specifically this* CloudFront distribution and not some other CloudFront distribution (anyone's) that discovered the ALB's hostname and pointed a custom origin at it. That's a narrower threat than it first sounds — mTLS was never the thing standing between an attacker and the app; a legitimate holder of a *stolen* JWT already reaches the app through the real, public `chess.alexit.online` domain today, mTLS or not, since that's the actual front door. Losing mTLS on this one listener doesn't create a new way to use a stolen token or a new way to skip authentication — it removes one narrow, specific control (anti-impersonation of the edge) for one path, while every other control (network ACL, JWT auth) stays exactly as strong as it was.

**Why this is the correct trade-off, not a workaround:** the alternative was accepting that WebSocket game connections simply don't work in prod at all — mTLS + WebSocket is a hard platform incompatibility CloudFront doesn't support fixing any other way (confirmed against AWS's own docs). Scoping the exception to exactly one path, on exactly one extra port, with every other layer left intact, is the minimum possible concession to get a supported feature working — not "disable security until it works."

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

**Cause:** The existing pod was created before the fix and still holds quota based on old resource specs. Rolling update cannot proceed: it needs to create a new pod first (`maxUnavailable: 0`, explicit for auth/room/game — see Rolling Update Strategy above), but quota is blocked by the old pod's inflated reservation.

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
