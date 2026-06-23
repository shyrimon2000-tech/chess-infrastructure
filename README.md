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

## Project Roadmap

- [x] Kubernetes manifests — secrets, configmaps, statefulsets, deployments, services, ingress, network policies, resource quota, limit range
- [ ] Helm charts — packaging manifests for reusable deployment
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
