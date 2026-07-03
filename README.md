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
| `/chess-prod/rds/master-password` | rds (`admin` login for the RDS instance — used by this module's own `mysql` provider to create the three per-service databases/users, and by you directly for manual DB admin access over the VPN) |
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

Apply order (Layer 1 — self-hosted Fargate runner, or a laptop while `endpoint_public_access = true`): `eks → vpn → karpenter → nodepools → ingress-nginx → route53 → argocd → eso` — same shape for both shared and prod now; prod's `ingress-nginx`/`route53` exist solely to keep ArgoCD VPN-only, not for app traffic (that's the public ALB, applied independently).

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
  - VPC CNI (`aws-node`) pinned off Fargate via `affinity.nodeAffinity` on `eks.amazonaws.com/compute-type NotIn ["fargate"]` — see **Troubleshooting → "VPC CNI's node-affinity matched zero real nodes"** for why it's `NotIn` and not the more obvious-looking `In ["ec2"]`
- **Design rule: anything whose pod needs a real EC2 node doesn't belong in `eks`.** `eks` only creates what can run on Fargate or needs no compute at all (cluster, core addons, IAM). The EBS CSI Driver addon + its IRSA role live in `nodepools` instead, applied only once Karpenter has a `NodePool` to actually provision from. Same rule extended to `argocd`/`eso` via ordering-only terragrunt dependencies (`argocd → ingress-nginx`, `eso → nodepools`) rather than moving those modules themselves, since they don't own compute-dependent *resources*, just need something else's compute to exist first. Learned the hard way — see **Troubleshooting → "Addons stuck waiting for compute that doesn't exist yet"**.
- Access entries: `enable_cluster_creator_admin_permissions = false`; `access_entries.personal` created unconditionally from `ADMIN_PRINCIPAL_ARN` (see Prerequisites) — no implicit "whoever applies becomes admin" fallback
- Fargate↔EC2 security group bridge (`cluster_primary_security_group_id` ↔ `node_security_group_id`) — see **Troubleshooting → "No DNS resolution on EC2-hosted pods"**

**Karpenter**
- Single `general` NodePool — all chess services bin-packed on the same nodes
- Instance types: t3/t3a medium+large (x86, amd64 only)
- **shared**: Spot instances — cost optimized, interruptions acceptable in dev/staging
- **prod**: on-demand instances — room-service can't tolerate Spot interruptions (Redis). Game-service state is persisted to the DB, so a Spot interruption wouldn't lose data — but the client's reconnect window is a hard 30s timeout, and a Spot interruption's full notice-to-reschedule cycle can easily exceed that, turning into a real scored loss for the player, not just a data-loss risk.
- Consolidation: `WhenEmptyOrUnderutilized` + 30s (shared), `WhenEmpty` + 5m (prod)
- Node limits: 8 CPU / 32Gi per cluster (parametrized via `cpu_limit` / `memory_limit` inputs)
- `null_resource.wait_for_node_termination` (destroy-time `local-exec`) polls `aws ec2 describe-instances` for actual node termination instead of trusting a fixed `time_sleep` duration — see **Troubleshooting → "`terragrunt destroy` fails with `DependencyViolation` deleting the node security group"**

