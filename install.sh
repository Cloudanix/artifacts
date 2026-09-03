#!/usr/bin/env bash
# =============================================================================
# Cloudanix JIT Setup — One-Line Installer
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash
#
# Or with a specific setup type:
#   curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- aws-jit-db
#
# This script:
#   1. Checks prerequisites (jq, cloud CLI)
#   2. Downloads only the required files for the selected setup type
#   3. Runs the orchestrator
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
# Branch/ref to pull setup files from. Override for testing a feature branch:
#   CDX_REPO_REF=ecr-changes curl ... | bash -s -- aws-jit-db
# or point REPO_BASE at any raw base URL directly via CDX_REPO_BASE.
CDX_REPO_REF="${CDX_REPO_REF:-Divyansh-master-script}"
REPO_BASE="${CDX_REPO_BASE:-https://raw.githubusercontent.com/Cloudanix/artifacts/${CDX_REPO_REF}}"
INSTALL_DIR="${CDX_INSTALL_DIR:-$HOME/.cdx-jit}"

# Colors
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    R="\033[0m" B="\033[1m" C="\033[36m" G="\033[32m" Y="\033[33m" RD="\033[31m"
else
    R="" B="" C="" G="" Y="" RD=""
fi

echo -e "${B}"
echo "   ╔═══════════════════════════════════════════════╗"
echo "   ║   Cloudanix JIT Setup Installer v${VERSION}      ║"
echo "   ╚═══════════════════════════════════════════════╝"
echo -e "${R}"

# =============================================================================
# SETUP TYPE SELECTION
# =============================================================================

SETUP_TYPES=("aws-jit-db" "aws-jit-vm" "aws-jit-eks" "azure-jit-db" "azure-jit-k8s" "gcp-jit-db")
SETUP_LABELS=(
    "AWS JIT Database"
    "AWS JIT VM (SSH Proxy)"
    "AWS JIT EKS (Kubernetes)"
    "Azure JIT Database"
    "Azure JIT Kubernetes (AKS)"
    "GCP JIT Database"
)

SELECTED="${1:-}"

if [[ -z "$SELECTED" ]]; then
    echo -e "${B}Select JIT setup type:${R}"
    echo ""
    for i in "${!SETUP_TYPES[@]}"; do
        echo -e "  ${C}$((i + 1)))${R} ${SETUP_LABELS[$i]}"
    done
    echo ""
    read -rp "Select [1-${#SETUP_TYPES[@]}]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#SETUP_TYPES[@]}" ]]; then
        SELECTED="${SETUP_TYPES[$((choice - 1))]}"
    else
        echo -e "${RD}Invalid selection.${R}"; exit 1
    fi
fi

# Validate selection
VALID=false
for st in "${SETUP_TYPES[@]}"; do
    if [[ "$st" == "$SELECTED" ]]; then VALID=true; break; fi
done
if [[ "$VALID" == false ]]; then
    echo -e "${RD}Unknown setup type: $SELECTED${R}"
    echo "Valid options: ${SETUP_TYPES[*]}"
    exit 1
fi

echo ""
echo -e "${G}✓${R} Selected: ${B}$SELECTED${R}"

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================

echo ""
echo -e "${B}Checking prerequisites...${R}"

REQUIRED_TOOLS=("jq" "curl")
case "$SELECTED" in
    aws-*)  REQUIRED_TOOLS+=("aws" "docker") ;;
    azure-*) REQUIRED_TOOLS+=("az" "jq") ;;
    gcp-*)  REQUIRED_TOOLS+=("gcloud" "docker") ;;
esac

MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo -e "  ${G}✓${R} $tool"
    else
        echo -e "  ${RD}✗${R} $tool — ${Y}not found${R}"
        MISSING+=("$tool")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RD}Missing required tools: ${MISSING[*]}${R}"
    echo "Please install them and re-run."
    exit 1
fi

echo -e "  ${G}✓${R} All prerequisites met"

