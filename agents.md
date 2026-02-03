# Project Agent Profiles

This document defines the AI agent profiles used for the Jules Companion Linux Port project.

## Project Status: COMPLETE (2026-02-03)

All 14 tasks completed. Linux port is feature-complete with:
- Session management with real-time polling
- GPU-accelerated diff rendering with syntax highlighting
- Boids particle animation and Gerstner wave effects
- System tray integration (X11/Wayland)
- Global hotkeys (X11 XGrabKey, Wayland Portal)
- Settings dialog with theme, notifications, font size
- AppImage packaging with CI/CD

## Profiles Used

### Ultrabrain
**Specialization**: High-complexity engineering, GPU programming, mathematical algorithms.
**Used For**:
- OpenGL Rendering Spike (Task 2)
- Full Diff Renderer (Task 10)
- Boids Particle Animation (Task 11)
- Wave Background Animation (Task 12)

### Visual Engineering
**Specialization**: UI/UX implementation, layout, theming, visual polish.
**Used For**:
- Core UI Shell (Task 6)
- Settings Dialog UI (Task 13.3)

### Quick
**Specialization**: Rapid execution of standard, well-documented tasks.
**Used For**:
- Project Setup (Task 0, 1)
- Desktop Entry, CMake Install Rules (Task 14.2, 14.3)
- GitHub Actions CI (Task 14.6)

### Unspecified-High
**Specialization**: Complex logic, state management, system integration.
**Used For**:
- API Client Module (Task 3)
- Data Layer / SQLite (Task 4)
- Tree-sitter Integration (Task 5)
- Session Management UI (Task 7)
- System Tray Integration (Task 8)
- Global Hotkeys (Task 9)
- AppImage Build Script (Task 14.4)

### Unspecified-Low
**Specialization**: Standard, low-risk implementation tasks.
**Used For**:
- Settings Manager (Task 13.1)
- Secure Storage (Task 13.2)
- Settings Integration (Task 13.5)

## Skills Used

### `git-master`
- **Description**: Expertise in git operations, conventional commits, and repository management.
- **Application**: Applied to infrastructure and CI/CD tasks for clean commit history.

### `frontend-ui-ux`
- **Description**: Understanding of visual design, user experience patterns, and rendering quality.
- **Application**: Applied to UI, animation, and rendering tasks for visual fidelity.

## Repository Structure (Post-Reorganization)

```
jules-companion/
├── src/                  # Linux port C++ source
├── include/              # Linux port C++ headers
├── shaders/              # GLSL shaders
├── grammars/             # Tree-sitter grammars
├── tests/                # Unit tests (13 test files)
├── scripts/              # Build scripts
├── resources/            # Icons, desktop file
├── .github/workflows/    # CI/CD
├── macos/                # Original macOS app (archived)
│   ├── jules/            # Swift source
│   ├── jules.xcodeproj/  # Xcode project
│   └── Package.swift     # SPM manifest
├── docs/                 # Architecture docs
└── .sisyphus/            # Planning docs (archived)
```
