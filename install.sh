#!/bin/sh
set -eu

# Distribution settings rendered from single configuration source
GITHUB_ORG="maplefall-studio"
RELEASES_REPO="peku-releases"
BINARY_NAME="peku"

# Default install directory: ~/.local/bin unless PEKU_INSTALL_DIR is provided
INSTALL_DIR="${PEKU_INSTALL_DIR:-$HOME/.local/bin}"

# Architecture detection
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    TARGET_OS="darwin"
    ;;
  Linux)
    TARGET_OS="linux"
    ;;
  *)
    echo "Error: Unsupported operating system: $OS" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  x86_64|amd64)
    TARGET_ARCH="amd64"
    ;;
  arm64|aarch64)
    TARGET_ARCH="arm64"
    ;;
  *)
    echo "Error: Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

TAR_NAME="${BINARY_NAME}-${TARGET_OS}-${TARGET_ARCH}.tar.gz"

# Version resolution
if [ -n "${PEKU_VERSION:-}" ]; then
  # Validate PEKU_VERSION: allow leading 'v', then strict semver characters (digits, dots, hyphens, plus)
  case "$PEKU_VERSION" in
    v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*)
      # Further check for illegal path traversal / special characters (slashes, whitespace, newlines)
      case "$PEKU_VERSION" in
        *[!0-9a-zA-Z._+-]*)
          echo "Error: PEKU_VERSION contains invalid characters: $PEKU_VERSION" >&2
          exit 1
          ;;
      esac
      VERSION="$PEKU_VERSION"
      ;;
    *)
      echo "Error: Invalid PEKU_VERSION format: '$PEKU_VERSION'. Must be a semantic version (e.g. 0.1.0 or v0.1.0)." >&2
      exit 1
      ;;
  esac
else
  # Resolve latest version via public GitHub API
  LATEST_API_URL="https://api.github.com/repos/${GITHUB_ORG}/${RELEASES_REPO}/releases/latest"
  echo "Fetching latest version information from ${LATEST_API_URL}..." >&2
  API_RESPONSE="$(curl -fsSL "$LATEST_API_URL" || true)"
  if [ -z "$API_RESPONSE" ]; then
    echo "Error: Failed to fetch latest release from ${LATEST_API_URL}." >&2
    echo "Please specify a version explicitly using PEKU_VERSION=vX.Y.Z (or PEKU_VERSION=X.Y.Z)." >&2
    exit 1
  fi

  # Extract tag_name from JSON without external JSON parser dependencies
  # Format in GitHub API: "tag_name": "v0.1.0" or "tag_name":"v0.1.0"
  VERSION="$(printf '%s' "$API_RESPONSE" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  if [ -z "$VERSION" ]; then
    echo "Error: Unable to parse tag_name from release response." >&2
    exit 1
  fi
fi

# Ensure tag has v prefix for release assets URL
case "$VERSION" in
  v*)
    TAG="$VERSION"
    ;;
  *)
    TAG="v${VERSION}"
    ;;
esac

DOWNLOAD_BASE_URL="https://github.com/${GITHUB_ORG}/${RELEASES_REPO}/releases/download/${TAG}"
CHECKSUMS_URL="${DOWNLOAD_BASE_URL}/sha256sums.txt"
ARCHIVE_URL="${DOWNLOAD_BASE_URL}/${TAR_NAME}"

# SHA-256 tool check
if command -v sha256sum >/dev/null 2>&1; then
  CHECK_SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECK_SHA="shasum -a 256"
else
  echo "Error: Neither sha256sum nor shasum is available for checksum verification." >&2
  exit 1
fi

# Prepare temporary work directory securely
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'peku-install' 2>/dev/null || true)"
if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
  echo "Error: Failed to create a secure temporary directory via mktemp." >&2
  exit 1
fi

TEMP_TARGET=""
cleanup() {
  if [ -n "$TEMP_TARGET" ] && [ -f "$TEMP_TARGET" ]; then
    rm -f "$TEMP_TARGET"
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM HUP

echo "Downloading ${CHECKSUMS_URL}..." >&2
if ! curl -fsSL "$CHECKSUMS_URL" -o "$TMP_DIR/sha256sums.txt"; then
  echo "Error: Failed to download checksums from ${CHECKSUMS_URL}." >&2
  exit 1
fi

echo "Downloading ${ARCHIVE_URL}..." >&2
if ! curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/${TAR_NAME}"; then
  echo "Error: Failed to download archive from ${ARCHIVE_URL}." >&2
  exit 1
fi

# Verify checksum
EXPECTED_SHA="$(grep "${TAR_NAME}$" "$TMP_DIR/sha256sums.txt" | awk '{print $1}' | head -n 1)"
if [ -z "$EXPECTED_SHA" ]; then
  echo "Error: Checksum for ${TAR_NAME} not found in sha256sums.txt." >&2
  exit 1
fi

ACTUAL_SHA="$(cd "$TMP_DIR" && $CHECK_SHA "${TAR_NAME}" | awk '{print $1}')"
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo "Error: Checksum verification failed for ${TAR_NAME}." >&2
  echo "Expected: ${EXPECTED_SHA}" >&2
  echo "Actual:   ${ACTUAL_SHA}" >&2
  exit 1
fi

echo "Checksum verified: ${ACTUAL_SHA}" >&2

# Extract binary
if ! tar -xzf "$TMP_DIR/${TAR_NAME}" -C "$TMP_DIR" "${BINARY_NAME}"; then
  echo "Error: Failed to extract ${BINARY_NAME} from ${TAR_NAME}." >&2
  exit 1
fi

EXTRACTED_BIN="$TMP_DIR/${BINARY_NAME}"
if [ ! -f "$EXTRACTED_BIN" ]; then
  echo "Error: Binary ${BINARY_NAME} not found in archive." >&2
  exit 1
fi

chmod +x "$EXTRACTED_BIN"

# Ensure install directory exists
mkdir -p "$INSTALL_DIR"

# Atomic install using secure mktemp in the destination directory
TARGET_BIN="$INSTALL_DIR/${BINARY_NAME}"
TEMP_TARGET="$(mktemp "${TARGET_BIN}.tmp.XXXXXX" 2>/dev/null || true)"
if [ -z "$TEMP_TARGET" ]; then
  echo "Error: Failed to create temporary binary in ${INSTALL_DIR} via mktemp." >&2
  exit 1
fi

cp "$EXTRACTED_BIN" "$TEMP_TARGET"
chmod +x "$TEMP_TARGET"
mv -f "$TEMP_TARGET" "$TARGET_BIN"
TEMP_TARGET=""

echo "Successfully installed ${BINARY_NAME} (${TAG}) to ${TARGET_BIN}" >&2

# PATH guidance (without modifying shell rc)
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    echo "" >&2
    echo "Note: ${INSTALL_DIR} is not in your PATH." >&2
    echo "Add it to your PATH by adding this line to your shell profile (~/.bashrc, ~/.zshrc, etc.):" >&2
    echo "  export PATH=\"\$PATH:${INSTALL_DIR}\"" >&2
    ;;
esac
