#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# EarnBox — Dockerless tier installer
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/Raspberry-PI-Earning/main/install-dockerless.sh -o install-dockerless.sh
#   chmod +x install-dockerless.sh
#   sudo ./install-dockerless.sh
#
# Run this AFTER install.sh has written earnbox-system.env in the same
# directory (install.sh hands off to this script automatically when it
# picks the "dockerless" tier — this file also works standalone for
# testing/re-runs).
#
# WHY THIS ISN'T 100% "NO CONTAINERS"
# ------------------------------------------------------------------------
# Of the four services, only Pawns.app ships an actual native Linux/ARM
# binary. Honeygain, TraffMonetizer, and Repocket are ONLY distributed as
# Docker images — there is no vendor-provided native binary for any of
# them, on any architecture. Faking one isn't possible, so this tier:
#
#   - Runs Pawns as a true native process (real binary, real systemd unit,
#     no container of any kind).
#   - Runs Honeygain / TraffMonetizer / Repocket via Podman, which has no
#     persistent background daemon (unlike Docker's dockerd/containerd),
#     so the baseline memory tax is meaningfully lower — appropriate for
#     a 1GB board. The container images themselves are unchanged; Podman
#     runs standard OCI/Docker images.
#
# WHAT THIS SCRIPT DOES
# ------------------------------------------------------------------------
#   1. Installs Podman + rootless container dependencies via apt.
#   2. Points Podman's image storage at DATA_ROOT (the external HDD if
#      install.sh found one, otherwise the SD card) so big image layers
#      don't have to live on a tiny boot partition.
#   3. Creates a dedicated systemd journal namespace ("earnbox") that is
#      memory-only (volatile) and size-capped, so the constantly-running
#      income services never wear out the SD card with log writes. The
#      rest of the system's normal journal is untouched.
#   4. Downloads the correct native Pawns CLI binary for this CPU and
#      sets it up as a systemd service.
#   5. Sets up Honeygain / TraffMonetizer / Repocket as Podman-backed
#      systemd services (start/stop/restart all work the normal
#      `systemctl` way — Podman is just the thing actually running them).
#
# Flags:
#   --dry-run    Print what would happen; skip apt/podman/systemctl/
#                network calls and any writes outside this directory.
#   -h, --help   Show this help.
# ---------------------------------------------------------------------------
set -euo pipefail

DRY_RUN="false"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
        -h|--help)
            sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

if [ "${INSTALL_TIER:-}" != "dockerless" ]; then
    echo "WARNING: earnbox-system.env says INSTALL_TIER=${INSTALL_TIER:-unset}, not 'dockerless'."
    echo "         Continuing anyway since you ran this script directly."
fi

