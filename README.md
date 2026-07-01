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
  - VPC CNI (`aws-node`): pinned off Fargate via `affinity.nodeAffinity` (**2 bugs fixed, 2026-07-01 and 2026-07-02**):
    1. A bare `nodeSelector` key was tried first — EKS addon `configuration_values` is validated against a per-addon JSON schema, and `nodeSelector` isn't a field vpc-cni's schema accepts; `aws eks describe-addon-configuration` is how to check an addon's real accepted fields before guessing.
    2. Switched to `affinity.nodeAffinity` matching `eks.amazonaws.com/compute-type In ["ec2"]` — passed schema validation, but matched **zero real nodes**: real Karpenter-provisioned EC2 nodes carry `eks.amazonaws.com/compute-type` set to an opaque per-node identifier (e.g. `4870584491797336910`), not the literal string `"ec2"` — only Fargate nodes reliably carry the literal value `"fargate"`. Confirmed via `kubectl get node <name> --show-labels`. Result: the `aws-node` DaemonSet sat at `DESIRED: 0` cluster-wide (not even on Fargate — it just matched nothing), which meant **no node anywhere had a CNI plugin**, so the 2 real EC2 nodes stayed `NotReady` for 40+ minutes with `NetworkPluginNotReady: cni plugin not initialized` — masquerading as a slow-boot issue when it was actually a total scheduling mismatch. Fixed by inverting the match: `NotIn ["fargate"]` instead of `In ["ec2"]` — matches any node that isn't explicitly Fargate, using the one label value that's actually confirmed to exist. General lesson: don't assume a label's value without checking `--show-labels` on a real node — `compute-type` sounds like it should have a matching `"ec2"` counterpart to `"fargate"`, but it doesn't.
- **EBS CSI Driver lives in the `nodepools` module, not `eks`** (**bug fixed 2026-07-01**): its controller pod needs a real EC2 node (privileged/hostPath access, unsupported on Fargate), but the only Fargate profile matching `kube-system` is scoped to `k8s-app=kube-dns` (CoreDNS only) — nothing else in `kube-system` schedules anywhere until Karpenter exists. Creating this addon inside `eks` meant Terraform polled `DescribeAddon` for 20 minutes waiting for a node that could never appear yet, then hard-failed (`timeout while waiting for state to become 'ACTIVE' (last state: 'DEGRADED')`). Fix: the `aws_eks_addon` resource + its IRSA role (`module.irsa_ebs_csi`) moved to `nodepools`, with `depends_on = [kubectl_manifest.nodepool]` — by the time it applies, Karpenter has a NodePool to act on, so the unschedulable pod triggers real node provisioning instead of polling into a timeout. `aws_eks_addon` resources aren't required to live in the same module as the cluster — they just need `cluster_name`, and ordering is enforced by the terragrunt `dependency` graph, not file location.
  - **Follow-on bug (same day)**: after moving it, the addon then failed with `CREATE_FAILED ... ConfigurationConflict ... ServiceAccount ebs-csi-controller-sa - .metadata.annotations.eks.amazonaws.com/role-arn`. The *original* failed attempt (back when this addon still lived in `eks`) got far enough to create the `ebs-csi-controller-sa` ServiceAccount and annotate it with that old IRSA role's ARN before timing out — a leftover from a run that never fully succeeded. The new `nodepools`-owned addon tries to set a *different* role ARN (its own, newly created IRSA role) on the same ServiceAccount, and the default conflict-resolution mode refuses to overwrite a field it doesn't already own. Fix: `resolve_conflicts_on_create = "OVERWRITE"` (and `resolve_conflicts_on_update` for the same reason on future changes) on `aws_eks_addon.ebs_csi`. General lesson: a failed `aws_eks_addon` create can still leave partially-reconciled Kubernetes objects behind — retries and relocations aren't guaranteed to start from a clean slate.
  - **Third follow-on (2026-07-02)**: with the addon finally `ACTIVE`, StatefulSet PVCs (`auth-db`, `room-db`, `game-db`, `redis`) still stayed `Pending` — `storageclass.storage.k8s.io "gp3" not found`. EKS ships a default `gp2` StorageClass (legacy in-tree provisioner), but installing the `aws-ebs-csi-driver` addon only gives you the *provisioner* (`ebs.csi.aws.com`) — it doesn't create any `StorageClass` objects that use it. The Helm chart's values files request `storageClassName: gp3` explicitly (matches the documented "DB Storage: EBS gp3" decision), but nothing in this repo had ever actually created that StorageClass. Added `kubectl_manifest.gp3_storage_class` to `nodepools` (same module as the addon itself) — provisioner `ebs.csi.aws.com`, `parameters.type: gp3`, `volumeBindingMode: WaitForFirstConsumer`.
  - **Second follow-on**: adding `resolve_conflicts_on_create` to the Terraform config alone wasn't enough — the addon object from the *first* failed attempt was already sitting in AWS in `CREATE_FAILED` state, still carrying whatever conflict-resolution mode it was originally created with. `CreateAddon` doesn't re-apply new parameters to an addon that already exists in some state; it needed `aws eks delete-addon --cluster-name chess-shared --addon-name aws-ebs-csi-driver` (then `aws eks wait addon-deleted`) as a one-time manual cleanup before a fresh `terraform apply` could create it cleanly with the corrected settings. Confirmed via `aws eks describe-addon` directly — don't assume a Terraform code fix retroactively repairs an already-broken cloud-side object; check ground truth against the API.
