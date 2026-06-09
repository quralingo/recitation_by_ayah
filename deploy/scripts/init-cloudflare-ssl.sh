#!/bin/bash
# Set up Cloudflare origin certificate for nginx.
#
# Prerequisites:
#   - Cloudflare DNS A record for recite-ayah.quranlingo.app pointing to this server (proxied)
#   - Cloudflare SSL mode set to "Full (Strict)"
#   - A Cloudflare origin certificate covering *.quranlingo.app
#     (Cloudflare dashboard → SSL/TLS → Origin Server → Create/download certificate)
#
# Usage:
#   ./deploy/scripts/init-cloudflare-ssl.sh

set -euo pipefail

SSL_DIR="/app/deploy/ssl"
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

mkdir -p "$SSL_DIR"

echo "==> Paste your Cloudflare origin CERTIFICATE below."
echo "    (starts with -----BEGIN CERTIFICATE-----, ends with -----END CERTIFICATE-----)"
echo "    Press Enter then Ctrl+D when done:"
cat > "$SSL_DIR/cert.pem"

echo ""
echo "==> Paste your PRIVATE KEY below."
echo "    (starts with -----BEGIN PRIVATE KEY-----, ends with -----END PRIVATE KEY-----)"
echo "    Press Enter then Ctrl+D when done:"
cat > "$SSL_DIR/key.pem"

chmod 600 "$SSL_DIR/key.pem"
chmod 644 "$SSL_DIR/cert.pem"

echo ""
echo "==> Restarting nginx with Cloudflare certificate..."
docker compose up -d nginx

echo ""
echo "Done. Test with:"
echo "  curl https://recite-ayah.quranlingo.app/health"
