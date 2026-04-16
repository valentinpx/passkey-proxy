#!/bin/sh
set -e

# ── passkey-proxy bootstrap ─────────────────────────────────────────
# Self-contained setup: can be curl'd and run from anywhere.
#   curl -fsSL https://raw.githubusercontent.com/valentinpx/passkey-proxy/main/setup.sh -o setup.sh && sh setup.sh
# ────────────────────────────────────────────────────────────────────

REPO_URL="https://github.com/valentinpx/passkey-proxy.git"

# ── helpers ──────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$1"; exit 1; }

prompt() {
    # prompt VAR "question" [default]
    _var=$1 _msg=$2 _default=$3
    if [ -n "$_default" ]; then
        printf '%s [%s]: ' "$_msg" "$_default"
    else
        printf '%s: ' "$_msg"
    fi
    read -r _val
    _val="${_val:-$_default}"
    [ -z "$_val" ] && err "$_msg cannot be empty."
    eval "$_var=\"\$_val\""
}

# ── 1. check prerequisites ──────────────────────────────────────────

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Detect OS and package manager
detect_installer() {
    _uname=$(uname -s)
    case "$_uname" in
        Darwin)
            if has_cmd brew; then
                PKG_INSTALL="brew install"
                SUDO=""
            else
                PKG_INSTALL=""
            fi
            ;;
        Linux)
            if has_cmd apt-get; then
                PKG_INSTALL="apt-get install -y"
                PKG_UPDATE="apt-get update"
            elif has_cmd dnf; then
                PKG_INSTALL="dnf install -y"
            elif has_cmd yum; then
                PKG_INSTALL="yum install -y"
            elif has_cmd pacman; then
                PKG_INSTALL="pacman -S --noconfirm"
            elif has_cmd apk; then
                PKG_INSTALL="apk add"
            else
                PKG_INSTALL=""
            fi
            if [ "$(id -u)" -eq 0 ]; then
                SUDO=""
            elif has_cmd sudo; then
                SUDO="sudo"
            else
                SUDO=""
            fi
            ;;
        *)
            PKG_INSTALL=""
            ;;
    esac
}

confirm_install() {
    # confirm_install "thing" "command that will run"
    printf '%s is missing. Install now with: %s ? [Y/n]: ' "$1" "$2"
    read -r _ans
    case "$_ans" in
        [nN]*) return 1 ;;
        *)     return 0 ;;
    esac
}

install_pkg() {
    # install_pkg <pkg-name>
    [ -z "$PKG_INSTALL" ] && err "No supported package manager found. Install '$1' manually."
    _cmd="$SUDO $PKG_INSTALL $1"
    confirm_install "$1" "$_cmd" || err "'$1' is required. Aborting."
    if [ -n "${PKG_UPDATE:-}" ]; then
        # shellcheck disable=SC2086
        $SUDO $PKG_UPDATE
    fi
    # shellcheck disable=SC2086
    $SUDO $PKG_INSTALL "$1"
}

install_docker() {
    _uname=$(uname -s)
    if [ "$_uname" = "Darwin" ]; then
        err "Docker Desktop for Mac is required. Download from https://www.docker.com/products/docker-desktop/"
    fi
    _cmd="curl -fsSL https://get.docker.com | $SUDO sh"
    confirm_install "Docker" "$_cmd" || err "Docker is required. Aborting."
    curl -fsSL https://get.docker.com | $SUDO sh
    # Add current user to docker group (non-root, non-immediate effect)
    if [ -n "$SUDO" ] && has_cmd usermod; then
        $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || true
        warn "You were added to the 'docker' group. Log out and back in for it to take effect,"
        warn "or run the rest of this script with: sudo sh setup.sh"
    fi
}

info "Checking prerequisites..."
detect_installer

for _dep in git openssl curl; do
    if ! has_cmd "$_dep"; then
        warn "'$_dep' not found."
        install_pkg "$_dep"
    fi
done

if ! has_cmd docker; then
    warn "'docker' not found."
    install_docker
    has_cmd docker || err "Docker install completed but 'docker' still not on PATH."
fi

# docker compose (v2 plugin or standalone)
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif has_cmd docker-compose; then
    DC="docker-compose"
else
    warn "'docker compose' plugin not found — the get.docker.com installer normally bundles it."
    err "Install Docker Compose v2 manually and re-run."
fi
ok "All prerequisites found ($DC)"

# ── 2. ensure we're inside the repo ─────────────────────────────────

if [ -f ".env.example" ] && [ -f "docker-compose.yml" ] && [ -f "Caddyfile" ]; then
    info "Already inside passkey-proxy directory — skipping clone."
else
    TARGET="passkey-proxy"
    if [ -d "$TARGET" ]; then
        info "Directory '$TARGET' already exists — entering it."
    else
        info "Cloning repository..."
        git clone "$REPO_URL" "$TARGET"
    fi
    cd "$TARGET"
fi

# ── 3. handle existing .env ─────────────────────────────────────────

if [ -f ".env" ]; then
    warn ".env already exists."
    printf 'Overwrite and reconfigure? [y/N]: '
    read -r _ow
    case "$_ow" in
        [yY]*) info "Reconfiguring..." ;;
        *)     info "Keeping existing .env — skipping to service start."
               SKIP_CONFIG=1 ;;
    esac
fi

# ── 4. interactive configuration ────────────────────────────────────

