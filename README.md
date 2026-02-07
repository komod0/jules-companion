# Jules Companion for Linux

Native Qt6 desktop client for the [Jules](https://jules.google.com) AI coding assistant. Built with C++20, Qt 6, and OpenGL 4.3 for high-performance diff visualization and a polished desktop experience on Linux.

> Forked from the original macOS SwiftUI application by [FUN RUN, LLC](https://github.com/funrun). The macOS source is preserved in the `macos/` directory for reference.

## Features

- **Session Management** -- Create, browse, and manage coding sessions with real-time status polling
- **OpenGL Diff Rendering** -- GPU-accelerated diff viewer with character-level inline highlighting, syntax coloring (19 languages via tree-sitter), and text selection/copy
- **System Tray** -- Animated tray icon with colored status indicators, context menu, and popup panel (X11 AppIndicator / Wayland SNI)
- **Global Hotkeys** -- Ctrl+Alt+J to toggle the window (X11 XGrabKey / Wayland xdg-desktop-portal)
- **Dark and Light Themes** -- Follows system preference or manual selection; all UI components adapt live
- **Offline Support** -- Queue sessions while offline, auto-sync with exponential backoff when connectivity returns
- **Notifications** -- Desktop notifications for session state changes (D-Bus org.freedesktop.Notifications)
- **GPU Animations** -- Boids particle system and Gerstner wave effects using compute shaders
- **AppImage Distribution** -- Single-file portable packaging for any Linux distro

## Building

### Prerequisites

| Dependency | Version |
|---|---|
| CMake | 3.24+ |
| Qt 6 | 6.4+ (Core, Gui, Widgets, Network, Sql, OpenGL, OpenGLWidgets, DBus) |
| FreeType | 2.x |
| XCB + xcb-keysyms | Any (optional, for X11 global hotkeys) |
| OpenGL | 4.3+ capable GPU |
| C++ Compiler | GCC 12+ or Clang 15+ (C++20) |

### Install Dependencies

```bash
# Ubuntu / Debian
sudo apt install cmake qt6-base-dev qt6-tools-dev libqt6opengl6-dev \
                 libfreetype-dev libxcb-keysyms1-dev

# Fedora
sudo dnf install cmake qt6-qtbase-devel qt6-qttools-devel \
                 freetype-devel libxcb-devel xcb-util-keysyms-devel

# Arch Linux
sudo pacman -S cmake qt6-base qt6-tools freetype2 xcb-util-keysyms
```

### Compile

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

### Run

```bash
./build/jules-linux
```

### Run Tests

```bash
cd build && ctest --output-on-failure
```

## Distribution

### AppImage (Recommended)

```bash
./scripts/build-appimage.sh
./Jules-x86_64.AppImage
```

### Local Install

```bash
./scripts/install-local.sh
```

Installs the binary, desktop entry, and icons to `~/.local/`.

### System Install

```bash
cmake --install build --prefix /usr/local
```

Installs the binary, desktop entry, icons, and tree-sitter grammars to standard FreeDesktop locations.

Tested on: Ubuntu 22.04+, Fedora 38+, Arch Linux.

## Configuration

On first launch, open **Settings** (system tray right-click or toolbar button) and enter your Jules API key. Alternatively, set the `JULES_API_KEY` environment variable.

Settings are stored in `~/.config/jules-linux/` via `QSettings`.

## Project Structure

```
jules-companion/
├── src/                    C++ source files
│   ├── api/                Jules REST API client (Qt Network)
│   ├── data/               SQLite persistence, network monitor, offline sync
│   ├── highlighting/       Tree-sitter syntax highlighting
│   ├── input/              Global hotkeys (X11 / Wayland)
│   ├── rendering/          OpenGL diff renderer, boids, wave, font atlas
│   └── ui/                 Qt Widgets (main window, dialogs, tray, panels)
├── include/                C++ headers (mirrors src/ layout)
├── shaders/                GLSL shaders (text, boids, wave, compute)
├── grammars/               Tree-sitter grammar shared libraries (.so)
├── tests/                  Unit tests (Google Test + Qt Test)
├── scripts/                Build and packaging scripts
├── resources/              Icons, desktop entry, Qt resources
├── docs/                   Architecture and development documentation
└── macos/                  Original macOS app (Swift/SwiftUI/Metal) -- reference only
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a detailed breakdown of the module architecture, dependency graph, and rendering pipeline.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Ctrl+Alt+J | Toggle window (global hotkey, configurable) |
| Ctrl+N | New session |
| Ctrl+R | Refresh sessions |
| Ctrl+F | Search sessions |
| Ctrl+C | Copy selected diff text |
| Up/Down | Navigate session list |

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for build setup, code style, and pull request guidelines.

## License

MIT License -- see [LICENSE](LICENSE) for details.

## Acknowledgments

- Original macOS application by [FUN RUN, LLC](https://github.com/funrun)
- [Qt](https://www.qt.io/) -- cross-platform application framework
- [tree-sitter](https://tree-sitter.github.io/) -- incremental parsing for syntax highlighting
- [FreeType](https://freetype.org/) -- font rendering for the OpenGL text pipeline
- "Jules" name and branding are trademarks of Alphabet Inc.
