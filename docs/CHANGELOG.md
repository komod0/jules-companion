# Changelog

All notable changes to the Linux port of Jules Companion.

## [Unreleased]

### Added
- `.clang-format` configuration matching the project code style
- Binary file indicators in diff renderer (placeholder instead of garbled output)
- New test suites: settings dialog, diff panel widget, diff precomputation, diffs database, feedback dialog, filename autocomplete, flash message, merge conflict dialog, network monitor, notification manager, offline sync, shared syntax cache, tray popup widget, update checker
- Comprehensive architecture documentation (`docs/ARCHITECTURE.md`)

### Fixed
- Diff panel loading animation now shows for all sessions pending activities, not just active ones (added `activitiesFetched` flag to Session)
- Diff panel underwater animation deferred until OpenGL context is initialized, preventing silent frame drops when `setLoading(true)` is called before `initializeGL()`
- Tray popup positioning on Linux: detect panel edge from available vs full screen geometry instead of relying on `QCursor::pos()` when `QSystemTrayIcon::geometry()` returns `(0,0,0,0)`
- Tray popup right-aligns when icon is on right half of screen

### Changed
- Chat bubble text wrapping on resize: replaced `QListWidget` with `QVBoxLayout` for proper reflow
- Scroll-to-bottom fix: activity feed now reliably scrolls to the latest message
- Theme live switching: all widgets respond immediately when theme changes, no restart needed
- Replaced `std::regex` with manual string parsing in diff renderer for improved performance
- Launcher icon fix: icons installed to correct XDG paths for desktop environment integration
- README rewritten with prerequisites table, local install instructions, and updated feature list
- Architecture document expanded with full module details, rendering pipeline, and database schema
- CONTRIBUTING.md updated with current test count and conventions

### Removed
- Outdated feature parity report (all features now implemented)
- macOS Metal architecture document (not relevant to Linux build)
- Completed planning artifacts (`.sisyphus/`, `agents.md`)

## [1.0.0] -- 2026-02-04

### Added
- Complete Linux port of Jules Companion
- Session management with create, list, and detail views
- Real-time session polling with configurable interval
- OpenGL 4.3 diff renderer with syntax highlighting (19 languages via tree-sitter)
- Character-level inline diff highlighting with prefix/suffix matching
- Text selection and Ctrl+C copy in diff viewer
- FreeType-based font atlas for GPU text rendering
- Boids particle animation (compute shader)
- Gerstner wave background animation (compute shader)
- System tray integration (X11 AppIndicator / Wayland SNI)
- Animated tray icons (loading bounce, running loop with 6-frame interpolation)
- Colored tray icon status dots (error, attention, paused, failed) via QPainter overlay
- Global hotkeys (X11 XGrabKey / Wayland xdg-desktop-portal)
- Dark and light theme support with system preference detection
- Settings dialog: API key, theme, font size, hotkeys, notifications, repo folders
- SQLite persistence with WAL mode and migration system (v1-v3)
- Separate diffs database for patch storage
- NetworkMonitor with connectivity change detection
- OfflineSyncManager with pending session queue and exponential backoff
- SharedSyntaxCache (LRU, 5K entries, thread-safe with shared_mutex)
- DiffPrecomputationService (background thread pool)
- FilenameAutocompleteManager with filesystem watcher and SQLite cache
- Hash-based API response caching (MD5)
- Rate limiter for API requests (token-bucket)
- Notification manager (D-Bus org.freedesktop.Notifications)
- Plan approval and feedback action buttons in session detail
- Markdown rendering in activity feed: headers, lists, blockquotes, links, horizontal rules
- Vertical splitter layout for session detail (activity feed / diff panel)
- Close-to-tray behavior when system tray is available
- Context menus on session list (Copy Session ID, Open in Browser)
- Keyboard shortcuts: Ctrl+N (new), Ctrl+R (refresh), Ctrl+F (search)
- Session state indicator colors matching Jules conventions
- Merge conflict dialog
- Update checker
- Feedback dialog
- Tray popup widget with quick session creation
- AppImage packaging with build script
- Local install script (`scripts/install-local.sh`)
- Desktop entry and icon installation (FreeDesktop)
- CMake install rules with GNUInstallDirs
- 31 test suites (Google Test + Qt Test)
- CI/CD: GitHub Actions for Ubuntu, Fedora, Arch Linux

## [0.1.0] -- 2026-01-28

### Added
- Initial project scaffold with CMake and Qt 6
- Minimal QMainWindow with split-pane layout
- Google Test integration
- GitHub Actions CI for multi-distro builds