if [ "${SKIP_CONFIG:-0}" != "1" ]; then

    echo ""
    info "Configure your passkey-proxy instance"
    echo "──────────────────────────────────────────────────"

    prompt APP_DOMAIN   "Domain for your protected app (e.g. app.example.com)"
    prompt AUTH_DOMAIN  "Domain for Pocket ID auth" "auth.${APP_DOMAIN}"
    prompt UPSTREAM_PORT "Port of the host service to protect" "3456"
    prompt ACME_EMAIL   "Email for Let's Encrypt notifications"

    # ── 5. derive BASE_DOMAIN ────────────────────────────────────────

    # Default: longest common suffix (by label) of APP_DOMAIN and AUTH_DOMAIN
    _a="$APP_DOMAIN"
    _b="$AUTH_DOMAIN"
    _default_base=""
    while [ -n "$_a" ] && [ -n "$_b" ]; do
        _la="${_a##*.}"
        _lb="${_b##*.}"
        [ "$_la" = "$_lb" ] || break
        _default_base="${_la}${_default_base:+.}${_default_base}"
        case "$_a" in *.*) _a="${_a%.*}" ;; *) _a="" ;; esac
        case "$_b" in *.*) _b="${_b%.*}" ;; *) _b="" ;; esac
    done
    case "$_default_base" in
        *.*) : ;;
        *)   _default_base="$APP_DOMAIN" ;;
    esac

    prompt BASE_DOMAIN "Base domain for cookie sharing (must be a parent of both APP_DOMAIN and AUTH_DOMAIN)" "$_default_base"
    info "Base domain (for cookies): $BASE_DOMAIN"

    # ── 6. generate secrets ──────────────────────────────────────────

    COOKIE_SECRET=$(openssl rand -base64 32 | tr -- '+/' '-_')
    POCKET_ID_ENCRYPTION_KEY=$(openssl rand -base64 32)

    # ── 7. write .env ────────────────────────────────────────────────

    cat > .env <<EOF
# === DOMAINS ===
APP_DOMAIN=${APP_DOMAIN}
AUTH_DOMAIN=${AUTH_DOMAIN}
BASE_DOMAIN=${BASE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

# === UPSTREAM SERVICE ===
UPSTREAM_PORT=${UPSTREAM_PORT}

# === OIDC (filled in during setup) ===
OIDC_CLIENT_ID=
OIDC_CLIENT_SECRET=

# === SECRETS (auto-generated) ===
COOKIE_SECRET=${COOKIE_SECRET}
POCKET_ID_ENCRYPTION_KEY=${POCKET_ID_ENCRYPTION_KEY}
EOF

    ok ".env written with generated secrets"
fi

# ── 8. start Caddy + Pocket ID ──────────────────────────────────────

echo ""
info "Starting Caddy and Pocket ID..."
$DC up -d caddy pocket-id

# ── 9. wait for Pocket ID to be healthy ─────────────────────────────

info "Waiting for Pocket ID to be ready..."
_tries=0
_max=30
while [ "$_tries" -lt "$_max" ]; do
    _state=$($DC ps pocket-id --format '{{.State}}' 2>/dev/null || echo "")
    case "$_state" in
        running*|Running*) break ;;
    esac
    _tries=$(( _tries + 1 ))
    sleep 2
done
if [ "$_tries" -ge "$_max" ]; then
    warn "Pocket ID didn't start within 60s. Check logs: $DC logs pocket-id"
else
    ok "Pocket ID is running"
fi

# ── 10. load domains from .env if we skipped config ─────────────────

if [ "${SKIP_CONFIG:-0}" = "1" ]; then
    # shellcheck disable=SC1091
    . ./.env
fi

# ── 11. guide user through OIDC setup ───────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Pocket ID is up! Complete the OIDC setup:"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  1. Open https://${AUTH_DOMAIN}/setup"
echo "  2. Create your admin account and register a passkey"
echo "  3. Go to OIDC Clients -> New Client"
echo "     - Name: anything (e.g. \"app\")"
echo "     - Callback URL: https://${APP_DOMAIN}/oauth2/callback"
echo "  4. Grant yourself access to the client:"
echo "     - Easiest: toggle \"Restricted\" OFF on the client, OR"
echo "     - Create a group, add your user, assign it under \"Allowed user groups\""
echo "     (Skip this and login will fail with \"You're not allowed to access this service.\")"
echo "  5. Copy the Client ID and Client Secret"
echo ""
echo "══════════════════════════════════════════════════════"
echo ""

prompt OIDC_CLIENT_ID     "Paste the OIDC Client ID"
prompt OIDC_CLIENT_SECRET  "Paste the OIDC Client Secret"

# ── 12. update .env with OIDC credentials ───────────────────────────

# Portable sed in-place
if sed --version >/dev/null 2>&1; then
    sed -i "s|^OIDC_CLIENT_ID=.*|OIDC_CLIENT_ID=${OIDC_CLIENT_ID}|" .env
    sed -i "s|^OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}|" .env
else
    sed -i '' "s|^OIDC_CLIENT_ID=.*|OIDC_CLIENT_ID=${OIDC_CLIENT_ID}|" .env
    sed -i '' "s|^OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}|" .env
fi

ok "OIDC credentials saved to .env"

# ── 13. start all services ──────────────────────────────────────────

echo ""
info "Starting all services..."
$DC up -d

ok "All services are running!"
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Visit: https://${APP_DOMAIN}"
echo "  Auth:  https://${AUTH_DOMAIN}"
echo "══════════════════════════════════════════════════════"
echo ""