if [ "$DRY_RUN" != "true" ] && [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root (apt, systemd units, /etc/containers config)." >&2
    echo "Re-run with sudo, or add --dry-run to preview without changes." >&2
    exit 1
fi

INSTALL_DIR="${DATA_ROOT:-$SCRIPT_DIR/data}"
BIN_DIR="$INSTALL_DIR/bin"
CRED_FILE="$INSTALL_DIR/credentials.env"
PODMAN_STORAGE_DIR="$INSTALL_DIR/podman-storage"

run() {
    # Wrapper so --dry-run can print instead of execute, in one place.
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

echo "======================================="
echo " EarnBox Dockerless Install"
echo "======================================="
echo " Install dir (binaries, podman storage, logs config): $INSTALL_DIR"
echo " CPU arch: $CPU_ARCH  (package arch: $PKG_ARCH)"
echo "======================================="

mkdir -p "$BIN_DIR"

# ===========================================================================
# 1. Packages
# ===========================================================================
echo ""
echo "[1/5] Installing Podman + rootless dependencies..."
run apt-get update -y
run apt-get install -y podman slirp4netns uidmap fuse-overlayfs curl ca-certificates

# ===========================================================================
# 2. Podman storage location (HDD if available, else SD card)
# ===========================================================================
echo ""
echo "[2/5] Pointing Podman's image storage at $PODMAN_STORAGE_DIR ..."
mkdir -p "$PODMAN_STORAGE_DIR"
CONTAINERS_CONF_DIR="/etc/containers"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would write storage.conf pointing graphroot to $PODMAN_STORAGE_DIR"
else
    mkdir -p "$CONTAINERS_CONF_DIR"
    cat > "$CONTAINERS_CONF_DIR/storage.conf" <<EOF
[storage]
driver = "overlay"
graphroot = "$PODMAN_STORAGE_DIR"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
fi

# ===========================================================================
# 3. SD-card-friendly logging: dedicated volatile journal namespace
# ===========================================================================
echo ""
echo "[3/5] Setting up a memory-only log namespace for income services..."
echo "      (keeps constant service logging off the SD card; the rest of"
echo "       the system's journal is unaffected)"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would write /etc/systemd/journald@earnbox.conf (Storage=volatile)"
else
    mkdir -p /etc/systemd
    cat > /etc/systemd/journald@earnbox.conf <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=15M
RuntimeMaxFileSize=5M
EOF
fi

# ===========================================================================
# 4. Credentials
# ===========================================================================
echo ""
echo "[4/5] Service credentials"

if [ -f "$CRED_FILE" ]; then
    echo "      Found existing credentials at $CRED_FILE — reusing values already set."
    # shellcheck disable=SC1090
    source "$CRED_FILE"
fi

prompt_if_unset() {
    # prompt_if_unset VAR_NAME "Prompt text" [secret]
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
REPOCKET_EMAIL="$REPOCKET_EMAIL"
REPOCKET_API_KEY="$REPOCKET_API_KEY"
EOF
    chmod 600 "$CRED_FILE"
    echo "      Saved to $CRED_FILE (chmod 600)."
fi

# Note on secrecy: these CLIs take credentials as command-line arguments
# (that's how the vendors built them), so they will be briefly visible to
# anyone running `ps aux` on the box while the process starts. This is a
# limitation of the upstream tools, not something this installer can fully
# hide — flagging it here rather than implying otherwise.

# ===========================================================================
# 5a. Pawns — native binary
# ===========================================================================
echo ""
echo "[5/5] Installing services..."
echo "  -- Pawns.app (native) --"

case "$CPU_ARCH" in
    armv7l)  PAWNS_ARCH="linux_armv7l" ;;
    armv6l)  PAWNS_ARCH="linux_armv6l" ;;
    armv5l)  PAWNS_ARCH="linux_armv5l" ;;
    x86_64)  PAWNS_ARCH="linux_x86_64" ;;
    aarch64)
        # Pawns has no aarch64 build. Raspberry Pi 3/4 in 64-bit mode can
        # still execute 32-bit ARM binaries (AArch32 compat in EL0), so we
        # fall back to the armv7l build and verify it actually runs below.
        PAWNS_ARCH="linux_armv7l"
        echo "    NOTE: no native aarch64 Pawns build exists; trying the"
        echo "          armv7l (32-bit) build, which usually still runs on"
        echo "          64-bit Raspberry Pi OS. Will verify before enabling."
        ;;
    *)
        echo "    WARNING: unrecognized CPU_ARCH '$CPU_ARCH' — skipping Pawns."
        PAWNS_ARCH=""
        ;;
esac

