#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# EarnBox Installer — single-file, downloadable.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/Raspberry-PI-Earning/main/install.sh -o install.sh
#   chmod +x install.sh
#   sudo ./install.sh
#
# This file is fully self-contained: no other scripts are required to run
# detection and decide how to install. Everything it finds is written to
# earnbox-system.env in the current directory.
#
# What it does:
#   1. Detects RAM, CPU architecture, Raspberry Pi vs generic Linux, OS,
#      and any attached external storage (HDD/SSD/USB drive).
#   2. Decides which install tier fits the hardware:
#        dockerless    < 1.5GB RAM   (e.g. Pi 3 1GB)
#        docker-light  1.5GB - 3.5GB (e.g. Pi 2GB boards)
#        docker-full   >= 3.5GB      (4GB+ boards, most generic Linux hosts)
#   3. Writes everything it found to earnbox-system.env so this script (on
#      a re-run) and the running app can read it instead of re-detecting.
#   4. Hands off to the matching tier's install routine.
#
# Tier install routines are stubs for now (Phase 2/3/4 not built yet) —
# they're functions in THIS file, not separate scripts, by design: a tier
# installer is free to download whatever extra files it actually needs
# (docker-compose.yml, dashboard code, etc.) once it exists, instead of
# every user having to clone a full repo just to run detection.
#
# Flags:
#   --dry-run             Only detect and print the report, install nothing.
#   --force-tier=TIER     Override auto-detected tier (dockerless |
#                         docker-light | docker-full).
#   -h, --help            Show this help.
# ---------------------------------------------------------------------------
set -euo pipefail

DRY_RUN="false"
FORCE_TIER=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN="true"
            ;;
        --force-tier=*)
            FORCE_TIER="${arg#--force-tier=}"
            ;;
        -h|--help)
            sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# ===========================================================================
# DETECTION
# ===========================================================================

# --- RAM ---------------------------------------------------------------
detect_ram() {
    local kb
    kb=$(grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -z "${kb:-}" ]; then
        RAM_TOTAL_MB=0
    else
        RAM_TOTAL_MB=$(( kb / 1024 ))
    fi
}

# --- CPU architecture ----------------------------------------------------
detect_arch() {
    CPU_ARCH="$(uname -m)"
    case "$CPU_ARCH" in
        aarch64|arm64)
            PKG_ARCH="arm64"
            ;;
        armv7l|armv6l|armhf)
            PKG_ARCH="armhf"
            ;;
        x86_64|amd64)
            PKG_ARCH="amd64"
            ;;
        *)
            PKG_ARCH="unknown"
            ;;
    esac
}

# --- Raspberry Pi vs generic Linux board ---------------------------------
detect_raspberry_pi() {
    IS_RASPBERRY_PI="false"
    PI_MODEL=""

    if [ -r /proc/device-tree/model ]; then
        local model
        model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
        if [[ "$model" == *"Raspberry Pi"* ]]; then
            IS_RASPBERRY_PI="true"
            PI_MODEL="$model"
        fi
    fi

    # Fallback: some Pi images don't expose device-tree the same way
    if [ "$IS_RASPBERRY_PI" = "false" ] && [ -r /proc/cpuinfo ]; then
        if grep -qi "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
            IS_RASPBERRY_PI="true"
            PI_MODEL=$(grep -i "^Model" /proc/cpuinfo | head -n1 | cut -d: -f2 | sed 's/^ *//')
        fi
    fi

    if [ "$IS_RASPBERRY_PI" = "true" ]; then
        PLATFORM_FAMILY="raspberry-pi"
    else
        PLATFORM_FAMILY="linux"
    fi
}

# --- OS release info -------------------------------------------------------
detect_os() {
    OS_ID="unknown"
    OS_VERSION_CODENAME="unknown"
    OS_PRETTY_NAME="Unknown OS"

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_CODENAME="${VERSION_CODENAME:-unknown}"
        OS_PRETTY_NAME="${PRETTY_NAME:-Unknown OS}"
    fi
}

