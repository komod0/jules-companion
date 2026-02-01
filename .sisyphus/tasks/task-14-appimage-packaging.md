# Task 14: AppImage Packaging

## Overview

| Field | Value |
|-------|-------|
| **Task ID** | 14 |
| **Title** | AppImage Packaging |
| **Priority** | Medium |
| **Estimated Effort** | 1 day |
| **Dependencies** | Tasks 8, 9, 10, 11, 12, 13 (all complete except 13) |
| **Blocks** | None (final task) |

## Objective

Create an AppImage distribution of Jules Linux that:
- Runs on Ubuntu 22.04+, Fedora 38+, Arch Linux without installation
- Bundles all Qt6 dependencies, plugins, and tree-sitter grammars
- Integrates with desktop environment (icon, .desktop file)
- Is self-contained and portable

## Success Criteria

- [ ] AppImage builds successfully via script
- [ ] Runs on fresh Ubuntu 22.04 VM (no Qt installed)
- [ ] Runs on fresh Fedora 38 VM
- [ ] Runs on fresh Arch Linux VM
- [ ] All features work (hotkeys, OpenGL rendering, syntax highlighting)
- [ ] Desktop integration works (shows in app menu)
- [ ] File size under 100MB

---

## Context from Codebase Analysis

### Current Build Output

| Target | Size | Type |
|--------|------|------|
| `jules-linux` | 9.6 MB | Main executable |
| `opengl_spike` | 2.7 MB | Demo app |

### Runtime Dependencies (ldd analysis)

**Qt6 Libraries:**
- libQt6Core.so.6
- libQt6Gui.so.6
- libQt6Widgets.so.6
- libQt6Network.so.6
- libQt6Sql.so.6
- libQt6OpenGL.so.6
- libQt6OpenGLWidgets.so.6
- libQt6DBus.so.6

**System Libraries:**
- libfreetype.so.6 (font rendering)
- libxcb.so.1, libxcb-keysyms.so.1 (X11)
- libOpenGL.so.0, libGLX.so.0 (OpenGL)
- libdbus-1.so.3 (D-Bus IPC)
- libfontconfig.so.1 (fonts)
- libharfbuzz.so.0 (text shaping)
- libpng16.so.16, libjpeg.so (images)
- libssl.so.3, libcrypto.so.3 (TLS)
- libsqlite3.so.0 (database)

**Qt6 Plugins Required:**
- `platforms/libqxcb.so` (X11 platform)
- `platforms/libqwayland-*.so` (Wayland platform)
- `sqldrivers/libqsqlite.so` (SQLite)
- `imageformats/libqpng.so`, `libqjpeg.so`
- `xcbglintegrations/libqxcb-glx-integration.so` (OpenGL+XCB)
- `platformthemes/libqgtk3.so` (GTK theme)

### Resource Files

**Bundled in Binary (via .qrc):**
- 9 GLSL shaders (text, rect, boids, wave)

**External Files to Bundle:**
- 19 tree-sitter grammar .so files (~27.5 MB total)

### Missing Components

- [ ] No .desktop file
- [ ] No application icon
- [ ] No install() rules in CMakeLists.txt
- [ ] No packaging script

---

## Implementation Plan

### Subtask 14.1: Create Application Icon

**Files:**
- `resources/icons/jules.svg` (scalable)
- `resources/icons/jules-256.png` (256x256)
- `resources/icons/jules-128.png` (128x128)
- `resources/icons/jules-64.png` (64x64)
- `resources/icons/jules-48.png` (48x48)

**Design Spec:**
- Match macOS app icon style if available
- Simple, recognizable at small sizes
- Works on both light and dark backgrounds

**Parallel**: YES - independent

---

### Subtask 14.2: Create Desktop Entry File

**File:** `resources/jules-linux.desktop`

