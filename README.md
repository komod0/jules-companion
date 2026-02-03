# Jules Companion

Native desktop applications for interacting with the Jules AI coding assistant API.

## Platforms

| Platform | Status | Technology | Directory |
|----------|--------|------------|-----------|
| **Linux** | **Complete** | C++20, Qt 6, OpenGL | `src/`, `include/` |
| **macOS** | Production | Swift, SwiftUI, Metal | `macos/` |

---

## Linux Port (Complete)

Native Qt6/C++/OpenGL application for Linux desktops (X11 and Wayland).

### Features

- **Session Management**: Create, view, and manage coding sessions
- **Real-time Updates**: Live polling for session status and activity updates  
- **Diff Viewing**: High-performance OpenGL-accelerated diff visualization
- **Syntax Highlighting**: Tree-sitter powered highlighting for 20 languages
- **GPU Animations**: Boids particle system and Gerstner wave effects
- **System Tray**: Integration with system tray (X11 AppIndicator, Wayland SNI)
- **Global Hotkeys**: Ctrl+Alt+J to toggle window (X11 XGrabKey, Wayland Portal)
- **Dark/Light Theme**: Follows system preference or manual selection
- **Settings Dialog**: API key, theme, notifications, font size configuration
- **AppImage Packaging**: Universal Linux distribution with CI/CD

### Building

**Requirements:**
- CMake 3.24+
- Qt 6.4+ (Core, Gui, Widgets, Network, Sql, OpenGL, OpenGLWidgets, DBus)
- FreeType 2
- XCB + xcb-keysyms (for X11 hotkeys)
- OpenGL 4.3+ capable GPU (for compute shaders)

**Build:**
```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install cmake qt6-base-dev qt6-tools-dev libqt6opengl6-dev \
                 libfreetype-dev libxcb-keysyms1-dev

# Build
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel

# Run tests
cd build && ctest --output-on-failure

# Run application
./build/jules-linux
```

### Project Structure

```
jules-companion/
├── src/                  # C++ source files (Linux port)
│   ├── api/              # Jules API client (Qt Network)
│   ├── data/             # SQLite persistence (Qt Sql)
│   ├── highlighting/     # Tree-sitter syntax highlighting
│   ├── input/            # Global hotkeys (X11/Wayland)
│   ├── rendering/        # OpenGL widgets (diff, boids, wave)
│   └── ui/               # Qt Widgets UI
├── include/              # C++ headers
├── shaders/              # GLSL shaders (text, boids, wave)
├── grammars/             # Tree-sitter grammar .so files
├── tests/                # Unit tests (Google Test + Qt Test)
├── scripts/              # Build scripts (AppImage)
├── resources/            # Icons, desktop file
├── .github/workflows/    # CI/CD (AppImage builds)
├── macos/                # Original macOS app (Swift/SwiftUI/Metal)
│   ├── jules/            # Swift source files
│   ├── jules.xcodeproj/  # Xcode project
│   └── Package.swift     # Swift Package Manager
└── docs/                 # Architecture documentation
```

### Distribution

**AppImage (Recommended):**
```bash
# Build AppImage
./scripts/build-appimage.sh

# Run
./Jules-x86_64.AppImage
```

Tested on: Ubuntu 22.04, Fedora 38, Arch Linux

---

## macOS

<img width="2416" height="1616" alt="jules-desktop" src="https://github.com/user-attachments/assets/b73d897e-845b-4aba-9a2e-7b268a8134d1" />

Native SwiftUI menu bar application with Metal-accelerated rendering.

### Features

- **Menu Bar Integration**: Quick access from your menu bar or centered floating panel
- **Session Management**: Create, view, and manage coding sessions
- **Real-time Updates**: Live polling for session status and activity updates
- **Diff Viewing**: High-performance Metal-accelerated diff visualization
- **Merge Conflict Resolution**: Visual merge conflict handling
- **Offline Support**: Queue sessions when offline, sync when connectivity returns
- **Keyboard Shortcuts**: Global hotkeys for quick access
- **Auto-updates**: Built-in update mechanism via Sparkle

### Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)
- A Jules API key (obtain from [jules.google.com](https://jules.google.com))

### Building

```bash
cd macos
open jules.xcodeproj
# Build and run (Cmd+R)
```

### Project Structure (macOS)

```
macos/
├── jules/
│   ├── AppDelegate.swift       # App lifecycle, menu bar, hotkeys
│   ├── DataManager.swift       # Core data management and API coordination
│   ├── APIService.swift        # REST API client for Jules backend
│   ├── SessionRepository.swift # Session persistence (GRDB/SQLite)
│   ├── Flux/                   # Metal-based diff rendering
│   ├── MergeConflictWindow/    # Merge conflict UI
│   ├── Canvas/                 # Drawing/annotation features
│   └── ...
├── jules.xcodeproj/            # Xcode project
└── Package.swift               # Swift Package Manager
```

### Keyboard Shortcuts

Default shortcuts (configurable in Settings):

- **Control+Option+J**: Toggle Jules menu
- **Control+Option+S**: Capture screenshot
- **Control+Option+V**: Voice input (macOS 26.0+)

### Dependencies

- [GRDB](https://github.com/groue/GRDB.swift) - SQLite toolkit
- [Sparkle](https://github.com/sparkle-project/Sparkle) - Auto-updates
- [HotKey](https://github.com/soffes/HotKey) - Global keyboard shortcuts
- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) - Syntax parsing
- [Lottie](https://github.com/airbnb/lottie-ios) - Animations
- [Firebase iOS SDK](https://github.com/firebase/firebase-ios-sdk) - Optional AI features

---

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Trademarks

"Jules" name, logo, and branding are trademarks of Alphabet Inc. and are used with permission.