- **Access entries — `enable_cluster_creator_admin_permissions = false`, always explicit `access_entries.personal`** (**bug fixed 2026-07-01, two rounds**): left `true`, Terraform tried to explicitly create `aws_eks_access_entry.this["cluster_creator"]` for the applying IAM principal and got `409 ResourceInUseException` ("already in use"). First fix attempt: kept it `true` as a safety net and skipped the explicit `access_entries.personal` block when it matched `data.aws_caller_identity.current.arn`, on the theory that AWS auto-grants the cluster creator admin access implicitly at `CreateCluster` time (a real, documented AWS behavior in general). **That theory didn't hold up empirically** — `aws eks list-access-entries` afterwards showed no entry at all for the applying principal, meaning helm/kubectl providers failed with `the server has asked for the client to provide credentials` (valid AWS IAM identity, zero Kubernetes RBAC mapping). Final fix: `enable_cluster_creator_admin_permissions` stays `false`, and `access_entries.personal` is created **unconditionally** whenever `admin_principal_arn` is set — no reliance on any implicit AWS-side grant, since it demonstrably didn't produce a usable one here. Lesson: verify AWS-side claims against the actual API (`list-access-entries`) rather than trusting documented default behavior when something doesn't line up — this project's IAM history is otherwise consistent with production practice regardless: explicit, reviewable `access_entries` per principal (human admin now, CI runner role later) instead of "whoever applies first becomes admin."

**Bug fixed 2026-07-02 — no DNS on EC2 nodes at all**: CoreDNS runs on Fargate (deliberate — see two-tier compute model), so every pod on a Karpenter-provisioned EC2 node has to reach it across the Fargate/EC2 boundary for DNS resolution. `terraform-aws-modules/eks/aws` doesn't bridge these by default: EC2 nodes get their own node security group, and Fargate pods get attached to AWS's own auto-created "primary" cluster security group (`cluster_primary_security_group_id` — **not** the same as the module's own separately-managed `cluster_security_group_id`, which is a different, additional SG used only for specific control-plane webhook rules; first fix attempt targeted the wrong one and would have been a no-op). Neither SG accepts traffic from the other by default. Symptom looked like a slow/stuck node (`NetworkPluginNotReady`) and later an IRSA/STS failure (EBS CSI driver's `AssumeRoleWithWebIdentity` timing out) — both were actually the same root cause: DNS resolution to anything, including `sts.us-east-1.amazonaws.com`, was failing on every EC2-hosted pod. Confirmed via a throwaway debug pod (`kubectl run ... --overrides='{"spec":{"nodeSelector":...}}'`) pinned to the affected node: `nslookup sts.us-east-1.amazonaws.com` (in-cluster resolver) timed out, `nslookup amazonaws.com 8.8.8.8` (bypassing CoreDNS entirely) worked — proving general internet/NAT egress was fine and the gap was specifically pod-to-Fargate-pod traffic within the VPC. Fixed with two `aws_security_group_rule` resources (both directions, all ports/protocols) between `cluster_primary_security_group_id` and `node_security_group_id`. This would have blocked **every** EC2-hosted workload's DNS resolution, not just the EBS CSI driver — the chess microservices themselves would have hit the identical wall.

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

