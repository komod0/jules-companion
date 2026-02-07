#!/bin/bash
# =============================================================================
# Jules AppImage Local Install Script
# =============================================================================
# Installs the AppImage to ~/.local/bin and sets up desktop integration
# =============================================================================

set -euo pipefail

APP_NAME="Jules-x86_64.AppImage"
INSTALL_DIR="$HOME/.local/bin"
DESKTOP_FILE="$HOME/.local/share/applications/jules-linux.desktop"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Installing Jules...${NC}"

# 1. Create install directory
mkdir -p "$INSTALL_DIR"

# 2. Find the AppImage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPIMAGE_SRC="${PROJECT_ROOT}/${APP_NAME}"

if [[ ! -f "$APPIMAGE_SRC" ]]; then
    echo "Error: ${APP_NAME} not found in ${PROJECT_ROOT}"
    exit 1
fi

# 3. Copy to install location
echo "  Copying to ${INSTALL_DIR}/"
cp "$APPIMAGE_SRC" "${INSTALL_DIR}/${APP_NAME}"
chmod +x "${INSTALL_DIR}/${APP_NAME}"

# 4. Remove old desktop file (so it regenerates with new path)
rm -f "$DESKTOP_FILE"

# 5. Run briefly to trigger desktop integration
echo "  Setting up desktop integration..."
timeout 2 "${INSTALL_DIR}/${APP_NAME}" &>/dev/null || true
sleep 1

# 6. Install icons to XDG paths
echo "  Installing icons..."
ICON_SRC="${PROJECT_ROOT}/resources/icons"
ICON_DST="${HOME}/.local/share/icons/hicolor"
for SIZE in 16 32 48 64 128 256; do
    mkdir -p "${ICON_DST}/${SIZE}x${SIZE}/apps"
    cp "${ICON_SRC}/jules-${SIZE}.png" "${ICON_DST}/${SIZE}x${SIZE}/apps/jules.png"
done
if [[ -f "${ICON_SRC}/jules.svg" ]]; then
    mkdir -p "${ICON_DST}/scalable/apps"
    cp "${ICON_SRC}/jules.svg" "${ICON_DST}/scalable/apps/jules.svg"
fi

# 7. Update icon cache
if command -v gtk-update-icon-cache &>/dev/null; then
    gtk-update-icon-cache -f -t "${ICON_DST}" 2>/dev/null || true
elif command -v update-icon-caches &>/dev/null; then
    update-icon-caches "${ICON_DST}" 2>/dev/null || true
fi

# 8. Update desktop database
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true
fi

# 9. Verify
echo ""
if [[ -f "$DESKTOP_FILE" ]]; then
    echo -e "${GREEN}✓ Installed successfully!${NC}"
    echo ""
    echo "  Location: ${INSTALL_DIR}/${APP_NAME}"
    echo "  Desktop:  ${DESKTOP_FILE}"
    echo ""
    echo "  You can now:"
    echo "    - Search 'Jules' in your app launcher"
    echo "    - Run from terminal: ~/.local/bin/${APP_NAME}"
    echo ""
else
    echo "Warning: Desktop file not created. You may need to run the app manually once."
fi