```ini
[Desktop Entry]
Type=Application
Name=Jules
GenericName=AI Coding Assistant
Comment=Native Linux client for Jules AI coding assistant
Exec=jules-linux %F
Icon=jules
Categories=Development;IDE;
Keywords=ai;coding;assistant;development;
Terminal=false
StartupNotify=true
StartupWMClass=jules-linux
MimeType=
```

**Parallel**: YES - independent

---

### Subtask 14.3: Add CMake Install Rules

**File:** `CMakeLists.txt` (modify)

```cmake
# Installation rules
include(GNUInstallDirs)

# Main executable
install(TARGETS jules-linux
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Tree-sitter grammars
install(DIRECTORY ${CMAKE_SOURCE_DIR}/grammars/
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/jules-linux/grammars
    FILES_MATCHING PATTERN "*.so"
)

# Desktop file
install(FILES ${CMAKE_SOURCE_DIR}/resources/jules-linux.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)

# Icons
install(FILES ${CMAKE_SOURCE_DIR}/resources/icons/jules.svg
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
)
install(FILES ${CMAKE_SOURCE_DIR}/resources/icons/jules-256.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/256x256/apps
    RENAME jules.png
)
install(FILES ${CMAKE_SOURCE_DIR}/resources/icons/jules-128.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/128x128/apps
    RENAME jules.png
)
install(FILES ${CMAKE_SOURCE_DIR}/resources/icons/jules-64.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/64x64/apps
    RENAME jules.png
)
install(FILES ${CMAKE_SOURCE_DIR}/resources/icons/jules-48.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/48x48/apps
    RENAME jules.png
)
```

**Parallel**: YES - can be done with 14.1, 14.2

---

### Subtask 14.4: Create AppImage Build Script

**File:** `scripts/build-appimage.sh`

```bash
#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="jules-linux"
APP_DIR="Jules.AppDir"
OUTPUT_NAME="Jules-x86_64.AppImage"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_deps() {
    log_info "Checking dependencies..."
    
    if ! command -v linuxdeploy-x86_64.AppImage &> /dev/null; then
        log_info "Downloading linuxdeploy..."
        wget -q "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
        chmod +x linuxdeploy-x86_64.AppImage
    fi
    
    if ! command -v linuxdeploy-plugin-qt-x86_64.AppImage &> /dev/null; then
        log_info "Downloading linuxdeploy-plugin-qt..."
        wget -q "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
        chmod +x linuxdeploy-plugin-qt-x86_64.AppImage
    fi
}

# Build the application
build_app() {
    log_info "Building application..."
    cd "$PROJECT_ROOT"
    
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build build --parallel $(nproc)
}

# Create AppDir structure
create_appdir() {
    log_info "Creating AppDir structure..."
    
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/usr/bin"
    mkdir -p "$APP_DIR/usr/lib/jules-linux/grammars"
    mkdir -p "$APP_DIR/usr/share/applications"
    mkdir -p "$APP_DIR/usr/share/icons/hicolor/scalable/apps"
    mkdir -p "$APP_DIR/usr/share/icons/hicolor/256x256/apps"
    
    # Copy executable
    cp "$BUILD_DIR/jules-linux" "$APP_DIR/usr/bin/"
    
    # Copy grammars
    cp "$PROJECT_ROOT/grammars/"*.so "$APP_DIR/usr/lib/jules-linux/grammars/" 2>/dev/null || log_warn "No grammar files found"
    
    # Copy desktop file and icon
    cp "$PROJECT_ROOT/resources/jules-linux.desktop" "$APP_DIR/usr/share/applications/"
    cp "$PROJECT_ROOT/resources/icons/jules.svg" "$APP_DIR/usr/share/icons/hicolor/scalable/apps/"
    cp "$PROJECT_ROOT/resources/icons/jules-256.png" "$APP_DIR/usr/share/icons/hicolor/256x256/apps/jules.png" 2>/dev/null || true
    
    # Create symlinks for AppImage
    ln -sf usr/share/applications/jules-linux.desktop "$APP_DIR/jules-linux.desktop"
    ln -sf usr/share/icons/hicolor/scalable/apps/jules.svg "$APP_DIR/jules.svg"
}

# Create AppRun wrapper
create_apprun() {
    log_info "Creating AppRun wrapper..."
    
    cat > "$APP_DIR/AppRun" << 'EOF'
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"

# Set library paths
export LD_LIBRARY_PATH="${APPDIR}/usr/lib:${APPDIR}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"

# Set Qt plugin path
export QT_PLUGIN_PATH="${APPDIR}/usr/plugins"

# Set tree-sitter grammar path
export TREE_SITTER_GRAMMAR_PATH="${APPDIR}/usr/lib/jules-linux/grammars"

# Set XDG paths for data storage
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Launch application
exec "${APPDIR}/usr/bin/jules-linux" "$@"
EOF
    chmod +x "$APP_DIR/AppRun"
}

# Bundle dependencies with linuxdeploy
bundle_deps() {
    log_info "Bundling dependencies with linuxdeploy..."
    
    export QMAKE=$(which qmake6 || which qmake)
    export EXTRA_QT_PLUGINS="sqldrivers;iconengines;platformthemes"
    export EXTRA_PLATFORM_PLUGINS="libqxcb.so"
    
    ./linuxdeploy-x86_64.AppImage \
        --appdir "$APP_DIR" \
        --plugin qt \
        --desktop-file "$APP_DIR/usr/share/applications/jules-linux.desktop" \
        --icon-file "$APP_DIR/usr/share/icons/hicolor/scalable/apps/jules.svg"
}

# Create final AppImage
create_appimage() {
    log_info "Creating AppImage..."
    
    ./linuxdeploy-x86_64.AppImage \
        --appdir "$APP_DIR" \
        --output appimage
    
    # Rename to final name
    mv Jules*.AppImage "$OUTPUT_NAME" 2>/dev/null || true
    
    log_info "AppImage created: $OUTPUT_NAME"
    ls -lh "$OUTPUT_NAME"
}

# Main
main() {
    cd "$PROJECT_ROOT"
    
    check_deps
    build_app
    create_appdir
    create_apprun
    bundle_deps
    create_appimage
    
    log_info "Build complete!"
    log_info "Test with: ./$OUTPUT_NAME"
}

main "$@"
```

