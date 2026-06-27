#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# EarnBox — Docker-light tier installer
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/Raspberry-PI-Earning/main/install-docker-light.sh -o install-docker-light.sh
#   chmod +x install-docker-light.sh
#   sudo ./install-docker-light.sh
#
# Run this AFTER install.sh has written earnbox-system.env in the same
# directory (install.sh hands off here automatically for 1.5-3.5GB boards).
#
# WHY THIS TIER IS DIFFERENT FROM DOCKERLESS
# ------------------------------------------------------------------------
# At 1.5GB+ RAM there's enough headroom that a real Docker daemon isn't
# the bottleneck anymore, so this tier just runs all four income services
# as ordinary containers — including Pawns, which the dockerless tier had
# to run as a native binary to avoid Docker's overhead entirely. No such
# workaround is needed here.
#
# WHAT THIS SCRIPT DOES
# ------------------------------------------------------------------------
#   1. Installs Docker Engine + Compose plugin.
#   2. Points Docker's image/container storage (data-root) at DATA_ROOT —
#      the external HDD if install.sh found one, SD card otherwise.
#   3. Caps each container's log size (json-file driver, max-size +
#      max-file) so none of these always-on services can slowly fill the
#      SD card with logs.
#   4. Collects credentials, writes docker-compose.yml + .env, brings the
#      stack up.
#
# Flags:
#   --dry-run    Print what would happen; skip apt/docker/network calls.
#   -h, --help   Show this help.
# ---------------------------------------------------------------------------
set -euo pipefail

DRY_RUN="false"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_ENV="$SCRIPT_DIR/earnbox-system.env"

if [ ! -f "$SYSTEM_ENV" ]; then
    echo "ERROR: $SYSTEM_ENV not found." >&2
    echo "Run install.sh first — it detects your hardware and writes this file." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$SYSTEM_ENV"

if [ "${INSTALL_TIER:-}" != "docker-light" ]; then
    echo "WARNING: earnbox-system.env says INSTALL_TIER=${INSTALL_TIER:-unset}, not 'docker-light'."
    echo "         Continuing anyway since you ran this script directly."
fi

if [ "$DRY_RUN" != "true" ] && [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root (apt, Docker, daemon.json)." >&2
    echo "Re-run with sudo, or add --dry-run to preview without changes." >&2
    exit 1
fi

INSTALL_DIR="${DATA_ROOT:-$SCRIPT_DIR/data}"
STACK_DIR="$SCRIPT_DIR"
DOCKER_DATA_ROOT="$INSTALL_DIR/docker"
CRED_FILE="$STACK_DIR/.env"

echo "======================================="
echo " EarnBox Docker-light Install"
echo "======================================="
echo " Install dir (Docker data-root):  $DOCKER_DATA_ROOT"
echo " Compose stack location:          $STACK_DIR"
echo " CPU arch: $CPU_ARCH  (package arch: $PKG_ARCH)"
echo "======================================="

mkdir -p "$INSTALL_DIR"

# ===========================================================================
# 1. Docker Engine + Compose plugin
# ===========================================================================
echo ""
echo "[1/4] Installing Docker Engine..."
if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] curl -fsSL https://get.docker.com | sh"
    echo "  [dry-run] apt-get install -y docker-compose-plugin"
else
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh
    else
        echo "  Docker already installed, skipping."
    fi
    if ! docker compose version >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y docker-compose-plugin
    fi
fi

# ===========================================================================
# 2. Docker data-root (HDD if available, else SD card)
# ===========================================================================
echo ""
echo "[2/4] Pointing Docker's storage at $DOCKER_DATA_ROOT ..."
mkdir -p "$DOCKER_DATA_ROOT"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would write /etc/docker/daemon.json with data-root=$DOCKER_DATA_ROOT"
    echo "  [dry-run] systemctl stop docker; rsync existing /var/lib/docker if any; systemctl start docker"
