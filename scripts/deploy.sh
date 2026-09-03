#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — despliega/actualiza esta instancia en el VPS a un tag concreto.
#
# La "version publicada" = el tag que queda checked out en el clon del VPS.
# Este script hace fetch, checkout de ese ref, genera admin/version.json (lo
# que muestra el panel), valida y recarga nginx, levanta el contenedor si
# compose.yaml cambio, y corre smoke tests contra el dominio publico.
#
# Uso (desde cualquier sitio, en el VPS):
#   ./scripts/deploy.sh              # ultimo tag vX.Y.Z
#   ./scripts/deploy.sh v0.1.0       # un tag concreto (rollback tambien)
#   DOMAIN=comments.ewcam.co ./scripts/deploy.sh
#
# Requisitos previos (una sola vez):
#   - clon del repo en el VPS con remote 'origin'
#   - .env relleno (SECRET, ADMIN_PASSWD, SITE=estrellaswebcam)
#   - /etc/nginx/remark-admin.htpasswd con  admin:<ADMIN_PASSWD>
#   - vhost copiado a /etc/nginx/ con las 3 location del panel (ver README)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${DOMAIN:-comments.ewcam.co}"
HTPASSWD="${HTPASSWD:-/etc/nginx/remark-admin.htpasswd}"
cd "$REPO_DIR"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f .env ] || die "no hay .env en $REPO_DIR"
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${ADMIN_PASSWD:?ADMIN_PASSWD no esta en .env}"
: "${SITE:?SITE no esta en .env}"

if [ ! -f "$HTPASSWD" ]; then
  die "falta $HTPASSWD — crealo con:
  sudo htpasswd -bc $HTPASSWD admin \"\$ADMIN_PASSWD\"
  (la credencial DEBE ser admin:<ADMIN_PASSWD del .env>)"
fi

# --- 1. traer refs y elegir target -----------------------------------------
say "git fetch"
git fetch --tags --prune origin

TARGET="${1:-$(git describe --tags "$(git rev-list --tags --max-count=1)" 2>/dev/null || true)}"
[ -n "$TARGET" ] || die "no hay tags; pasa un ref explicito: ./scripts/deploy.sh <ref>"

PREV_REF="$(git rev-parse HEAD)"
say "checkout $TARGET  (antes: $(git describe --tags --always "$PREV_REF"))"
git checkout --quiet --detach "$TARGET"

# --- 2. sello de version para el panel ------------------------------------
VERSTR="$(git describe --tags --always)"
COMMIT="$(git rev-parse --short HEAD)"
cat > admin/version.json <<EOF
{"version":"$VERSTR","commit":"$COMMIT","date":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
say "admin/version.json -> $VERSTR ($COMMIT)"

# --- 3. contenedor: solo si compose.yaml cambio -------------------------
if ! git diff --quiet "$PREV_REF" HEAD -- compose.yaml; then
  say "compose.yaml cambio -> docker compose pull && up -d"
  docker compose pull
  docker compose up -d
else
  echo "compose.yaml sin cambios; no se toca el contenedor"
fi

# --- 4. nginx -----------------------------------------------------------
say "nginx -t && reload"
sudo nginx -t
sudo systemctl reload nginx

# --- 5. smoke tests ---------------------------------------------------
say "smoke tests contra https://$DOMAIN"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

c1="$(code "https://$DOMAIN/admin/")"
[ "$c1" = "401" ] || die "GET /admin/ sin credencial devolvio $c1 (esperado 401)"
echo "  /admin/ sin credencial: 401 OK"

c2="$(code -u "admin:$ADMIN_PASSWD" "https://$DOMAIN/admin/")"
[ "$c2" = "200" ] || die "GET /admin/ con credencial devolvio $c2 (esperado 200)"
echo "  /admin/ con credencial: 200 OK"

if curl -s -u "admin:$ADMIN_PASSWD" "https://$DOMAIN/admin/" | grep -q "Panel de moderación"; then
  echo "  index.html servido OK"
else
  die "el HTML de /admin/ no contiene 'Panel de moderación'"
fi

c3="$(code -u "admin:$ADMIN_PASSWD" "https://$DOMAIN/api/v1/admin/export?site=$SITE&mode=stream")"
[ "$c3" = "200" ] || die "export con credencial devolvio $c3 (esperado 200)"
echo "  /api/v1/admin/export con credencial: 200 OK"

n="$(curl -s "https://$DOMAIN/api/v1/last/5?site=$SITE" | head -c 1)"
[ "$n" = "[" ] || die "last/5 no devolvio un array JSON (empieza con '$n')"
echo "  /api/v1/last?site=$SITE: array JSON OK"

say "desplegado: $VERSTR   site=$SITE   dominio=$DOMAIN"
echo "rollback: ./scripts/deploy.sh <tag-anterior>"
