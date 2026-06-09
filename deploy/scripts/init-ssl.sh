#!/bin/bash
# First-time HTTPS setup for recite-ayah.quranlingo.app
#
# Run this ONCE after:
#   1. terraform apply completes
#   2. DNS A record points recite-ayah.quranlingo.app to the Elastic IP
#   3. Services are up (docker compose ps shows engine + app + nginx healthy)
#
# Usage:
#   ./deploy/scripts/init-ssl.sh your@email.com
#
# What it does:
#   1. Creates a temporary self-signed cert so nginx can start in SSL mode
#      (nginx refuses to start if the ssl_certificate file doesn't exist)
#   2. Starts/restarts nginx
#   3. Asks Let's Encrypt for a real cert via the webroot challenge
#      (nginx serves /.well-known/acme-challenge/ on port 80)
#   4. Reloads nginx so it picks up the real cert
#   5. The certbot container handles automatic renewal every 12h

set -euo pipefail

DOMAIN="recite-ayah.quranlingo.app"
EMAIL="${1:?Usage: $0 <certbot-notification-email>}"

# Run from repo root regardless of where the script is called from
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

echo "==> [1/4] Creating dummy self-signed certificate for $DOMAIN ..."
docker compose run --rm --entrypoint "" certbot sh -c "
  mkdir -p /etc/letsencrypt/live/$DOMAIN
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout /etc/letsencrypt/live/$DOMAIN/privkey.pem \
    -out  /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
    -subj '/CN=localhost' 2>/dev/null
  echo 'Dummy cert created.'
"

echo "==> [2/4] Starting nginx (using dummy cert) ..."
docker compose up -d nginx
# Give nginx a moment to bind ports
sleep 5

echo "==> [3/4] Requesting real certificate from Let's Encrypt ..."
docker compose run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  --force-renewal \
  -d "$DOMAIN"

echo "==> [4/4] Reloading nginx with the real certificate ..."
docker compose exec nginx nginx -s reload

echo ""
echo "Done. HTTPS is live at https://$DOMAIN"
echo ""
echo "The certbot container will auto-renew the certificate every 12 hours."
echo "To verify renewal works: docker compose run --rm certbot renew --dry-run"
