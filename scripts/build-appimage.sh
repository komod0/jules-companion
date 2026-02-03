#!/bin/bash
# =============================================================================
# Jules Linux AppImage Build Script
# =============================================================================
# Creates a portable AppImage bundle for the Jules Linux application.
#
# Usage:
#   ./scripts/build-appimage.sh [OPTIONS]
#
# Options:
#   --skip-build    Skip the CMake build step (use existing build)
#   --clean         Clean build and AppDir before starting
#   --help          Show this help message
#
# Requirements:
#   - cmake, make/ninja
#   - wget or curl
#   - qmake6 or qmake (Qt6)
#   - FUSE (for running AppImages)
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

APP_NAME="jules-linux"
OUTPUT_NAME="Jules-x86_64.AppImage"
BUILD_DIR="build"
APPDIR="Jules.AppDir"
TOOLS_DIR=".appimage-tools"

# linuxdeploy tool URLs
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
LINUXDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"

# Script directory (for relative paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# =============================================================================
# Color-coded Logging
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${GREEN}==>${NC} ${CYAN}$*${NC}"
}

# =============================================================================
# Argument Parsing
# =============================================================================

SKIP_BUILD=false
CLEAN=false

show_help() {
    cat << EOF
Jules Linux AppImage Build Script

Usage: $(basename "$0") [OPTIONS]

Options:
  --skip-build    Skip the CMake build step (use existing build)
  --clean         Clean build directory and AppDir before starting
  --help          Show this help message

Examples:
  $(basename "$0")              # Full build and package
  $(basename "$0") --skip-build # Package only (assumes build exists)
  $(basename "$0") --clean      # Clean build from scratch

Requirements:
  - cmake, make or ninja
  - wget or curl
  - qmake6 or qmake (for Qt6 detection)
  - FUSE (for running/creating AppImages)

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --clean)
                CLEAN=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# Dependency Checking
# =============================================================================

check_dependencies() {
    log_step "Checking dependencies"
    
    local missing=()
    
    # Check cmake
    if ! command -v cmake &>/dev/null; then
        missing+=("cmake")
    else
        log_info "Found cmake: $(cmake --version | head -1)"
    fi
    
    # Check wget or curl
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        missing+=("wget or curl")
    else
        if command -v wget &>/dev/null; then
            log_info "Found wget: $(wget --version | head -1)"
        else
            log_info "Found curl: $(curl --version | head -1)"
        fi
    fi
    
    # Check qmake6 or qmake
    if command -v qmake6 &>/dev/null; then
        log_info "Found qmake6: $(qmake6 --version | tail -1)"
        export QMAKE=qmake6
    elif command -v qmake &>/dev/null; then
        log_info "Found qmake: $(qmake --version | tail -1)"
        export QMAKE=qmake
    else
        missing+=("qmake6 or qmake")
    fi
    
    # Check make or ninja
    if ! command -v make &>/dev/null && ! command -v ninja &>/dev/null; then
        missing+=("make or ninja")
    fi
    
    # Report missing dependencies
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            log_error "  - $dep"
        done
        exit 1
    fi
    
    log_info "All dependencies satisfied"
}

# =============================================================================
# Tool Download
# =============================================================================

download_file() {
    local url="$1"
    local output="$2"
    
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$output" "$url"
    else
        curl -L --progress-bar -o "$output" "$url"
    fi
}

download_tools() {
    log_step "Downloading linuxdeploy tools"
    
    mkdir -p "${PROJECT_ROOT}/${TOOLS_DIR}"
    cd "${PROJECT_ROOT}/${TOOLS_DIR}"
    
    # Download linuxdeploy
    if [[ ! -f "linuxdeploy-x86_64.AppImage" ]]; then
        log_info "Downloading linuxdeploy..."
        download_file "$LINUXDEPLOY_URL" "linuxdeploy-x86_64.AppImage"
        chmod +x "linuxdeploy-x86_64.AppImage"
    else
        log_info "linuxdeploy already downloaded"
    fi
    
    # Download linuxdeploy-plugin-qt
    if [[ ! -f "linuxdeploy-plugin-qt-x86_64.AppImage" ]]; then
        log_info "Downloading linuxdeploy-plugin-qt..."
        download_file "$LINUXDEPLOY_QT_URL" "linuxdeploy-plugin-qt-x86_64.AppImage"
        chmod +x "linuxdeploy-plugin-qt-x86_64.AppImage"
    else
        log_info "linuxdeploy-plugin-qt already downloaded"
    fi
    
    cd "${PROJECT_ROOT}"
    log_info "Tools ready in ${TOOLS_DIR}/"
}

# =============================================================================
# Build Application
# =============================================================================