else
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "3"
  }
}
EOF
    systemctl stop docker 2>/dev/null || true
    if [ -d /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
        echo "  Migrating existing /var/lib/docker contents to $DOCKER_DATA_ROOT ..."
        rsync -aP /var/lib/docker/ "$DOCKER_DATA_ROOT/" 2>/dev/null || true
    fi
    systemctl start docker
fi

# The daemon.json log-opts above set a DEFAULT for every container, so even
# services we don't explicitly configure below still get capped logs. We
# also set it per-service in the compose file for clarity/overrides.

# ===========================================================================
# 3. Credentials
# ===========================================================================
echo ""
echo "[3/4] Service credentials"

if [ -f "$CRED_FILE" ]; then
    echo "      Found existing .env at $CRED_FILE — reusing values already set."
    # shellcheck disable=SC1090
    source "$CRED_FILE"
fi

prompt_if_unset() {
    local var_name="$1" prompt_text="$2" secret="${3:-}"
    local current_value="${!var_name:-}"
    if [ -n "$current_value" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = "true" ]; then
        printf -v "$var_name" '%s' "dry-run-placeholder"
        return 0
    fi
    local value=""
    if [ "$secret" = "secret" ]; then
        read -r -s -p "$prompt_text: " value
        echo
    else
        read -r -p "$prompt_text: " value
    fi
    printf -v "$var_name" '%s' "$value"
}

echo "  -- Honeygain --"
prompt_if_unset HONEYGAIN_EMAIL "Honeygain email"
prompt_if_unset HONEYGAIN_PASSWORD "Honeygain password" secret
prompt_if_unset HONEYGAIN_DEVICE "Honeygain device name (e.g. earnbox-pi)"

echo "  -- Pawns.app --"
prompt_if_unset PAWNS_EMAIL "Pawns email"
prompt_if_unset PAWNS_PASSWORD "Pawns password" secret
prompt_if_unset PAWNS_DEVICE "Pawns device name (e.g. earnbox-pi)"

echo "  -- TraffMonetizer --"
prompt_if_unset TRAFFMONETIZER_TOKEN "TraffMonetizer token" secret
prompt_if_unset TRAFFMONETIZER_DEVICE "TraffMonetizer device name (e.g. earnbox-pi)"

echo "  -- Repocket --"
prompt_if_unset REPOCKET_EMAIL "Repocket email"
prompt_if_unset REPOCKET_API_KEY "Repocket API key" secret

# TraffMonetizer's image isn't a unified multi-arch manifest — the tag
# itself has to match the CPU.
case "$PKG_ARCH" in
    arm64)  TRAFFMONETIZER_TAG="arm64v8" ;;
    armhf)  TRAFFMONETIZER_TAG="arm32v7" ;;
    amd64)  TRAFFMONETIZER_TAG="latest" ;;
    *)
        TRAFFMONETIZER_TAG="latest"
        echo "  WARNING: unrecognized PKG_ARCH '$PKG_ARCH' for TraffMonetizer — defaulting to 'latest' (amd64)."
        ;;
esac

if [ "$DRY_RUN" != "true" ]; then
    umask 177
    cat > "$CRED_FILE" <<EOF
HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL"
HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD"
HONEYGAIN_DEVICE="$HONEYGAIN_DEVICE"
PAWNS_EMAIL="$PAWNS_EMAIL"
PAWNS_PASSWORD="$PAWNS_PASSWORD"
PAWNS_DEVICE="$PAWNS_DEVICE"
TRAFFMONETIZER_TOKEN="$TRAFFMONETIZER_TOKEN"
TRAFFMONETIZER_DEVICE="$TRAFFMONETIZER_DEVICE"
TRAFFMONETIZER_TAG="$TRAFFMONETIZER_TAG"
REPOCKET_EMAIL="$REPOCKET_EMAIL"
REPOCKET_API_KEY="$REPOCKET_API_KEY"
EOF
    chmod 600 "$CRED_FILE"
    echo "      Saved to $CRED_FILE (chmod 600)."
fi

# ===========================================================================
# 4. Compose stack
# ===========================================================================
echo ""
echo "[4/4] Writing docker-compose.yml and starting the stack..."

COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would write $COMPOSE_FILE"
else
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  honeygain:
    image: docker.io/honeygain/honeygain:latest
    container_name: earnbox-honeygain
    restart: unless-stopped
    command: >
      -tou-accept
      -email ${HONEYGAIN_EMAIL}
      -pass ${HONEYGAIN_PASSWORD}
      -device ${HONEYGAIN_DEVICE}
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"
    networks:
      - earning_net

  pawns:
    image: docker.io/iproyal/pawns-cli:latest
    container_name: earnbox-pawns
    restart: unless-stopped
    command: >
      -email=${PAWNS_EMAIL}
      -password=${PAWNS_PASSWORD}
      -device-name=${PAWNS_DEVICE}
      -device-id=${PAWNS_DEVICE}
      -accept-tos
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"
    networks:
      - earning_net

  traffmonetizer:
    image: docker.io/traffmonetizer/cli_v2:${TRAFFMONETIZER_TAG}
    container_name: earnbox-traffmonetizer
    restart: unless-stopped
    command: >
      start accept
      --token ${TRAFFMONETIZER_TOKEN}
      --device-name ${TRAFFMONETIZER_DEVICE}
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"
    networks:
      - earning_net

  repocket:
    image: docker.io/repocket/repocket:latest
    container_name: earnbox-repocket
    restart: unless-stopped
    environment:
      - RP_EMAIL=${REPOCKET_EMAIL}
      - RP_API_KEY=${REPOCKET_API_KEY}
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"
    networks:
      - earning_net

networks:
  earning_net:
    driver: bridge
EOF
    echo "  Wrote $COMPOSE_FILE"
fi

if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] docker compose --env-file $CRED_FILE -f $COMPOSE_FILE pull"
    echo "  [dry-run] docker compose --env-file $CRED_FILE -f $COMPOSE_FILE up -d"
else
    docker compose --env-file "$CRED_FILE" -f "$COMPOSE_FILE" pull
    docker compose --env-file "$CRED_FILE" -f "$COMPOSE_FILE" up -d
fi

echo ""
echo "======================================="
echo " Docker-light install complete"
echo "======================================="
echo " Containers:"
echo "   docker ps"
echo "   docker logs -f earnbox-honeygain"
echo "   docker logs -f earnbox-pawns"
echo "   docker logs -f earnbox-traffmonetizer"
echo "   docker logs -f earnbox-repocket"
echo ""
echo " Each container's logs are capped at ~15MB (5MB x 3 files)."
echo ""
echo " Monitoring dashboard + balance fetching is the next phase — not"
echo " part of this install step."
echo "======================================="
