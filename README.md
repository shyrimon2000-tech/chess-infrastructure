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
| Secrets | plain Secret | plain Secret | ESO (External Secrets) |

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

**Dev / Staging** — internal only, not exposed to the internet. Access via VPN:
- `dev.chess.internal` → dev namespace
- `staging.chess.internal` → staging namespace

DNS is resolved via Route53 private hosted zone (provisioned by Terraform). Both hostnames point to the nginx ingress on the shared EKS cluster. Traffic stays within the VPC.

**Prod** — public via ALB + Route53 public hosted zone. TLS terminated at the ALB.

## Project Roadmap

- [x] Kubernetes manifests — secrets, configmaps, statefulsets, deployments, services, ingress, network policies, resource quota, limit range
- [x] Helm charts — packaging manifests for reusable deployment
- [ ] Terraform — cloud infrastructure provisioning (cluster, DNS, storage)
- [ ] GitHub Actions — CD pipeline for automated production deploys

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


## External Access via VPN + Caddy

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
