#!/usr/bin/env bash
set -euo pipefail

# Defaults
BIN_NAME="cyclonedx"
REPO_OWNER="CycloneDX"
REPO_NAME="cyclonedx-cli"
USE_DOCKER=true

# Fallback behavior
FALLBACK_DL=true       # Fallback to downloading remote binary for comparison if checksum missing
FALLBACK_VER=false     # Fallback to simple version string match (least secure)

function usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Verifies the local cyclonedx binary against the latest GitHub release.

Options:
  --bin <path>          Path to local binary (default: cyclonedx)
  --no-docker           Skip Docker image version check
  --strict              Disable all fallbacks (checksum must exist)
  --allow-version-match Allow passing if only version strings match (insecure)
  -h, --help            Show this help

Exit Codes:
  0  - Verified (Checksum match)
  10 - Match found but integrity NOT guaranteed (Fallback method used)
  1  - Mismatch or Error
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) LOCAL_BIN="$2"; shift 2 ;;
    --no-docker) USE_DOCKER=false; shift ;;
    --strict) FALLBACK_DL=false; FALLBACK_VER=false; shift ;;
    --allow-version-match) FALLBACK_VER=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Deps check
command -v curl >/dev/null || { echo "Error: curl required"; exit 1; }
command -v jq >/dev/null || { echo "Error: jq required"; exit 1; }

# Hash cmd wrapper
get_sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "Error: sha256sum or shasum required" >&2; exit 1
  fi
}