**Parallel**: NO - depends on 14.1, 14.2, 14.3

---

### Subtask 14.5: Update Syntax Highlighter for Grammar Path

**File:** `src/highlighting/syntax_highlighter.cpp` (modify)

Ensure grammar loading respects `TREE_SITTER_GRAMMAR_PATH` environment variable:

```cpp
QString SyntaxHighlighter::grammarPath() {
    // Check environment variable first (for AppImage)
    QString envPath = qEnvironmentVariable("TREE_SITTER_GRAMMAR_PATH");
    if (!envPath.isEmpty() && QDir(envPath).exists()) {
        return envPath;
    }
    
    // Check relative to executable
    QString exePath = QCoreApplication::applicationDirPath();
    QString relativePath = exePath + "/../lib/jules-linux/grammars";
    if (QDir(relativePath).exists()) {
        return QDir(relativePath).canonicalPath();
    }
    
    // Fallback to build directory
    return QStringLiteral("./grammars");
}
```

**Parallel**: YES - independent

---

### Subtask 14.6: Create GitHub Actions CI for AppImage

**File:** `.github/workflows/appimage.yml`

```yaml
name: Build AppImage

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-22.04
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            cmake ninja-build \
            qt6-base-dev qt6-tools-dev libqt6opengl6-dev \
            libfreetype-dev libxcb-keysyms1-dev \
            libfuse2
      
      - name: Build grammars
        run: ./scripts/build_grammars.sh
      
      - name: Build AppImage
        run: ./scripts/build-appimage.sh
      
      - name: Test AppImage
        run: |
          chmod +x Jules-x86_64.AppImage
          ./Jules-x86_64.AppImage --version || true
      
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: jules-linux-appimage
          path: Jules-x86_64.AppImage
      
      - name: Create Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v1
        with:
          files: Jules-x86_64.AppImage
```

