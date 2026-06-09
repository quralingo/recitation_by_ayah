#!/usr/bin/env bash
# Start or stop the Quran Muaalem EC2 instance.
# Usage:
#   ./tools/ec2.sh start
#   ./tools/ec2.sh stop

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
INSTANCE_NAME="quran-muaalem"
AWS_REGION="us-east-1"
HEALTH_URL="https://recite-ayah.quranlingo.app/health"
HEALTH_TIMEOUT=180   # seconds to wait for the app to become healthy after start
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}==>${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

cmd="${1:-}"
[[ "$cmd" == "start" || "$cmd" == "stop" ]] || die "Usage: $0 start|stop"

# Look up instance ID by Name tag
info "Looking up instance '${INSTANCE_NAME}' in ${AWS_REGION}..."
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
            "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

[[ "$INSTANCE_ID" != "None" && -n "$INSTANCE_ID" ]] || die "No instance named '${INSTANCE_NAME}' found in ${AWS_REGION}."
info "Instance ID: ${INSTANCE_ID}"

# ── Current state ─────────────────────────────────────────────────────────────
CURRENT_STATE=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text)
info "Current state: ${CURRENT_STATE}"

# ── START ─────────────────────────────────────────────────────────────────────
if [[ "$cmd" == "start" ]]; then
  if [[ "$CURRENT_STATE" == "running" ]]; then
    warn "Instance is already running. Checking app health..."
  else
    info "Starting instance..."
    aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" > /dev/null

    info "Waiting for instance to reach 'running' state..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
    success "Instance is running."
  fi

  info "Waiting for app to become healthy (up to ${HEALTH_TIMEOUT}s)..."
  elapsed=0
  interval=8
  while true; do
    if curl -sf --max-time 5 "$HEALTH_URL" > /dev/null 2>&1; then
      echo ""
      success "Everything is perfect — ${HEALTH_URL} is healthy."
      break
    fi
    if (( elapsed >= HEALTH_TIMEOUT )); then
      echo ""
      die "Timed out after ${HEALTH_TIMEOUT}s waiting for health check."
    fi
    printf "."
    sleep "$interval"
    (( elapsed += interval ))
  done
fi

# ── STOP ──────────────────────────────────────────────────────────────────────
if [[ "$cmd" == "stop" ]]; then
  if [[ "$CURRENT_STATE" == "stopped" ]]; then
    warn "Instance is already stopped."
    exit 0
  fi

  info "Stopping instance..."
  aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" > /dev/null

  info "Waiting for instance to reach 'stopped' state..."
  aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  success "Instance stopped. No charges for compute while stopped (EBS storage still billed at ~\$0.53/day)."
fi
