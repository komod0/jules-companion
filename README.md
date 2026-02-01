# Jules Companion

Native desktop applications for interacting with the Jules AI coding assistant API.

## Platforms

| Platform | Status | Technology |
|----------|--------|------------|
| **macOS** | Production | Swift, SwiftUI, Metal |
| **Linux** | ~90% Complete | C++20, Qt 6, OpenGL |

---

## Linux Port

Native Qt6/C++/OpenGL application for Linux desktops (X11 and Wayland).

### Features (Implemented)

- **Session Management**: Create, view, and manage coding sessions
- **Real-time Updates**: Live polling for session status and activity updates
- **Diff Viewing**: High-performance OpenGL-accelerated diff visualization
- **Syntax Highlighting**: Tree-sitter powered highlighting for 20 languages
- **GPU Animations**: Boids particle system and Gerstner wave effects
- **System Tray**: Integration with system tray (X11 AppIndicator, Wayland SNI)
- **Global Hotkeys**: Ctrl+Alt+J to toggle window (X11 XGrabKey, Wayland Portal)
- **Dark/Light Theme**: Follows system preference or manual selection

### Building (Linux)

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

### Linux Project Structure

```
src/
├── api/              # Jules API client (Qt Network)
├── data/             # SQLite persistence (Qt Sql)
├── highlighting/     # Tree-sitter syntax highlighting
├── input/            # Global hotkeys (X11/Wayland)
├── rendering/        # OpenGL widgets (diff, boids, wave)
└── ui/               # Qt Widgets UI

shaders/              # GLSL shaders (text, boids, wave)
grammars/             # Tree-sitter grammar .so files
tests/                # Unit tests (Google Test + Qt Test)
```

### Remaining Work (Linux)

- [ ] **Settings Dialog** - API key, theme, hotkey configuration
- [ ] **AppImage Packaging** - Universal Linux distribution

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

### Requirements (macOS)

- macOS 13.0 or later
- Xcode 15.0 or later (for building)
- A Jules API key (obtain from [jules.google.com](https://jules.google.com))

### Building (macOS)

1. Clone the repository:
   ```bash
   git clone https://github.com/simpsoka/jules-osx.git
   cd jules-osx
   ```

2. Open the project in Xcode:
   ```bash
   open jules.xcodeproj
   ```

3. Build and run (Cmd+R)

### Configuration

#### API Key

Enter your Jules API key in the app's Settings to start using the application.

#### Firebase/Gemini (Optional)

The app includes optional Firebase integration for AI-generated activity descriptions using Gemini. This feature is **disabled by default** and the app works perfectly without it.

To enable Firebase/Gemini:

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Add a macOS app with your bundle ID
3. Download `GoogleService-Info.plist` and replace the placeholder file in `jules/`
4. Open `jules/AppDelegate.swift` and set:
   ```swift
   let ENABLE_FIREBASE = true
   ```

### macOS Project Structure

```
jules/
├── AppDelegate.swift       # App lifecycle, menu bar, hotkeys
├── DataManager.swift       # Core data management and API coordination
├── APIService.swift        # REST API client for Jules backend
├── SessionRepository.swift # Session persistence (GRDB/SQLite)
├── Flux/                   # Metal-based diff rendering
├── MergeConflictWindow/    # Merge conflict UI
├── Canvas/                 # Drawing/annotation features
└── ...
```

### Keyboard Shortcuts

Default shortcuts (configurable in Settings):

- **Control+Option+J**: Toggle Jules menu
- **Control+Option+S**: Capture screenshot
- **Control+Option+V**: Voice input (macOS 26.0+)

### macOS Architecture

- **UI Framework**: SwiftUI with AppKit integration
- **Database**: SQLite via GRDB
- **Networking**: URLSession with offline queue support
- **Graphics**: Metal for high-performance diff rendering
- **Updates**: Sparkle framework

### macOS Dependencies

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