# --- External storage (attached HDD/SSD/USB drive) ------------------------
# Heuristic: find mounted partitions that are NOT on the same physical disk
# as the root filesystem, excluding boot/swap/virtual mounts, and require
# a meaningful minimum size so small bind mounts / container overlays don't
# get mistaken for a real attached drive. If several qualify, pick the
# largest.
detect_storage() {
    HAS_EXTERNAL_STORAGE="false"
    EXTERNAL_STORAGE_PATH=""
    EXTERNAL_STORAGE_SIZE=""

    if ! command -v lsblk >/dev/null 2>&1; then
        return 0
    fi

    local root_src root_pk
    root_src=$(findmnt -no SOURCE / 2>/dev/null)
    root_pk=$(lsblk -no PKNAME "$root_src" 2>/dev/null)
    if [ -z "$root_pk" ]; then
        root_pk=$(basename "$root_src" 2>/dev/null | sed -E 's/p?[0-9]+$//')
    fi

    local best_path="" best_bytes=0
    # 5GB floor: comfortably above container/bind-mount noise, comfortably
    # below even a small USB drive.
    local min_useful_bytes=$((5 * 1024 * 1024 * 1024))

    while IFS= read -r line; do
        # lsblk -P emits quoted KEY="value" pairs safe to eval
        eval "$line"
        # Variables now available: NAME PKNAME TYPE MOUNTPOINT SIZE FSTYPE

        [ "$TYPE" != "part" ] && [ "$TYPE" != "disk" ] && continue
        [ -z "$MOUNTPOINT" ] && continue
        case "$MOUNTPOINT" in
            /|/boot|/boot/*|/proc*|/sys*|/dev*|/run*|"[SWAP]") continue ;;
        esac
        [ "$PKNAME" = "$root_pk" ] && continue

        case "$FSTYPE" in
            tmpfs|overlay|overlay2|squashfs|devtmpfs|proc|sysfs|cgroup*|"") continue ;;
        esac

        local bytes
        bytes=$(df -B1 --output=size "$MOUNTPOINT" 2>/dev/null | tail -n1 | tr -d ' ')
        [ -z "$bytes" ] && bytes=0
        [ "$bytes" -lt "$min_useful_bytes" ] 2>/dev/null && continue

        if [ "$bytes" -gt "$best_bytes" ] 2>/dev/null; then
            best_bytes="$bytes"
            best_path="$MOUNTPOINT"
        fi
    done < <(lsblk -P -o NAME,PKNAME,TYPE,MOUNTPOINT,SIZE,FSTYPE 2>/dev/null)

    if [ -n "$best_path" ]; then
        HAS_EXTERNAL_STORAGE="true"
        EXTERNAL_STORAGE_PATH="$best_path"
        EXTERNAL_STORAGE_SIZE=$(lsblk -no SIZE "$(findmnt -no SOURCE "$best_path" 2>/dev/null)" 2>/dev/null | head -n1)
    fi
}

# --- Decide install tier from RAM ------------------------------------------
decide_tier() {
    if [ "$RAM_TOTAL_MB" -lt 1500 ]; then
        INSTALL_TIER="dockerless"
    elif [ "$RAM_TOTAL_MB" -lt 3500 ]; then
        INSTALL_TIER="docker-light"
    else
        INSTALL_TIER="docker-full"
    fi
}

detect_all() {
    detect_ram
    detect_arch
    detect_raspberry_pi
    detect_os
    detect_storage
    decide_tier
}

print_report() {
    echo "======================================="
    echo "        EarnBox System Detection"
    echo "======================================="
    echo " Platform:        $PLATFORM_FAMILY"
    if [ "$IS_RASPBERRY_PI" = "true" ]; then
        echo " Board:           $PI_MODEL"
    fi
    echo " OS:               $OS_PRETTY_NAME"
    echo " CPU arch:         $CPU_ARCH  (package arch: $PKG_ARCH)"
    echo " RAM:              ${RAM_TOTAL_MB} MB"
    if [ "$HAS_EXTERNAL_STORAGE" = "true" ]; then
        echo " External storage: $EXTERNAL_STORAGE_PATH ($EXTERNAL_STORAGE_SIZE)"
    else
        echo " External storage: none detected (using SD card / root disk)"
    fi
    echo "---------------------------------------"
    echo " Selected install tier: $INSTALL_TIER"
    case "$INSTALL_TIER" in
        dockerless)
            echo "   -> Native services + systemd, no Docker daemon."
            echo "      Required for boards this low on RAM."
            ;;
        docker-light)
            echo "   -> Docker, but a trimmed stack (no Netdata/heavy extras)."
            ;;
        docker-full)
            echo "   -> Full Docker Compose stack, all monitoring included."
            ;;
    esac
    if [ "$PKG_ARCH" = "unknown" ]; then
        echo " WARNING: could not determine a known CPU architecture."
        echo "          Native binary downloads in later install steps may fail."
    fi
    echo "======================================="
}

# ===========================================================================
# TIER INSTALL ROUTINES (stubs — Phase 2/3/4)
# ===========================================================================

install_dockerless() {
    echo ""
    echo "[dockerless] Not built yet (Phase 2)."
    echo "[dockerless] earnbox-system.env is ready for it to read once it exists."
}

install_docker_light() {
    echo ""
    echo "[docker-light] Not built yet (Phase 3)."
    echo "[docker-light] earnbox-system.env is ready for it to read once it exists."
}

install_docker_full() {
    echo ""
    echo "[docker-full] Not built yet (Phase 4)."
    echo "[docker-full] Will extend the existing docker-compose.yml stack with"
    echo "[docker-full] Repocket support and the new forecast logic."
    echo "[docker-full] earnbox-system.env is ready for it to read once it exists."
}

# ===========================================================================
# MAIN
# ===========================================================================

detect_all

if [ -n "$FORCE_TIER" ]; then
    case "$FORCE_TIER" in
        dockerless|docker-light|docker-full)
            echo "Overriding auto-detected tier ($INSTALL_TIER) with --force-tier=$FORCE_TIER"
            INSTALL_TIER="$FORCE_TIER"
            ;;
        *)
            echo "Invalid --force-tier value: $FORCE_TIER" >&2
            echo "Must be one of: dockerless, docker-light, docker-full" >&2
            exit 1
            ;;
    esac
fi

print_report

DATA_ROOT="$(pwd)/data"
if [ "$HAS_EXTERNAL_STORAGE" = "true" ]; then
    DATA_ROOT="$EXTERNAL_STORAGE_PATH/earnbox-data"
fi

CONFIG_FILE="$(pwd)/earnbox-system.env"
cat > "$CONFIG_FILE" <<EOF
# Auto-generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Do not edit by hand — re-run install.sh to refresh.
PLATFORM_FAMILY="$PLATFORM_FAMILY"
IS_RASPBERRY_PI="$IS_RASPBERRY_PI"
PI_MODEL="$PI_MODEL"
OS_ID="$OS_ID"
OS_VERSION_CODENAME="$OS_VERSION_CODENAME"
OS_PRETTY_NAME="$OS_PRETTY_NAME"
CPU_ARCH="$CPU_ARCH"
PKG_ARCH="$PKG_ARCH"
RAM_TOTAL_MB="$RAM_TOTAL_MB"
HAS_EXTERNAL_STORAGE="$HAS_EXTERNAL_STORAGE"
EXTERNAL_STORAGE_PATH="$EXTERNAL_STORAGE_PATH"
EXTERNAL_STORAGE_SIZE="$EXTERNAL_STORAGE_SIZE"
DATA_ROOT="$DATA_ROOT"
INSTALL_TIER="$INSTALL_TIER"
EOF

echo "Saved detection results to $CONFIG_FILE"
echo "Data root for this install will be: $DATA_ROOT"

if [ "$HAS_EXTERNAL_STORAGE" = "true" ]; then
    echo ""
    echo "NOTE: an external drive was found and will be used for app data and"
    echo "      logs (keeps writes off the SD card). Once the storage-aware"
    echo "      install phase is built, this is also where extra disk-backed"
    echo "      earning services could be offered, since Honeygain/Pawns/"
    echo "      TraffMonetizer/Repocket only use bandwidth, not disk space."
fi

if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo "--dry-run set: stopping here, nothing was installed."
    exit 0
fi

mkdir -p "$DATA_ROOT"

echo ""
echo "Handing off to the $INSTALL_TIER installer..."
case "$INSTALL_TIER" in
    dockerless)
        install_dockerless
        ;;
    docker-light)
        install_docker_light
        ;;
    docker-full)
        install_docker_full
        ;;
esac