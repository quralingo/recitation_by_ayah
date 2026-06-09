#!/bin/bash
# Runs once on first boot via cloud-init.
# Template variables (repo_url, app_dir) are injected by Terraform templatefile().
# All other bash variables use $VAR syntax (no braces) to avoid conflicts.
set -euo pipefail
exec > /var/log/user-data.log 2>&1

echo "[bootstrap] Starting at $(date)"

# ── Wait for apt to be ready ──────────────────────────────────────────────────
echo "[bootstrap] Waiting for apt locks..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

apt-get update -y
apt-get install -y git curl

# ── Docker Compose plugin ─────────────────────────────────────────────────────
# The Deep Learning AMI ships Docker Engine but may lack the compose plugin.
if ! docker compose version >/dev/null 2>&1; then
  echo "[bootstrap] Installing docker compose plugin..."
  apt-get install -y docker-compose-plugin
fi

# ── nvidia-container-toolkit ──────────────────────────────────────────────────
# Required for GPU passthrough to Docker containers.
# The Deep Learning AMI typically pre-installs this; skip if already present.
if ! nvidia-ctk --version >/dev/null 2>&1; then
  echo "[bootstrap] Installing nvidia-container-toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

# ── Clone repository ──────────────────────────────────────────────────────────
echo "[bootstrap] Cloning repository..."
git clone "${repo_url}" "${app_dir}"
chown -R ubuntu:ubuntu "${app_dir}"

# ── Initial .env ──────────────────────────────────────────────────────────────
cp "${app_dir}/.env.example" "${app_dir}/.env"

# ── Build and start services (HTTP mode; HTTPS configured via init-ssl.sh) ───
echo "[bootstrap] Building and starting services..."
cd "${app_dir}"
docker compose up -d --build

echo ""
echo "[bootstrap] Done at $(date)"
echo "[bootstrap] Services starting. Model download may take 5-15 min on first run."
echo "[bootstrap] Once DNS is pointed to this IP, run:"
echo "             ${app_dir}/deploy/scripts/init-ssl.sh your@email.com"