build_app() {
    if [[ "$SKIP_BUILD" == true ]]; then
        log_step "Skipping build (--skip-build specified)"
        if [[ ! -d "${PROJECT_ROOT}/${BUILD_DIR}" ]]; then
            log_error "Build directory does not exist. Cannot skip build."
            exit 1
        fi
        return
    fi
    
    log_step "Building application"
    
    cd "${PROJECT_ROOT}"
    
    # Clean if requested
    if [[ "$CLEAN" == true ]]; then
        log_info "Cleaning build directory..."
        rm -rf "${BUILD_DIR}"
    fi
    
    # Create build directory
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
    
    # Configure with CMake
    log_info "Configuring with CMake..."
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr
    
    # Build
    log_info "Building..."
    cmake --build . --parallel "$(nproc)"
    
    cd "${PROJECT_ROOT}"
    log_info "Build complete"
}

# =============================================================================
# Create AppDir Structure
# =============================================================================

create_appdir() {
    log_step "Creating AppDir structure"
    
    cd "${PROJECT_ROOT}"
    
    # Clean existing AppDir if requested
    if [[ "$CLEAN" == true ]]; then
        log_info "Cleaning existing AppDir..."
        rm -rf "${APPDIR}"
    fi
    
    # Remove existing AppDir for fresh install
    rm -rf "${APPDIR}"
    
    # Install to AppDir using DESTDIR
    log_info "Installing to AppDir..."
    cd "${BUILD_DIR}"
    DESTDIR="${PROJECT_ROOT}/${APPDIR}" cmake --install .
    
    cd "${PROJECT_ROOT}"
    log_info "AppDir created at ${APPDIR}/"
}

# =============================================================================
# Create AppRun Wrapper
# =============================================================================

create_apprun() {
    log_step "Creating AppRun wrapper"
    
    cat > "${PROJECT_ROOT}/${APPDIR}/AppRun" << 'APPRUN_EOF'
#!/bin/bash
# =============================================================================
# Jules AppRun - Application launcher for AppImage
# =============================================================================

# Get the directory where this AppRun script is located
APPDIR="$(dirname "$(readlink -f "$0")")"

# -----------------------------------------------------------------------------
# Library Path Setup
# -----------------------------------------------------------------------------
# Add bundled libraries to the library search path
export LD_LIBRARY_PATH="${APPDIR}/usr/lib:${APPDIR}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

# -----------------------------------------------------------------------------
# Qt Plugin Path Setup
# -----------------------------------------------------------------------------
# Point Qt to the bundled plugins
export QT_PLUGIN_PATH="${APPDIR}/usr/plugins:${QT_PLUGIN_PATH:-}"

# Also set QML import path if QML is used
export QML2_IMPORT_PATH="${APPDIR}/usr/qml:${QML2_IMPORT_PATH:-}"

# -----------------------------------------------------------------------------
# Tree-sitter Grammar Path
# -----------------------------------------------------------------------------
# Point to bundled grammar .so files
export TREE_SITTER_GRAMMAR_PATH="${APPDIR}/usr/lib/jules-linux/grammars"

# -----------------------------------------------------------------------------
# XDG Paths for Config Isolation (optional)
# -----------------------------------------------------------------------------
# Uncomment these to fully isolate config/data from system installation
# export XDG_CONFIG_HOME="${HOME}/.config"
# export XDG_DATA_HOME="${HOME}/.local/share"
# export XDG_CACHE_HOME="${HOME}/.cache"

# Set application-specific paths
export JULES_APPIMAGE=1
export JULES_APPDIR="${APPDIR}"

# -----------------------------------------------------------------------------
# Launch Application
# -----------------------------------------------------------------------------
exec "${APPDIR}/usr/bin/jules-linux" "$@"
APPRUN_EOF

    chmod +x "${PROJECT_ROOT}/${APPDIR}/AppRun"
    log_info "AppRun wrapper created"
}

# =============================================================================
# Create Desktop File Symlinks
# =============================================================================

