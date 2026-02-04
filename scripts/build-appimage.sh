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

APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# =============================================================================
# Color-coded Logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "\n${GREEN}==>${NC} ${CYAN}$*${NC}"; }

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

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-build) SKIP_BUILD=true; shift ;;
            --clean) CLEAN=true; shift ;;
            --help|-h) show_help ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
}

# =============================================================================
# Dependency Checking
# =============================================================================

check_dependencies() {
    log_step "Checking dependencies"
    
    local missing=()
    
    command -v cmake &>/dev/null || missing+=("cmake")
    command -v wget &>/dev/null || command -v curl &>/dev/null || missing+=("wget or curl")
    command -v make &>/dev/null || command -v ninja &>/dev/null || missing+=("make or ninja")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
    
    log_info "All dependencies satisfied"
}

# =============================================================================
# Tool Download
# =============================================================================

download_file() {
    local url="$1" output="$2"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$output" "$url"
    else
        curl -L --progress-bar -o "$output" "$url"
    fi
}

download_tools() {
    log_step "Checking appimagetool"
    
    mkdir -p "${PROJECT_ROOT}/${TOOLS_DIR}"
    
    if [[ ! -f "${PROJECT_ROOT}/${TOOLS_DIR}/appimagetool-x86_64.AppImage" ]]; then
        log_info "Downloading appimagetool..."
        download_file "$APPIMAGETOOL_URL" "${PROJECT_ROOT}/${TOOLS_DIR}/appimagetool-x86_64.AppImage"
        chmod +x "${PROJECT_ROOT}/${TOOLS_DIR}/appimagetool-x86_64.AppImage"
    else
        log_info "appimagetool already available"
    fi
}

# =============================================================================
# Build Application
# =============================================================================

build_app() {
    if [[ "$SKIP_BUILD" == true ]]; then
        log_step "Skipping build (--skip-build specified)"
        [[ -d "${PROJECT_ROOT}/${BUILD_DIR}" ]] || { log_error "Build directory does not exist"; exit 1; }
        return
    fi
    
    log_step "Building application"
    cd "${PROJECT_ROOT}"
    
    [[ "$CLEAN" == true ]] && rm -rf "${BUILD_DIR}"
    
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
    
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build . --parallel "$(nproc)"
    
    cd "${PROJECT_ROOT}"
    log_info "Build complete"
}

# =============================================================================
# Create AppDir Structure (Manual approach - more reliable than linuxdeploy)
# =============================================================================

