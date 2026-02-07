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
    mkdir -p "${APPDIR}/usr/share/icons/hicolor/scalable/apps"
    mkdir -p "${APPDIR}/usr/share/fonts/truetype/dejavu"
    
    # Copy main executable
    cp "${BUILD_DIR}/jules-linux" "${APPDIR}/usr/bin/"
    
    # Copy tree-sitter grammars
    if [[ -d "grammars" ]]; then
        cp -a grammars/*.so "${APPDIR}/usr/lib/jules-linux/grammars/" 2>/dev/null || true
    fi
    
    # Copy desktop file and icons (all sizes for proper XDG integration)
    cp "resources/jules-linux.desktop" "${APPDIR}/usr/share/applications/"
    for SIZE in 16 32 48 64 128 256; do
        mkdir -p "${APPDIR}/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps"
        cp "resources/icons/jules-${SIZE}.png" "${APPDIR}/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps/jules.png"
    done
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
    qt_plugin_dir=$(pkg-config --variable=plugindir Qt6Core 2>/dev/null)
    
    # Fallback: search common locations if pkg-config failed
    if [[ -z "$qt_plugin_dir" || ! -d "$qt_plugin_dir" ]]; then
        for candidate in "/usr/lib/qt6/plugins" "/usr/lib/x86_64-linux-gnu/qt6/plugins" "/usr/lib64/qt6/plugins"; do
            if [[ -d "$candidate" ]]; then
                qt_plugin_dir="$candidate"
                break
            fi
        done
    fi
    
    log_info "  Qt plugin dir: ${qt_plugin_dir:-NOT FOUND}"
    
    # Platform plugins (XCB for X11, Wayland for native Wayland)
    cp "${qt_plugin_dir}/platforms/libqxcb.so" "${APPDIR}/usr/plugins/platforms/" 2>/dev/null || true
    cp "${qt_plugin_dir}/platforms/libqwayland.so" "${APPDIR}/usr/plugins/platforms/" 2>/dev/null || true
    
    # Wayland shell integrations (for native Wayland decorations)
    mkdir -p "${APPDIR}/usr/plugins/wayland-shell-integration"
    cp "${qt_plugin_dir}/wayland-shell-integration/"*.so "${APPDIR}/usr/plugins/wayland-shell-integration/" 2>/dev/null || true
    
    # Wayland graphics integrations
    mkdir -p "${APPDIR}/usr/plugins/wayland-graphics-integration-client"
    cp "${qt_plugin_dir}/wayland-graphics-integration-client/"*.so "${APPDIR}/usr/plugins/wayland-graphics-integration-client/" 2>/dev/null || true
    
    # Wayland decoration plugins
    mkdir -p "${APPDIR}/usr/plugins/wayland-decoration-client"
    cp "${qt_plugin_dir}/wayland-decoration-client/"*.so "${APPDIR}/usr/plugins/wayland-decoration-client/" 2>/dev/null || true
    
    # XCB GL integration (for X11)
    cp "${qt_plugin_dir}/xcbglintegrations/"*.so "${APPDIR}/usr/plugins/xcbglintegrations/" 2>/dev/null || true
    
    # SQLite driver (for session storage)
    cp "${qt_plugin_dir}/sqldrivers/libqsqlite.so" "${APPDIR}/usr/plugins/sqldrivers/" 2>/dev/null || true
    
    # Basic image formats only (skip problematic ones like jxr, heif, avif)
    for fmt in libqico.so libqjpeg.so libqgif.so libqsvg.so; do
        cp "${qt_plugin_dir}/imageformats/${fmt}" "${APPDIR}/usr/plugins/imageformats/" 2>/dev/null || true
    done
    
    # TLS backend plugins (CRITICAL for HTTPS/API calls)
    mkdir -p "${APPDIR}/usr/plugins/tls"
    cp "${qt_plugin_dir}/tls/libqopensslbackend.so" "${APPDIR}/usr/plugins/tls/" 2>/dev/null || true
    cp "${qt_plugin_dir}/tls/libqcertonlybackend.so" "${APPDIR}/usr/plugins/tls/" 2>/dev/null || true
    log_info "  Bundled TLS plugins for HTTPS support"
    
    # Copy dependencies of Qt plugins
    log_info "Resolving plugin dependencies..."
    local plugin_count
    plugin_count=$(find "${APPDIR}/usr/plugins" -name "*.so" 2>/dev/null | wc -l)
    
    if [[ "$plugin_count" -gt 0 ]]; then
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
    else
        log_warn "No Qt plugins found to resolve dependencies for"
    fi
    
    # Bundle OpenSSL libraries for HTTPS/TLS support
    log_info "Bundling OpenSSL libraries..."
    for ssl_lib in libssl.so.3 libcrypto.so.3; do
        if [[ -f "/usr/lib/x86_64-linux-gnu/${ssl_lib}" ]]; then
            cp -n "/usr/lib/x86_64-linux-gnu/${ssl_lib}" "${APPDIR}/usr/lib/" 2>/dev/null || true
            log_info "  Bundled ${ssl_lib}"
        elif [[ -f "/usr/lib64/${ssl_lib}" ]]; then
            cp -n "/usr/lib64/${ssl_lib}" "${APPDIR}/usr/lib/" 2>/dev/null || true
            log_info "  Bundled ${ssl_lib}"
        elif [[ -f "/lib/x86_64-linux-gnu/${ssl_lib}" ]]; then
            cp -n "/lib/x86_64-linux-gnu/${ssl_lib}" "${APPDIR}/usr/lib/" 2>/dev/null || true
            log_info "  Bundled ${ssl_lib}"
        else
            log_warn "  Could not find ${ssl_lib} - HTTPS may not work"
        fi
    done
    
    # Bundle DejaVu Sans Mono font for diff rendering
    log_info "Bundling fonts..."
    local font_paths=(
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
        "/usr/share/fonts/dejavu/DejaVuSansMono.ttf"
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
    )
    local font_found=false
    for font_path in "${font_paths[@]}"; do
        if [[ -f "$font_path" ]]; then
            cp "$font_path" "${APPDIR}/usr/share/fonts/truetype/dejavu/"
            log_info "  Bundled DejaVuSansMono.ttf"
            font_found=true
            break
        fi
    done
    if [[ "$font_found" == false ]]; then
        log_warn "  Could not find DejaVuSansMono.ttf - diff rendering may use fallback font"
    fi
    
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

# SSL/TLS configuration for HTTPS
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"

# Font configuration
export FONTCONFIG_PATH="${APPDIR}/usr/share/fonts"

# Desktop integration for XDG portals (file dialogs, URLs, etc.)
# Install .desktop file if not present (enables portal integration)
DESKTOP_FILE="${HOME}/.local/share/applications/jules-linux.desktop"
if [[ ! -f "$DESKTOP_FILE" && -n "$APPIMAGE" ]]; then
    mkdir -p "${HOME}/.local/share/applications"
    # $APPIMAGE is set by AppImage runtime to the actual .AppImage file path
    sed "s|Exec=jules-linux|Exec=\"${APPIMAGE}\"|g" "${APPDIR}/usr/share/applications/jules-linux.desktop" > "$DESKTOP_FILE" 2>/dev/null || true
fi

# Install icons for launcher
if [[ ! -f "${HOME}/.local/share/icons/hicolor/256x256/apps/jules.png" ]]; then
    for size_dir in "${APPDIR}/usr/share/icons/hicolor/"*; do
        size=$(basename "$size_dir")
        mkdir -p "${HOME}/.local/share/icons/hicolor/${size}/apps"
        cp "${size_dir}/apps/jules"* "${HOME}/.local/share/icons/hicolor/${size}/apps/" 2>/dev/null || true
    done
    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
fi

# Tell portal our app ID
export DESKTOP_FILE_HINT="jules-linux"
export GIO_LAUNCHED_DESKTOP_FILE="$DESKTOP_FILE"

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