# =============================================================================
# DOWNLOAD FILES
# =============================================================================

echo ""
echo -e "${B}Downloading setup files to ${C}${INSTALL_DIR}/${SELECTED}${R}..."

TARGET_DIR="${INSTALL_DIR}/${SELECTED}"
mkdir -p "$TARGET_DIR/steps"

# Download shared library
mkdir -p "${INSTALL_DIR}/lib"
curl -fsSL "${REPO_BASE}/lib/common.sh" -o "${INSTALL_DIR}/lib/common.sh"
chmod +x "${INSTALL_DIR}/lib/common.sh"
echo -e "  ${G}✓${R} lib/common.sh"

# Download config and setup
curl -fsSL "${REPO_BASE}/${SELECTED}/config.sh" -o "${TARGET_DIR}/config.sh"
curl -fsSL "${REPO_BASE}/${SELECTED}/setup.sh" -o "${TARGET_DIR}/setup.sh"
chmod +x "${TARGET_DIR}/setup.sh"
echo -e "  ${G}✓${R} ${SELECTED}/config.sh"
echo -e "  ${G}✓${R} ${SELECTED}/setup.sh"

# Download cleanup script if present (optional)
mkdir -p "${TARGET_DIR}/cleanup"
if curl -fsSL "${REPO_BASE}/${SELECTED}/cleanup/cleanup.sh" -o "${TARGET_DIR}/cleanup/cleanup.sh" 2>/dev/null; then
    chmod +x "${TARGET_DIR}/cleanup/cleanup.sh"
    echo -e "  ${G}✓${R} ${SELECTED}/cleanup/cleanup.sh"
else
    rm -f "${TARGET_DIR}/cleanup/cleanup.sh" 2>/dev/null || true
fi

# Download step scripts by listing from a manifest
# We fetch the steps manifest (one filename per line)
STEPS_MANIFEST=$(curl -fsSL "${REPO_BASE}/${SELECTED}/steps/MANIFEST" 2>/dev/null || echo "")

if [[ -n "$STEPS_MANIFEST" ]]; then
    while IFS= read -r step_file; do
        [[ -z "$step_file" ]] && continue
        curl -fsSL "${REPO_BASE}/${SELECTED}/steps/${step_file}" -o "${TARGET_DIR}/steps/${step_file}"
        chmod +x "${TARGET_DIR}/steps/${step_file}"
        echo -e "  ${G}✓${R} steps/${step_file}"
    done <<< "$STEPS_MANIFEST"
else
    # Fallback: try known step patterns
    echo -e "  ${Y}!${R} No MANIFEST found — downloading step scripts individually..."
    for i in $(seq -w 1 15); do
        for script in $(curl -fsSL "${REPO_BASE}/${SELECTED}/steps/" 2>/dev/null | grep -oE "${i}[^\"]*\.sh" | head -5); do
            curl -fsSL "${REPO_BASE}/${SELECTED}/steps/${script}" -o "${TARGET_DIR}/steps/${script}" 2>/dev/null && \
                chmod +x "${TARGET_DIR}/steps/${script}" && \
                echo -e "  ${G}✓${R} steps/${script}" || true
        done
    done
fi

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${G}╔═══════════════════════════════════════════════╗${R}"
echo -e "${G}║  ✅ Installation complete!                     ║${R}"
echo -e "${G}╚═══════════════════════════════════════════════╝${R}"
echo ""
echo -e "  Files installed to: ${C}${TARGET_DIR}${R}"
echo ""
echo -e "  ${B}To run the setup:${R}"
echo -e "    cd ${TARGET_DIR} && ./setup.sh"
echo ""
echo -e "  ${B}To clean up later:${R}"
echo -e "    cd ${TARGET_DIR} && ./setup.sh --cleanup"
echo ""
echo -e "  ${B}To remove installer files:${R}"
echo -e "    rm -rf ${INSTALL_DIR}"
echo ""