create_appdir() {
    log_step "Creating AppDir structure"
    
    cd "${PROJECT_ROOT}"
    rm -rf "${APPDIR}"
    
    # Create directory structure
    mkdir -p "${APPDIR}/usr/bin"
    mkdir -p "${APPDIR}/usr/lib/jules-linux/grammars"
    mkdir -p "${APPDIR}/usr/plugins/platforms"
    mkdir -p "${APPDIR}/usr/plugins/xcbglintegrations"
    mkdir -p "${APPDIR}/usr/plugins/sqldrivers"
    mkdir -p "${APPDIR}/usr/plugins/imageformats"
    mkdir -p "${APPDIR}/usr/share/applications"
    mkdir -p "${APPDIR}/usr/share/icons/hicolor/256x256/apps"
    mkdir -p "${APPDIR}/usr/share/icons/hicolor/scalable/apps"
    
    # Copy main executable
    cp "${BUILD_DIR}/jules-linux" "${APPDIR}/usr/bin/"
    
    # Copy tree-sitter grammars
    if [[ -d "grammars" ]]; then
        cp -a grammars/*.so "${APPDIR}/usr/lib/jules-linux/grammars/" 2>/dev/null || true
    fi
    
    # Copy desktop file and icons
    cp "resources/jules-linux.desktop" "${APPDIR}/usr/share/applications/"
    cp "resources/icons/jules-256.png" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/jules.png" 2>/dev/null || true
    cp "resources/icons/jules.svg" "${APPDIR}/usr/share/icons/hicolor/scalable/apps/" 2>/dev/null || true
    
    # Create top-level symlinks required by AppImage
    ln -sf "usr/share/applications/jules-linux.desktop" "${APPDIR}/jules-linux.desktop"
    cp "resources/icons/jules-256.png" "${APPDIR}/jules.png" 2>/dev/null || touch "${APPDIR}/jules.png"
    
    log_info "AppDir structure created"
}

# =============================================================================
# Bundle Dependencies
# =============================================================================

bundle_dependencies() {
    log_step "Bundling dependencies"
    
    cd "${PROJECT_ROOT}"
    
    # Copy all library dependencies of the main executable
    log_info "Copying library dependencies..."
    ldd "${BUILD_DIR}/jules-linux" | grep "=> /" | awk '{print $3}' | while read -r lib; do
        # Skip system libraries that should not be bundled
        case "$(basename "$lib")" in
            libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*.so*) continue ;;
            libGL.so*|libGLX.so*|libGLdispatch.so*|libEGL.so*|libOpenGL.so*) continue ;;
            libX11.so*|libxcb.so*|libfontconfig.so*|libfreetype.so*) continue ;;
            libstdc++.so*|libgcc_s.so*) continue ;;
        esac
        cp -n "$lib" "${APPDIR}/usr/lib/" 2>/dev/null || true
    done
    
    # Copy essential Qt plugins
    log_info "Copying Qt plugins..."
    local qt_plugin_dir
    qt_plugin_dir=$(pkg-config --variable=plugindir Qt6Core 2>/dev/null || echo "/usr/lib/qt6/plugins")
    
    # Platform plugin (required)
    cp "${qt_plugin_dir}/platforms/libqxcb.so" "${APPDIR}/usr/plugins/platforms/" 2>/dev/null || true
    
    # XCB GL integration
    cp "${qt_plugin_dir}/xcbglintegrations/"*.so "${APPDIR}/usr/plugins/xcbglintegrations/" 2>/dev/null || true
    
    # SQLite driver (for session storage)
    cp "${qt_plugin_dir}/sqldrivers/libqsqlite.so" "${APPDIR}/usr/plugins/sqldrivers/" 2>/dev/null || true
    
    # Basic image formats only (skip problematic ones like jxr, heif, avif)
    for fmt in libqico.so libqjpeg.so libqgif.so libqsvg.so; do
        cp "${qt_plugin_dir}/imageformats/${fmt}" "${APPDIR}/usr/plugins/imageformats/" 2>/dev/null || true
    done
    
    # Copy dependencies of Qt plugins
    log_info "Resolving plugin dependencies..."
    find "${APPDIR}/usr/plugins" -name "*.so" -exec ldd {} \; 2>/dev/null | \
        grep "=> /" | awk '{print $3}' | sort -u | while read -r lib; do
        case "$(basename "$lib")" in
            libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*.so*) continue ;;
            libGL.so*|libGLX.so*|libGLdispatch.so*|libEGL.so*|libOpenGL.so*) continue ;;
            libX11.so*|libxcb.so*|libfontconfig.so*|libfreetype.so*) continue ;;
            libstdc++.so*|libgcc_s.so*) continue ;;
        esac
        cp -n "$lib" "${APPDIR}/usr/lib/" 2>/dev/null || true
    done
    
    log_info "Dependencies bundled ($(ls "${APPDIR}/usr/lib/" | wc -l) libraries)"
}

# =============================================================================
# Create AppRun
# =============================================================================

create_apprun() {
    log_step "Creating AppRun"
    
    cat > "${PROJECT_ROOT}/${APPDIR}/AppRun" << 'EOF'
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${APPDIR}/usr/lib:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="${APPDIR}/usr/plugins:${QT_PLUGIN_PATH:-}"
export TREE_SITTER_GRAMMAR_PATH="${APPDIR}/usr/lib/jules-linux/grammars"
export JULES_APPIMAGE=1
export JULES_APPDIR="${APPDIR}"
exec "${APPDIR}/usr/bin/jules-linux" "$@"
EOF
    
    chmod +x "${PROJECT_ROOT}/${APPDIR}/AppRun"
    log_info "AppRun created"
}

# =============================================================================
# Create AppImage
# =============================================================================

create_appimage() {
    log_step "Creating AppImage"
    
    cd "${PROJECT_ROOT}"
    
    "${TOOLS_DIR}/appimagetool-x86_64.AppImage" --appimage-extract-and-run \
        "${APPDIR}" "${OUTPUT_NAME}" 2>&1 || {
        log_error "appimagetool failed"
        exit 1
    }
    
    if [[ -f "$OUTPUT_NAME" ]]; then
        local size
        size=$(du -h "$OUTPUT_NAME" | cut -f1)
        log_info "AppImage created: ${OUTPUT_NAME} (${size})"
    else
        log_error "AppImage creation failed"
        exit 1
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_step "Cleaning up"
    rm -rf "${PROJECT_ROOT}/${APPDIR}"
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
    bundle_dependencies
    create_apprun
    create_appimage
    cleanup
    
    echo ""
    log_step "Build complete!"
    echo ""
    echo "  Output: ${PROJECT_ROOT}/${OUTPUT_NAME}"
    echo "  Run with: ./${OUTPUT_NAME}"
    echo ""
}

main "$@"