**VPN**
- WireGuard (wg-easy) + Caddy on a single EC2 instance, SSM-only management (no SSH, no port 22)
- **Bug fixed 2026-07-01**: `aws_security_group.vpn`'s `description` used an em-dash (`—`) — `InvalidParameterValue: Character sets beyond ASCII are not supported`. AWS EC2 `GroupDescription` is ASCII-only; fixed by swapping the em-dash for a plain hyphen (`-`). Applies to any free-text AWS resource description/tag field, not just this one — typographic punctuation (em/en dashes, smart quotes, ellipsis character) copy-pasted into Terraform string literals is a recurring source of this exact error.
- **Bug fixed 2026-07-01 — wg-easy password silently didn't work**: the bcrypt hash from SSM (`$2a$10$...`) was interpolated straight into `docker-compose.yml` via `templatefile()`. The bash heredoc that *writes* the file (`<<'COMPOSE'`, quoted delimiter) correctly leaves `$` alone — but **`docker-compose` itself re-parses the file's `$VAR`/`${VAR}` syntax when you run `docker-compose up`**, independent of the shell that wrote it. A bcrypt hash always has at least three literal `$` (version, cost, salt/hash separators), each treated as an undefined variable reference and dropped/mangled — the hash that actually reaches the container's `PASSWORD_HASH` env var is corrupted, even though the value in SSM and the password used to generate it were both correct. Fix: `replace(data.aws_ssm_parameter.wg_easy_password_hash.value, "$", "$$")` before passing it to `templatefile()` — `$$` is docker-compose's own escape sequence for a literal `$`, so the file on disk round-trips back to the real hash. General lesson: any secret containing `$` (bcrypt hashes, some generated passwords) needs this same escaping if it's ever written into a docker-compose file, regardless of how it got there.

