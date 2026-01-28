# Architectural Decisions - Jules Linux Port

## Technology Stack
- **Language**: C++ (best performance, proper Qt integration)
- **UI Framework**: Qt 6 (native)
- **GPU API**: OpenGL 4.3+ (compute shaders for Boids)
- **Text Rendering**: Grayscale anti-aliasing (not subpixel)
- **Desktop Sessions**: Both X11 AND Wayland from day one
- **Syntax Highlighting**: Top 20 languages for MVP
- **Testing**: TDD with Qt Test + Google Test
- **Distribution**: AppImage (Flatpak in v1.1)

## Scope Decisions
- **IN**: Session management, GPU diff rendering, Boids + waves, system tray, global hotkeys
- **OUT**: Merge conflicts (v2), offline sync (v2), voice input (v2), screenshot capture (v2)

(Subagents will append decisions here)