**Frontend**
- Prod: S3 + CloudFront (static assets, no pod in cluster) — `terraform/modules/frontend`
- Dev / Staging: container in EKS (shared cluster)
- **Fully independent of EKS/VPC** — no `dependency` blocks in `terraform/environments/prod/frontend/terragrunt.hcl` at all. Static hosting doesn't need a cluster, a VPC, or even prod's other units to exist first; it can apply/destroy on its own schedule.
- **Excluded from `run --all destroy` specifically** (`exclude { if = get_terraform_command() == "destroy", actions = ["all"] }`) — still fully included in `run --all apply`/`plan`. Unlike EKS/EC2/NAT (the actual cost drivers behind tearing `shared`/`prod` down between sessions), S3 + CloudFront cost cents to sit idle, so there's no cost reason to destroy it on the same cycle. It also isn't cheap to *redo* — CloudFront takes 15-30 minutes to propagate a new distribution to edge locations, so destroying and reapplying it on every cost-saving teardown would make `chess.alexit.online` unreachable for that whole window, every single cycle, for no benefit.
- **S3 is private, CloudFront reads via Origin Access Control (OAC)** — no S3 static website hosting, no public bucket policy. `aws_s3_bucket_public_access_block` blocks all four public-access vectors; the only allowed reader is this exact CloudFront distribution, enforced by an `AWS:SourceArn` condition in the bucket policy (not just "any CloudFront", a specific one). OAC is the current AWS-recommended approach — the older Origin Access Identity (OAI) is legacy.
- **ACM certificate in us-east-1** — a CloudFront hard requirement regardless of which region the distribution's origin lives in. Not a special case here since this whole project already runs in us-east-1 (see `root.hcl`); a project centered on another region would need a second, aliased `aws` provider just for this one certificate.
- **SPA routing via `custom_error_response`** — a direct hit on a client-side route (e.g. `/profile/123`) doesn't exist as an S3 object. A private bucket denies unknown keys with `403` (not `404` — it won't reveal whether the key exists at all), so both `403` and `404` are rewritten to `/index.html` with a real `200`, letting React Router take over client-side instead of the browser showing a raw CloudFront error page.
- **Terraform provisions infrastructure only, never uploads content** — same principle as ArgoCD/GitOps (infra vs. delivery stay separate). No `aws_s3_object` resources tracking build output in state; that would couple this repo to the frontend's build artifacts and cause a Terraform diff on every frontend deploy for content Terraform doesn't actually need to know about. Instead, Terraform writes the bucket name and CloudFront distribution ID to plain-`String` (not `SecureString` — neither is a secret) SSM parameters (`/chess-prod/frontend/s3-bucket`, `/chess-prod/frontend/cloudfront-distribution-id`) that the separate `chess-frontend-service` repo's own CI reads to run `aws s3 sync` + a cache invalidation after each build — works identically whether triggered locally or from a future GitHub Actions runner, without hardcoding either value into that repo. Both params set `overwrite = true` — `aws_ssm_parameter` defaults to `false` on create specifically to avoid clobbering a parameter it doesn't already own, but a stale value left behind by a prior destroy/apply cycle that never made it into *this* state should always just be replaced with what the current apply actually produced (same failure class as the Helm "name still in use" and EKS "addon already exists" bugs — see Troubleshooting — neither of these two params is a secret needing manual bootstrap, so there's nothing worth preserving).
- **CloudFront is multi-origin: S3 (default) + ALB (`/api/*`)** — one public hostname (`chess.alexit.online`) for both static assets and the backend API, chosen specifically to avoid a cross-origin (CORS) setup between frontend and backend. See the ALB / ExternalDNS section below for why the ALB origin can reference a hostname that doesn't resolve to anything at the moment this distribution is created.

**ALB / ExternalDNS (prod only — dev/staging use ingress-nginx internally, no public ALB)**
- **Terraform does not create the ALB.** It only installs two Kubernetes controllers (IRSA + Helm, same shape as `ingress-nginx`/`karpenter`): the **AWS Load Balancer Controller** (watches `Ingress` resources, creates/manages the actual ALB, target groups, and listener rules) and **ExternalDNS** (watches the same `Ingress` resources, creates the matching Route53 record). Confirmed against the controller's own official docs: it always creates and fully owns the ALB's lifecycle — there is no supported way to pre-create an ALB in Terraform and have the controller "adopt" it. The real ALB only exists after ArgoCD deploys chess-chart's `Ingress` objects (`main-ingress.yaml`, `game-ingress.yaml`, `ingressClassName: alb`) — an async step outside this repo's `terraform apply` entirely.
- **This creates a real sequencing problem for CloudFront**, which needs to know the ALB's origin domain *at the moment the distribution is created* — but the ALB doesn't exist yet at that point. **ExternalDNS is what resolves this without a second `terraform apply`:** CloudFront's ALB origin is configured with a stable, pre-decided hostname (`api-origin.alexit.online`, `frontend` module's `api_origin_hostname` input) that doesn't resolve to anything the moment `terraform apply` runs — CloudFront only needs an origin to resolve when an actual request routes there, not at distribution-creation time. Once chess-chart's `Ingress` applies later and the ALB Controller creates the real ALB, ExternalDNS notices the same `Ingress` object and automatically creates the Route53 A/ALIAS record for `api-origin.alexit.online` pointing at it — fully autonomously, the same GitOps-reconciliation shape as ArgoCD/ESO already use elsewhere in this project.
- **For `Ingress` resources specifically, ExternalDNS reads the target hostname straight from `spec.rules[].host`** (`ingress.host` in `values-prod.yaml`) — not from an `external-dns.alpha.kubernetes.io/hostname` annotation, which is a Service-only mechanism. Confirmed against ExternalDNS's own AWS integration docs after an initial wrong assumption here (see git history) — worth calling out since the two mechanisms look similar but apply to different resource kinds.
- **`ingress.host` in `values-prod.yaml` is `api-origin.alexit.online`, not `chess.alexit.online`.** The public hostname end users hit is CloudFront's; the ALB never receives direct public traffic under its own name — it only receives proxied requests from CloudFront for the `/api/*` path, and its host-based listener rule (generated from `ingress.host`) must match the `Host` header CloudFront actually sends, which is the origin's `domain_name` (`api_origin_hostname`), not the viewer's original `Host`. These two values are set independently in two different repos/files and must stay in sync by hand — the `frontend` module's `api_origin_hostname` variable and `values-prod.yaml`'s `ingress.host` — there's no single source of truth linking them yet.
- **`alb.ingress.kubernetes.io/group.name: chess-prod`** on both `main-ingress.yaml` and `game-ingress.yaml` — without it, two separate `Ingress` objects get two separate ALBs from the controller, not the "single ALB" CLAUDE.md describes. Same annotation value on both merges them into one ALB with combined listener rules.
- **ALB has no TLS certificate or HTTPS listener at all** — TLS for end users terminates at CloudFront (which already holds the ACM cert for `chess.alexit.online`, see Frontend section); the CloudFront-to-ALB hop is plain HTTP over AWS's internal network (`origin_protocol_policy = "http-only"` in the `frontend` module). Simpler than issuing and rotating a second certificate for an internal-only hop nothing public ever touches directly.
- **AWS Load Balancer Controller and ExternalDNS each get their own dedicated namespace + Fargate profile** (`aws-load-balancer-controller`, `external-dns`) in the `eks` module, not `kube-system` — the existing `kube_system` Fargate profile is scoped only to CoreDNS (`k8s-app=kube-dns`), so a pod merely living in `kube-system` wouldn't actually match it and would need a real EC2 node instead. Same reasoning as the existing `karpenter`/`argocd`/`grafana`/`ingress-nginx` profiles: these controllers only watch the K8s API and call AWS APIs, no real compute needed. Defined unconditionally in the shared `eks` module (used by both `shared` and `prod`) — harmless for `shared`, which never runs these controllers at all.
- **IAM policy for the ALB Controller is AWS's own published JSON** (`terraform/modules/alb-controller/iam_policy.json`, fetched verbatim from `kubernetes-sigs/aws-load-balancer-controller`'s `docs/install/iam_policy.json`), not hand-written — the controller needs a genuinely large set of EC2/ELB permissions to create and manage load balancers, target groups, listeners, and security groups on its own.
- **ExternalDNS's Route53 write permission (`route53:ChangeResourceRecordSets`) is scoped to exactly the one hosted zone ARN** (`alexit.online`), not account-wide — same least-privilege reasoning as ESO's per-environment SSM path scoping. The read-only discovery actions (`ListHostedZones`, `ListResourceRecordSets`, `ListTagsForResources`) have to stay account-wide since Route53's API doesn't expose a per-zone ARN for those calls.
- **`policy = "upsert-only"`** on the ExternalDNS Helm release — it will create and update records it owns, but never delete a record just because the matching `Ingress` disappeared. Safer default for a shared public hosted zone that also holds unrelated records (the `vpn` module's `vpn-prod.alexit.online`, etc.) than `policy = "sync"`, which would actively reconcile-by-deletion.
- **Well-Architected angle (Operational Excellence pillar): ExternalDNS exists specifically to remove a manual step, not just to be "more automated" for its own sake.** Without it, wiring `api-origin.alexit.online` → the real ALB after every deploy would be a human task — someone has to notice the ALB was (re)created, copy its DNS name, and update a Route53 record by hand, a step that's easy to forget, easy to get stale after the ALB is replaced (e.g. a listener/target-group change that forces ALB recreation), and easy to typo. ExternalDNS turns that into a reconciling control loop tied to the actual cluster state (the `Ingress` object), the same "operate via code, not manual runbook steps" principle already applied elsewhere in this project (ArgoCD for deploys, ESO for secrets) — one less place where a person is the thing keeping frontend↔backend connectivity correct.
- **The ALB is reachable from nowhere except CloudFront — two independent layers, not one.** By default the controller auto-creates a permissive security group open to the internet on the listener ports. Instead, `terraform/modules/alb-controller` creates its own `aws_security_group.alb`, referenced by the Ingress via `alb.ingress.kubernetes.io/security-groups` (matched by the SG's `Name` **tag**, not its AWS-generated `groupName` — easy to get wrong), which bypasses that auto-creation. `manage-backend-security-group-rules: "true"` keeps the controller still auto-managing the ALB→pod backend rules despite the custom frontend SG.
  1. **Network layer** — ingress restricted to AWS's managed prefix list `com.amazonaws.global.cloudfront.origin-facing` (port 80 only, since the ALB has no HTTPS listener — see above). Authoritative, AWS-maintained source for "which IPs does CloudFront originate from" — hand-maintaining that CIDR list would go stale as AWS rotates edge IPs.
  2. **Identity layer — `X-Origin-Verify` header check.** The prefix list alone only proves traffic came from *some* CloudFront distribution — that IP range is shared across every CloudFront customer on AWS, not exclusive to this one. CloudFront's origin config adds a `custom_header` (`terraform/modules/frontend`) carrying a shared secret to every request it sends the ALB origin; each real backend path's Ingress rule carries a matching `alb.ingress.kubernetes.io/conditions.<service>` HTTP-header condition (combined via AND with the existing path match — a request that matches the path but not the header matches no rule at all, and ALB's own default-no-match behavior is a plain 404, so no separate deny-all fixed-response action is needed). Without this second layer, anyone who discovers `api-origin.alexit.online` (a normal, publicly-resolvable record once ExternalDNS creates it — nothing about it is actually hidden) could point their own CloudFront distribution at the same ALB and pass the IP check too.
  - **This secret is committed in plaintext**, in both `helm/chess-chart/values-prod.yaml` (`ingress.alb.originVerifySecret`) and `terraform/environments/prod/frontend/terragrunt.hcl` (`origin_verify_secret`) — Ingress annotations are static content rendered from `values.yaml` at Helm template time, not populated from an ESO-managed `Secret` object at runtime, so there's no mechanism to keep this specific value out of git the way `DATABASE_URL`/`JWT_SECRET_KEY`/etc. stay in SSM. Accepted explicitly as a public-pet-project tradeoff: if this were a private/closed-source repo, plaintext-in-git wouldn't even be an exposure (repo access is already the access control); a real production team would more likely inject this at deploy time from a secret store instead of committing it either way. If this value leaks, the practical impact is narrow and non-catastrophic — it degrades this specific check back down to "any CloudFront customer's traffic, not just this one" (the IP-prefix-list layer still holds, blocking plain non-CloudFront internet traffic), not a hole into the backend services themselves, which still require their own normal application-level auth regardless.

**RDS (prod only — dev/staging keep the in-cluster MySQL StatefulSet)**
- **One Multi-AZ MySQL 8.0 instance, three logical databases** (`auth_db`, `room_db`, `game_db`) — not three separate RDS instances. Matches the ~$40-50/mo estimate in CLAUDE.md (a single Multi-AZ instance's ballpark, not 3x it) while still respecting "each service owns its own database, no shared database" — the isolation boundary is per-database credentials, not per-instance.
- **Dedicated MySQL user per database, not one shared master user** — `mysql_user` + `mysql_grant` (`ALL PRIVILEGES`, scoped to exactly one database each) via the `petoju/mysql` provider, not the AWS provider. `ALL PRIVILEGES` and not a narrower DML-only set because alembic's `upgrade head` init container (see Troubleshooting) needs DDL — `CREATE`/`ALTER`/`DROP TABLE` — not just row-level access; the isolation is "which database", not "which SQL statements". A leaked `room_user` credential can't touch `auth_db` or `game_db` at all.
- **The `mysql` provider needs a live MySQL connection at apply time** — RDS sits in the private database subnets (`publicly_accessible = false`), so this module only applies successfully while connected to prod's VPN (or from inside the VPC, e.g. the future `ecs-runner`) — same operational constraint this project already has for any `kubectl`/`helm` provider call against the EKS API.
- **Depends only on `vpc`, deliberately not on `eks`** — applies in parallel with the cluster instead of queuing behind it. RDS provisioning (storage allocation, Multi-AZ standby setup, DNS propagation) takes 10-15+ minutes regardless of what else is happening, so by the time `chess-chart` is actually ready to deploy, the database is already up rather than adding its own startup time to the critical path.
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
| RDS (prod) | module written (`terraform/modules/rds`), `terragrunt validate` passes — not yet applied (needs VPN connectivity for the `mysql` provider) |
| ElastiCache / Redis (prod) | module written (`terraform/modules/elasticache`), `terragrunt validate` passes — not yet applied |
| ALB Ingress Controller (prod) | modules written (`alb-controller`, `external-dns`), `terragrunt validate` passes — not yet applied. Real ALB won't exist until chess-chart is deployed via ArgoCD (see ALB/ExternalDNS section) — end-to-end `/api/*` routing through CloudFront unverified until then |
| ExternalDNS (prod) | module written (`terraform/modules/external-dns`), `terragrunt validate` passes — not yet applied |
| ArgoCD RBAC per environment | not started — **required by interview task** |
| Route53 public zone (prod) | not started |
| S3 + CloudFront (prod frontend) | module written (`terraform/modules/frontend`), `terragrunt validate` passes — not yet applied |

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

**Solution:** moved the EBS CSI Driver addon + its IRSA role from the `eks` module into `nodepools` (`depends_on = [kubectl_manifest.nodepool]`), and added ordering-only terragrunt `dependency` blocks (output deliberately unused — the block's presence alone forces DAG ordering) for `eso → nodepools` and `argocd → ingress-nginx` (same shape of problem, different trigger — an admission webhook, not compute). Once nodes can actually be provisioned before the addon's create call starts, Karpenter picks up the unschedulable pod and provisions a node inside the addon's own timeout window.

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