**ArgoCD / GitOps**
- **Two `ApplicationSet`s per ArgoCD instance** (`chess-chart-automated`, `chess-chart-manual`), split by sync mode — not one ApplicationSet with a Go-template `{{if}}` for conditional sync policy (see bugs below for why). Each is a `list` generator + `goTemplate: true`, filtered in Terraform (`local.automated_environments` / `local.manual_environments`, via `[for env in var.environments : env if env.automated]`) — `count = length(...) > 0 ? 1 : 0` so an empty split (e.g. prod, which is 100% manual) doesn't create an ApplicationSet with a null/empty `elements` list.
- Bootstrap (both `ApplicationSet`s) is created by Terraform (`kubectl_manifest`), not a manual one-time `kubectl apply` — keeps `terragrunt apply` alone sufficient to rebuild the whole GitOps loop from zero. Everything downstream (image tags, replicas, values) still flows through git only.
- Branch mapping: dev + staging watch the `dev` branch, prod watches `main`
- Sync policy: dev = automated + prune (no selfHeal — keeps live `kubectl` debugging possible without instant revert), staging + prod = manual
- `server.insecure = true` when ingress is enabled — argocd-server's own self-signed TLS would otherwise mismatch nginx's plain-HTTP proxy to the backend; acceptable since traffic is already inside the VPN tunnel + private VPC
  - **Bug fixed 2026-07-02 — redirect loop, then a stale ConfigMap**: browsing `argocd.chess.internal` first hit `ERR_TOO_MANY_REDIRECTS`. ingress-nginx assumes an HTTPS-capable backend and forces an HTTP→HTTPS redirect by default even with no TLS configured on the Ingress; fixed with `nginx.ingress.kubernetes.io/backend-protocol: HTTP` + `nginx.ingress.kubernetes.io/ssl-redirect: false` on the Ingress annotations. That alone didn't fix it — `curl -v` still showed a `307` to `https://`, but the response body (Go's default `http.Redirect` HTML, no `Server: nginx` framing) pointed at **argocd-server itself** redirecting, not nginx. `kubectl get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].args}'` showed no `--insecure` flag — this chart applies `server.insecure` via the `argocd-cmd-params-cm` ConfigMap (read at process startup), not a CLI arg. `kubectl get cm argocd-cmd-params-cm -o jsonpath='{.data}'` showed `"server.insecure":"false"` even though `helm get values argocd` confirmed `insecure: true` was in the latest release's user-supplied values — `helm history argocd` showed **every one of 4 revisions**, including the one marked `deployed`, carrying a failure description from the same ingress-nginx admission-webhook race documented above, meaning the upgrade kept dying partway through applying the chart's resources before the ConfigMap got patched. Fixed by patching the ConfigMap directly (`kubectl patch cm argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'`) and `kubectl rollout restart deployment/argocd-server` (ConfigMap changes aren't hot-reloaded — the pod only reads it at startup). Lesson: `helm history`'s `STATUS: deployed` on the latest revision doesn't guarantee that revision's values fully landed if earlier revisions in the same release repeatedly failed partway through — check the live resource, not just the release status.
- No verified community Terraform module exists for ArgoCD — installed via raw `helm_release` (argo-helm chart), same as Karpenter
- **Ordering bug fixed 2026-07-02**: `argocd`'s `helm_release` (with `server.ingress.enabled = true`) creates an `Ingress` resource that's validated by ingress-nginx's admission webhook — but `argocd` and `ingress-nginx` were siblings in the terragrunt DAG (both only depended on `eks`), so `run --all apply` could run them in parallel and race: `Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io" ... no endpoints available for service "ingress-nginx-controller-admission"`. Fixed with an **ordering-only** terragrunt `dependency "ingress_nginx"` block in `environments/shared/argocd/terragrunt.hcl` — its output isn't consumed by any input, the block's mere presence is what forces `ingress-nginx` to fully apply (including `helm_release`'s default wait-for-ready behavior) before `argocd` starts. Not needed in prod — prod's `argocd` never sets `ingress_enabled` (ALB there instead of nginx), so it never creates an `Ingress` at all.