# Cleanup
TMP_FILES=()
cleanup() { rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup EXIT

# 1. Check Local Binary
LOCAL_BIN_PATH=$(command -v "${LOCAL_BIN:-$BIN_NAME}" || true)
if [[ -z "$LOCAL_BIN_PATH" && -x "$LOCAL_BIN" ]]; then LOCAL_BIN_PATH="$LOCAL_BIN"; fi

if [[ ! -x "$LOCAL_BIN_PATH" ]]; then
  echo "Error: Local binary not found or not executable: ${LOCAL_BIN}" >&2
  exit 1
fi

echo ">> Local Binary: $LOCAL_BIN_PATH"
LOCAL_HASH=$(get_sha256 "$LOCAL_BIN_PATH")
LOCAL_VER_RAW=$("$LOCAL_BIN_PATH" --version 2>/dev/null || echo "N/A")
LOCAL_VER=$(echo "$LOCAL_VER_RAW" | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[ +].*$//')
echo "   SHA256: $LOCAL_HASH"
echo "   Version: $LOCAL_VER"

# 2. Determine Asset Name
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$OS" == "darwin" ]] && OS="osx"
[[ "$ARCH" == "x86_64" ]] && ARCH="x64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

ASSET_PREFIX="cyclonedx-${OS}-${ARCH}"
echo ">> Target Asset: ${ASSET_PREFIX}"

# 3. Fetch Release Info
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
echo ">> Fetching latest release info..."
REL_JSON=$(curl -fsSL "$API_URL") || { echo "Error: Failed to fetch GitHub release"; exit 1; }

REMOTE_TAG=$(echo "$REL_JSON" | jq -r '.tag_name // empty')
REMOTE_TAG_CLEAN="${REMOTE_TAG#v}"
echo "   Latest Tag: $REMOTE_TAG"

# 4. Verification Logic
MATCH_TYPE="none"
REMOTE_HASH=""
INTEGRITY_OK=false

# Strategy A: Checksums.txt (Preferred)
CHECKSUMS_URL=$(echo "$REL_JSON" | jq -r '.assets[] | select(.name | test("checksums?\\.txt$"; "i")) | .browser_download_url' | head -n1)

if [[ -n "$CHECKSUMS_URL" && "$CHECKSUMS_URL" != "null" ]]; then
  echo "   Checking checksums.txt..."
  TMP_SUMS=$(mktemp); TMP_FILES+=("$TMP_SUMS")
  curl -fsSL "$CHECKSUMS_URL" -o "$TMP_SUMS"
  
  # Try exact match then loose match
  REMOTE_HASH=$(grep -E "  ${ASSET_PREFIX}(\.zip|\.tar\.gz|$)" "$TMP_SUMS" | awk '{print $1}' | head -n1 || true)
  if [[ -z "$REMOTE_HASH" ]]; then
    REMOTE_HASH=$(grep "${ASSET_PREFIX}" "$TMP_SUMS" | awk '{print $1}' | head -n1 || true)
  fi
  
  if [[ -n "$REMOTE_HASH" ]]; then
    MATCH_TYPE="checksums.txt"
  fi
fi

# Strategy B: Individual .sha256 asset
if [[ -z "$REMOTE_HASH" ]]; then
  echo "   Checking individual .sha256 files..."
  # Find binary url first to construct sha url name
  BIN_URL=$(echo "$REL_JSON" | jq -r --arg n "$ASSET_PREFIX" '.assets[] | select(.name | startswith($n)) | .browser_download_url' | head -n1)
  if [[ -n "$BIN_URL" ]]; then
    BIN_NAME_BASE=$(basename "$BIN_URL")
    SHA_URL=$(echo "$REL_JSON" | jq -r --arg b "$BIN_NAME_BASE" '.assets[] | select(.name == $b+".sha256" or .name == $b+".sha256sum") | .browser_download_url' | head -n1)
    
    if [[ -n "$SHA_URL" && "$SHA_URL" != "null" ]]; then
      REMOTE_HASH=$(curl -fsSL "$SHA_URL" | awk '{print $1}' | head -n1)
      [[ -n "$REMOTE_HASH" ]] && MATCH_TYPE="asset-sha"
    fi
  fi
fi

# Strategy C: Download Remote Binary (Fallback)
if [[ -z "$REMOTE_HASH" && "$FALLBACK_DL" == "true" ]]; then
  echo "   (!) Checksum missing. Downloading remote asset for direct comparison..."
  DL_URL=$(echo "$REL_JSON" | jq -r --arg n "$ASSET_PREFIX" '.assets[] | select(.name | startswith($n)) | .browser_download_url' | head -n1)
  
  if [[ -n "$DL_URL" && "$DL_URL" != "null" ]]; then
    TMP_BIN=$(mktemp); TMP_FILES+=("$TMP_BIN")
    curl -fsSL "$DL_URL" -o "$TMP_BIN"
    REMOTE_HASH=$(get_sha256 "$TMP_BIN")
    MATCH_TYPE="binary-download (NO INTEGRITY GUARANTEE)"
  else
    echo "   Warning: Could not find remote asset to download."
  fi
fi

# Compare Hashes
FINAL_STATUS="FAIL"

if [[ -n "$REMOTE_HASH" ]]; then
  if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
    if [[ "$MATCH_TYPE" == *"binary-download"* ]]; then
      FINAL_STATUS="MATCH_UNVERIFIED"
    else
      FINAL_STATUS="MATCH_VERIFIED"
      INTEGRITY_OK=true
    fi
  else
    FINAL_STATUS="HASH_MISMATCH"
  fi
elif [[ "$FALLBACK_VER" == "true" ]]; then
  # Strategy D: Version String Match
  echo "   (!) Comparing version strings only..."
  if [[ "$LOCAL_VER" == "$REMOTE_TAG_CLEAN" ]]; then
    FINAL_STATUS="VERSION_MATCH_ONLY"
  else
    FINAL_STATUS="VERSION_MISMATCH"
  fi
else
  FINAL_STATUS="NO_DATA"
fi

# 5. Docker Check (Optional)
if [[ "$USE_DOCKER" == "true" ]] && command -v docker >/dev/null; then
  echo ">> Checking Docker version..."
  DOCKER_VER=$(docker run --rm cyclonedx/cyclonedx-cli --version 2>/dev/null || echo "Error")
  echo "   Docker Img: $DOCKER_VER"
fi

# 6. Summary
echo "=================================================="
echo "Summary: $FINAL_STATUS"
echo "  Local:  $LOCAL_HASH"

if [[ -n "$REMOTE_HASH" ]]; then
  echo "  Remote: $REMOTE_HASH ($MATCH_TYPE)"
else
  echo "  Remote: (Hash not found)"
fi

if [[ "$INTEGRITY_OK" == "true" ]]; then
  echo "Result: SUCCESS (Integrity Verified)"
  exit 0

elif [[ "$FINAL_STATUS" == "MATCH_UNVERIFIED" || "$FINAL_STATUS" == "VERSION_MATCH_ONLY" ]]; then
  echo "Result: WARNING - Files match but source integrity is NOT guaranteed." >&2
  
  exit 10 

else
  echo "Result: FAILED - Version or Hash mismatch!" >&2
  exit 1
fi
