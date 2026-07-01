#!/bin/bash
set -euxo pipefail

dnf install -y docker
systemctl enable --now docker

curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir -p /opt/vpn
cd /opt/vpn

cat > docker-compose.yml <<'COMPOSE'
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    environment:
      - WG_HOST=${wg_host}
      - PASSWORD_HASH=${password_hash}
      - WG_DEFAULT_DNS=${wg_default_dns}
    volumes:
      - ./wg-easy:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped

  caddy:
    image: caddy:2
    container_name: caddy
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
    restart: unless-stopped

volumes:
  caddy_data:
COMPOSE

cat > Caddyfile <<'CADDYFILE'
${wg_host} {
  reverse_proxy wg-easy:51821
}
CADDYFILE

/usr/local/bin/docker-compose up -d