create_desktop_symlinks() {
    log_step "Creating desktop file symlinks"
    
    cd "${PROJECT_ROOT}/${APPDIR}"
    
    # Find and symlink .desktop file
    local desktop_file
    desktop_file=$(find usr/share/applications -name "*.desktop" 2>/dev/null | head -1)
    
    if [[ -n "$desktop_file" ]]; then
        ln -sf "$desktop_file" "${APP_NAME}.desktop"
        log_info "Linked desktop file: $desktop_file"
    else
        log_warn "No .desktop file found in usr/share/applications/"
    fi
    
    # Find and symlink icon
    # Try various icon locations and sizes (prefer larger)
    local icon_file=""
    for size in 512 256 128 64 48 32; do
        icon_file=$(find usr/share/icons -name "${APP_NAME}.png" -path "*${size}*" 2>/dev/null | head -1)
        [[ -n "$icon_file" ]] && break
    done
    
    # Fallback: any icon with the app name
    if [[ -z "$icon_file" ]]; then
        icon_file=$(find usr/share/icons -name "${APP_NAME}.*" 2>/dev/null | head -1)
    fi
    
    # Fallback: pixmaps
    if [[ -z "$icon_file" ]]; then
        icon_file=$(find usr/share/pixmaps -name "${APP_NAME}.*" 2>/dev/null | head -1)
    fi
    
    if [[ -n "$icon_file" ]]; then
        # Get extension
        local ext="${icon_file##*.}"
        ln -sf "$icon_file" "${APP_NAME}.${ext}"
        log_info "Linked icon: $icon_file"
    else
        log_warn "No icon found for ${APP_NAME}"
    fi
    
    cd "${PROJECT_ROOT}"
}

# =============================================================================
# Bundle Dependencies with linuxdeploy
# =============================================================================

bundle_dependencies() {
    log_step "Bundling dependencies with linuxdeploy"
    
    cd "${PROJECT_ROOT}"
    
    local linuxdeploy="${TOOLS_DIR}/linuxdeploy-x86_64.AppImage"
    local linuxdeploy_qt="${TOOLS_DIR}/linuxdeploy-plugin-qt-x86_64.AppImage"
    
    # Verify tools exist
    if [[ ! -x "$linuxdeploy" ]]; then
        log_error "linuxdeploy not found at $linuxdeploy"
        exit 1
    fi
    
    if [[ ! -x "$linuxdeploy_qt" ]]; then
        log_error "linuxdeploy-plugin-qt not found at $linuxdeploy_qt"
        exit 1
    fi
    
    # Set environment for Qt plugin
    export QMAKE="${QMAKE:-qmake6}"
    export PATH="${TOOLS_DIR}:${PATH}"
    
    # Run linuxdeploy with Qt plugin
    # Note: Using --appimage-extract-and-run to avoid FUSE requirement during build
    log_info "Running linuxdeploy with Qt plugin..."
    
    "${linuxdeploy}" \
        --appimage-extract-and-run \
        --appdir "${APPDIR}" \
        --plugin qt \
        --output appimage \
        --desktop-file "${APPDIR}/${APP_NAME}.desktop"
    
    log_info "Dependencies bundled successfully"
}

# =============================================================================
# Create Final AppImage
# =============================================================================

create_appimage() {
    log_step "Creating AppImage"
    
    cd "${PROJECT_ROOT}"
    
    # linuxdeploy creates the AppImage with a default name
    # Find it and rename to our desired output name
    local created_appimage
    created_appimage=$(ls -t Jules*.AppImage 2>/dev/null | head -1 || true)
    
    if [[ -z "$created_appimage" ]]; then
        # Try generic pattern
        created_appimage=$(ls -t *.AppImage 2>/dev/null | grep -v linuxdeploy | head -1 || true)
    fi
    
    if [[ -n "$created_appimage" && "$created_appimage" != "$OUTPUT_NAME" ]]; then
        mv "$created_appimage" "$OUTPUT_NAME"
    fi
    
    if [[ -f "$OUTPUT_NAME" ]]; then
        local size
        size=$(du -h "$OUTPUT_NAME" | cut -f1)
        log_info "AppImage created: ${OUTPUT_NAME} (${size})"
        log_info "To run: ./${OUTPUT_NAME}"
    else
        log_error "AppImage creation failed - output file not found"
        exit 1
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_step "Cleaning up"
    
    # Remove AppDir (it's no longer needed after AppImage is created)
    if [[ -d "${PROJECT_ROOT}/${APPDIR}" ]]; then
        log_info "Removing AppDir..."
        rm -rf "${PROJECT_ROOT}/${APPDIR}"
    fi
    
    log_info "Cleanup complete"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "========================================"
    echo "  Jules Linux AppImage Builder"
    echo "========================================"
    echo ""
    
    parse_args "$@"
    
    cd "${PROJECT_ROOT}"
    
    check_dependencies
    download_tools
    build_app
    create_appdir
    create_apprun
    create_desktop_symlinks
    bundle_dependencies
    create_appimage
    cleanup
    
    echo ""
    log_step "Build complete!"
    echo ""
    echo "  Output: ${PROJECT_ROOT}/${OUTPUT_NAME}"
    echo ""
    echo "  Run with: ./${OUTPUT_NAME}"
    echo ""
}

# Run main function
main "$@"