**Two YAML bugs fixed 2026-07-01, both only surfaced on the first real `kubectl_manifest` apply** (every earlier `plan`/`validate` had failed even earlier, at the `kubectl` provider's PEM-cert mock-config step, before ever reaching this resource — so neither bug had ever actually been exercised before):
- **`%{for}` loop body indentation** (`yaml: line 12: did not find expected key`): the loop body's `- env: ${env.name}` line ended up *less* indented than its own sibling keys (`namespace:`, `valuesFile:`, ...) after Terraform's heredoc dedent interacted with the `%{for ...~}` / `%{endfor~}` markers — invalid YAML (a mapping's keys must be indented consistently, and a list item can't be less indented than its own children). Debugged by rendering the exact heredoc in an isolated scratch Terraform config (`terraform apply` + `terraform output -raw`) to see the literal byte-level output instead of guessing at heredoc dedent semantics by eye. Fixed with `%{~for ...~}` (trim both sides) and indenting the loop body to land at the same column as its parent list marker.
- **Bare `{{- if .automated }}...{{- end }}` isn't valid standalone YAML**: `kubectl_manifest` (provider `alekc/kubectl`) parses `yaml_body` client-side with a strict YAML decoder *before* the document ever reaches ArgoCD — and unquoted `{{` at the start of a scalar is a YAML flow-mapping indicator, so a bare Go-template conditional spanning multiple keys can't parse (`did not find expected node content`). Same root cause hit `prune: {{ .prune }}` (unquoted) further down — `invalid map key: map[interface{}]interface{}{".prune": nil}`, i.e. `{{ .prune }}` got parsed as a nested one-entry flow mapping, not a template placeholder. Every *working* `{{...}}` usage in this file was already single-quoted (`'{{.env}}'`, `'{{.namespace}}'`); the two that weren't are what broke. Fix for the quoting part: `prune: '{{ .prune }}'`. Fix for the structural `{{if}}` (quoting alone doesn't help — you can't quote your way into optional key *presence*): moved the decision to Terraform, since `env.automated` is already known at `terraform apply` time — two separate `kubectl_manifest` resources instead of one shared template relying on ArgoCD-runtime conditional YAML structure.

**ESO — External Secrets Operator**
- `helm_release` (chart `external-secrets/external-secrets`) + `kubectl_manifest` for `ClusterSecretStore`, same bootstrap pattern as ArgoCD's `ApplicationSet`
- One IRSA role per environment, scoped to `ssm:GetParameter[s][ByPath]` on `arn:...:parameter/${var.name}/*` — shared's role can only read `/chess-shared/*`, prod's only `/chess-prod/*`, no cross-environment access even by mistake
- `ClusterSecretStore` (fixed name `cluster-secret-store` — hardcoded in every chess-chart `values.yaml` `secretStoreRef.name`, must match exactly) has **no explicit `auth` block** — ESO falls back to the credentials of its own controller pod, i.e. the IRSA role above via the AWS SDK's default credential chain. Simpler than `auth.jwt.serviceAccountRef` (which would need extra RBAC for cross-namespace service account references) since there's only one ESO controller per cluster.
- `terraform/modules/eso/` intentionally has no `outputs.tf` — nothing consumes an ESO output yet; added back if/when something needs `role_arn`
- **Ordering bug fixed 2026-07-02**: same root cause as the EBS CSI Driver — the ESO controller pod runs in the `external-secrets` namespace, which no Fargate profile covers, so it can only schedule on a real EC2 node. `eso` only depended on `eks`, so it could apply in parallel with `karpenter`/`nodepools` and its `helm_release` would time out (`context deadline exceeded`) waiting for a pod with nowhere to run. Fixed the same way as the ArgoCD webhook race: an ordering-only `dependency "nodepools"` block (shared + prod), output unused, just forces apply order.

### Progress

| Module | Status |
|---|---|
| S3 state bucket | done (manual) |
| VPC (shared + prod) | applied ✓ (shared) |
| EKS (shared + prod) | **applied ✓ (shared)** — 5 bugs fixed 2026-07-01/02 (vpc-cni config schema, vpc-cni affinity value, EBS CSI Driver ordering, access entry conflict × 2 rounds, Fargate↔EC2 security group gap) |
| Karpenter (shared + prod) | applied ✓ (shared) |
| NodePools (shared + prod) | **applied ✓ (shared)** — owns EBS CSI Driver addon + `gp3` StorageClass; 3 bugs fixed (SA annotation conflict, stuck `CREATE_FAILED` addon needing manual `delete-addon`, missing `gp3` StorageClass) |
| ECS runner (shared + prod) | written, **deferred on purpose** (`exclude` in terragrunt.hcl) — building last |
| ingress-nginx (shared) | **applied ✓** |
| Route53 private zone (shared) | **applied ✓** — `dev`/`staging`/`argocd`.chess.internal all resolve and route correctly |
| VPN — WireGuard (shared + prod) | **applied ✓ (shared)** — 2 bugs fixed (ASCII-only security group description, docker-compose `$` escaping mangling the wg-easy password hash) |
| ArgoCD (shared + prod) | **applied ✓ (shared)** — 4 bugs fixed (heredoc loop indentation, bare Go-template `{{if}}` not valid YAML → split into 2 ApplicationSets, ingress-nginx admission webhook race, redirect loop + stale ConfigMap after repeated failed upgrades) |
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