if [ -n "$PAWNS_ARCH" ]; then
    PAWNS_URL="https://pawns-app.s3.eu-central-1.amazonaws.com/cli/latest/${PAWNS_ARCH}/pawns-cli"
    PAWNS_BIN="$BIN_DIR/pawns-cli"

    echo "    Downloading $PAWNS_URL"
    run curl -fsSL "$PAWNS_URL" -o "$PAWNS_BIN"
    run chmod +x "$PAWNS_BIN"

    PAWNS_OK="true"
    if [ "$DRY_RUN" != "true" ]; then
        # Smoke-test: a binary built for the wrong architecture fails to
        # exec at all (not just exits with an error code).
        if ! "$PAWNS_BIN" --help >/tmp/earnbox-pawns-test.log 2>&1; then
            if grep -qiE "cannot execute|exec format error" /tmp/earnbox-pawns-test.log; then
                PAWNS_OK="false"
                echo "    ERROR: downloaded Pawns binary will not execute on this CPU."
                echo "           Skipping Pawns — see /tmp/earnbox-pawns-test.log"
            fi
        fi
    fi

    if [ "$PAWNS_OK" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [dry-run] would write /etc/systemd/system/earnbox-pawns.service"
        else
            cat > /etc/systemd/system/earnbox-pawns.service <<EOF
[Unit]
Description=EarnBox - Pawns.app (native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CRED_FILE
ExecStart=/bin/sh -c '$PAWNS_BIN -email=\${PAWNS_EMAIL} -password=\${PAWNS_PASSWORD} -device-name=\${PAWNS_DEVICE} -device-id=\${PAWNS_DEVICE} -accept-tos'
Restart=on-failure
RestartSec=10
LogNamespace=earnbox

[Install]
WantedBy=multi-user.target
EOF
        fi
        run systemctl daemon-reload
        run systemctl enable --now earnbox-pawns.service
        echo "    Pawns installed as systemd service: earnbox-pawns.service"
    fi
fi

# ===========================================================================
# 5b. Podman-backed services: Honeygain, TraffMonetizer, Repocket
# ===========================================================================
write_podman_service() {
    # write_podman_service NAME DESCRIPTION "podman run args..."
    local name="$1" desc="$2" podman_args="$3"
    local unit="/etc/systemd/system/earnbox-${name}.service"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] would write $unit"
        echo "  [dry-run] podman run --rm --replace --name $name $podman_args"
        return 0
    fi

    cat > "$unit" <<EOF
[Unit]
Description=EarnBox - $desc (podman)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CRED_FILE
ExecStartPre=-/usr/bin/podman rm -f $name
ExecStart=/usr/bin/podman run --rm --replace --name $name $podman_args
ExecStop=/usr/bin/podman stop -t 10 $name
Restart=on-failure
RestartSec=15
TimeoutStartSec=120
LogNamespace=earnbox

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "earnbox-${name}.service"
    echo "    $desc installed as systemd service: earnbox-${name}.service"
}

echo "  -- Honeygain (podman) --"
write_podman_service "honeygain" "Honeygain" \
    'docker.io/honeygain/honeygain:latest -tou-accept -email ${HONEYGAIN_EMAIL} -pass ${HONEYGAIN_PASSWORD} -device ${HONEYGAIN_DEVICE}'

echo "  -- TraffMonetizer (podman) --"
write_podman_service "traffmonetizer" "TraffMonetizer" \
    'docker.io/traffmonetizer/cli_v2:latest start accept --token ${TRAFFMONETIZER_TOKEN} --device-name ${TRAFFMONETIZER_DEVICE}'

echo "  -- Repocket (podman) --"
write_podman_service "repocket" "Repocket" \
    '-e RP_EMAIL=${REPOCKET_EMAIL} -e RP_API_KEY=${REPOCKET_API_KEY} docker.io/repocket/repocket:latest'

echo ""
echo "======================================="
echo " Dockerless install complete"
echo "======================================="
echo " Services:"
echo "   systemctl status earnbox-pawns"
echo "   systemctl status earnbox-honeygain"
echo "   systemctl status earnbox-traffmonetizer"
echo "   systemctl status earnbox-repocket"
echo ""
echo " Logs (memory-only, capped at 15MB total):"
echo "   journalctl --namespace=earnbox -f"
echo ""
echo " Monitoring dashboard + balance fetching is the next phase — not"
echo " part of this install step."
echo "======================================="