**Parallel**: YES - can be done with 14.4, 14.5

---

### Subtask 14.7: Testing on Multiple Distros

**Manual verification steps:**

1. **Ubuntu 22.04 (fresh VM)**
   ```bash
   # No Qt installed
   wget https://github.com/.../Jules-x86_64.AppImage
   chmod +x Jules-x86_64.AppImage
   ./Jules-x86_64.AppImage
   ```
   Verify: App launches, hotkeys work, syntax highlighting works

2. **Fedora 38 (fresh VM)**
   ```bash
   # Minimal install
   ./Jules-x86_64.AppImage
   ```
   Verify: Same checks

3. **Arch Linux (fresh VM)**
   ```bash
   ./Jules-x86_64.AppImage
   ```
   Verify: Same checks

**Test Checklist:**
- [ ] App launches without errors
- [ ] Main window displays correctly
- [ ] System tray icon appears
- [ ] Global hotkey (Ctrl+Alt+J) works
- [ ] OpenGL rendering works (wave/boids animations)
- [ ] Syntax highlighting works for Python, JS, Rust
- [ ] Settings persist after restart
- [ ] Desktop integration (shows in app menu after extraction)

**Parallel**: NO - depends on 14.4

---

## Dependency Graph

```
14.1 (Icon) ─────────────┐
14.2 (Desktop file) ─────┼──→ 14.4 (Build script) ──→ 14.7 (Testing)
14.3 (CMake install) ────┘           ↑
14.5 (Grammar path) ─────────────────┘
14.6 (CI) ───────────────────────────→ (parallel with 14.7)
```

## Parallel Execution Plan

| Wave | Tasks | Can Parallelize |
|------|-------|-----------------|
| Wave A | 14.1 (Icon), 14.2 (Desktop), 14.3 (CMake), 14.5 (Grammar path) | YES |
| Wave B | 14.4 (Build script), 14.6 (CI) | After Wave A |
| Wave C | 14.7 (Testing) | After Wave B |

---

## Agent Assignment Recommendations

| Subtask | Category | Skills | Reason |
|---------|----------|--------|--------|
| 14.1 | `artistry` | `["frontend-ui-ux"]` | Icon design |
| 14.2 | `quick` | `[]` | Simple config file |
| 14.3 | `quick` | `[]` | Standard CMake patterns |
| 14.4 | `unspecified-high` | `[]` | Complex shell scripting |
| 14.5 | `quick` | `[]` | Minor code change |
| 14.6 | `quick` | `["git-master"]` | CI/CD setup |
| 14.7 | Manual | - | Requires VMs |

---

## Files to Create

| File | Purpose |
|------|---------|
| `resources/icons/jules.svg` | Scalable app icon |
| `resources/icons/jules-256.png` | High-res icon |
| `resources/icons/jules-128.png` | Medium-res icon |
| `resources/icons/jules-64.png` | Small icon |
| `resources/icons/jules-48.png` | Tiny icon |
| `resources/jules-linux.desktop` | Desktop entry |
| `scripts/build-appimage.sh` | Build script |
| `.github/workflows/appimage.yml` | CI workflow |

## Files to Modify

| File | Changes |
|------|---------|
| `CMakeLists.txt` | Add install() rules |
| `src/highlighting/syntax_highlighter.cpp` | Grammar path from env |

---

## Verification Checklist

- [ ] `./scripts/build-appimage.sh` completes without errors
- [ ] `Jules-x86_64.AppImage` file created
- [ ] File size < 100MB
- [ ] Runs on Ubuntu 22.04 fresh install
- [ ] Runs on Fedora 38 fresh install
- [ ] Runs on Arch Linux fresh install
- [ ] OpenGL rendering works
- [ ] Syntax highlighting works
- [ ] Hotkeys work on X11
- [ ] Settings persist correctly
- [ ] Desktop integration works
