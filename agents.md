# Project Agent Profiles

This document defines the AI agent profiles recommended for different tasks in the Jules Companion Linux Port project.

## Profiles

### Ultrabrain
**Specialization**: High-complexity engineering, GPU programming, mathematical algorithms.
**Used For**:
- OpenGL Rendering Spike
- Full Diff Renderer (Performance critical)
- Boids Particle Animation (Compute shaders)
- Wave Background Animation (Gerstner waves)

### Visual Engineering
**Specialization**: UI/UX implementation, layout, theming, visual polish.
**Used For**:
- Core UI Shell (Main window, layouts)
- Visual consistency across platforms

### Quick
**Specialization**: Rapid execution of standard, well-documented tasks.
**Used For**:
- Project Setup (CMake, CI)
- Qt 6 Project Skeleton

### Unspecified-High
**Specialization**: Complex logic, state management, system integration.
**Used For**:
- API Client Module
- Data Layer (SQLite)
- Tree-sitter Integration
- Session Management UI
- System Tray Integration
- Global Hotkeys (X11/Wayland)

### Unspecified-Low
**Specialization**: Standard, low-risk implementation tasks.
**Used For**:
- Settings & Persistence
- AppImage Packaging

## Skills

### `git-master`
- **Description**: Expertise in git operations, conventional commits, and repository management.
- **Application**: Applied to infrastructure and backend tasks to ensure clean history.

### `frontend-ui-ux`
- **Description**: Understanding of visual design, user experience patterns, and rendering quality.
- **Application**: Applied to UI, animation, and rendering tasks to ensure visual fidelity.
