# Architecture

This document describes the internal architecture of Jules Companion for Linux.

## Overview

Jules Companion is a Qt 6 Widgets desktop application written in C++20. It is a Linux port of the original macOS SwiftUI application. The app monitors and manages [Jules](https://jules.google.com) AI coding sessions, providing a native desktop experience with real-time status polling, GPU-accelerated diff visualization, and system tray integration.

The application communicates with the Jules REST API, persists data in SQLite, and renders diffs using a custom OpenGL 4.3 instanced rendering pipeline. All application code lives in the `jules` namespace (except `SettingsManager`, which is in the global namespace for `QSettings` compatibility).

## Directory Structure

```
jules-companion/
├── src/                    Source files organized by module
│   ├── api/                Jules REST API client
│   ├── data/               SQLite persistence, repositories, network, offline sync
│   ├── highlighting/       Tree-sitter syntax highlighting
│   ├── input/              Global hotkeys (X11 / Wayland)
│   ├── rendering/          OpenGL diff renderer, boids, wave, font atlas
│   └── ui/                 Qt Widgets (main window, dialogs, tray, panels)
├── include/                Public headers (mirrors src/ layout)
│   ├── api/
│   ├── data/
│   ├── highlighting/
│   ├── input/
│   ├── rendering/
│   └── ui/
├── tests/                  Unit tests (Google Test + Qt Test)
├── shaders/                GLSL shaders (text, boids, wave, compute)
├── grammars/               Tree-sitter grammar shared libraries (.so)
├── resources/              Icons, desktop entry, Qt resource files (.qrc)
├── scripts/                Build and packaging scripts
├── docs/                   Architecture and development documentation
└── macos/                  Original macOS app (Swift/SwiftUI/Metal) for reference
```

## Build System

The project uses CMake (3.24+) with six static library targets plus the main executable:

```
jules-linux (executable)
├── jules_api          REST API client, rate limiting, response caching
├── jules_data         SQLite database, session repository, network monitor, offline sync
├── jules_highlighting Tree-sitter syntax highlighting (19 languages)
├── jules_input        Global hotkeys (X11 XGrabKey / Wayland xdg-desktop-portal)
├── jules_rendering    OpenGL diff renderer, boids, wave, font atlas, syntax cache
└── jules_ui           Qt Widgets (main window, session list/detail, dialogs, tray)
```

External dependencies are fetched at configure time via `FetchContent`:
- **tree-sitter** v0.26.5 -- incremental parsing library for syntax highlighting
- **Google Test** -- unit testing framework (fetched in `tests/CMakeLists.txt`)

System dependencies:
- Qt 6.4+ (Core, Gui, Widgets, Network, Sql, OpenGL, OpenGLWidgets, DBus, Test)
- FreeType 2 (font rendering for the OpenGL text pipeline)
- XCB + xcb-keysyms (optional, for X11 global hotkeys)
- OpenGL 4.3+ capable GPU

### Dependency Graph

```
jules_ui ──────► jules_rendering ──► jules_highlighting ──► tree-sitter-lib
    │                │
    ▼                ▼
jules_data ◄───► jules_api
    │
    ▼
jules_input
```

### Installation

CMake install rules use `GNUInstallDirs` to place the binary, desktop entry, icons, and tree-sitter grammars in standard FreeDesktop locations. An AppImage build script (`scripts/build-appimage.sh`) produces a single-file portable package.

## Module Details

### jules_api

**Files:** `src/api/jules_api_client.cpp`, `include/api/jules_api_client.h`

The API client wraps the Jules REST API using `QNetworkAccessManager`. It provides session CRUD, activity fetching, and source listing.

Key features:
- **Rate limiter** -- Token-bucket algorithm to stay within API quotas.
- **Retry with exponential backoff** -- Automatic retry on HTTP 429 and 5xx responses.
- **Hash-based caching** -- MD5 hash comparison on activity and session responses. When the hash matches the previous response, the client emits `activitiesUnchanged()` or `sessionsUnchanged()` instead of re-parsing the JSON. This eliminates redundant work during polling.
- **Gemini summaries** -- Optional AI-generated session summaries (opt-in via settings).

Signals: `sessionsReceived`, `sessionReceived`, `activitiesReceived`, `activitiesUnchanged`, `sessionsUnchanged`, `sessionCreated`, `errorOccurred`.

### jules_data

**Files:** `src/data/database.cpp`, `session_repository.cpp`, `settings_manager.cpp`, `network_monitor.cpp`, `offline_sync_manager.cpp`, `diffs_database.cpp`, `filename_autocomplete_manager.cpp`

The data layer handles all persistence, settings, and network state.

- **Database** -- SQLite with WAL mode for concurrent read access. Migration system via `runMigration(version)` switch statement (currently at v3). Tables: `sessions`, `activities`, `pending_sessions`, `filename_cache`.

- **SessionRepository** -- CRUD operations for sessions and activities with signal-based change notification (`sessionsReloaded`, `sessionChanged`). Used by both the API response handlers and the UI layer.

- **DiffsDatabase** -- Separate SQLite database (`diffs.db`) for diff/patch storage, keeping the main database lean and fast for session queries.

- **NetworkMonitor** -- Uses `QNetworkInformation` with a periodic probe fallback. Emits `connectivityRestored()` on offline-to-online transitions, triggering the offline sync manager.

- **OfflineSyncManager** -- Queues session creation requests when offline. When connectivity returns, syncs with exponential backoff to avoid overwhelming the API.

- **FilenameAutocompleteManager** -- `QFileSystemWatcher`-based file indexing with SQLite cache. Provides debounced prefix-matching autocomplete for the new session dialog.

- **SettingsManager** -- Singleton wrapping `QSettings`. Stores API key, theme preference, font size, hotkey bindings, notification preferences, and repository folders. Emits signals on change (`apiKeyChanged`, `themeChanged`, `repositoryFoldersChanged`).

### jules_highlighting

**Files:** `src/highlighting/syntax_highlighter.cpp`, `include/highlighting/syntax_highlighter.h`

PImpl-based wrapper around tree-sitter. Loads language grammar shared libraries (`.so`) from the `grammars/` directory at runtime using `dlopen`.

Supported languages (19): C, C++, Python, JavaScript, TypeScript, Go, Rust, Java, Ruby, PHP, C#, Swift, Kotlin, Lua, Bash, CSS, HTML, JSON, YAML.

Returns a list of `SyntaxSpan` structs (start offset, length, color) for a given source string and language identifier.

### jules_input

**Files:** `src/input/global_hotkey.cpp`, `include/input/global_hotkey.h`

Cross-session global hotkey registration with automatic platform detection via `QGuiApplication::platformName()`:

- **X11** -- `xcb_grab_key` with a native X11 event filter installed on `QGuiApplication`.
- **Wayland** -- `org.freedesktop.portal.GlobalShortcuts` D-Bus interface via the XDG Desktop Portal.

The default hotkey is Ctrl+Alt+J (configurable in settings). Emits `toggleWindowActivated()`.

### jules_rendering

**Files:** `src/rendering/diff_renderer.cpp`, `font_atlas.cpp`, `opengl_widget.cpp`, `boids_widget.cpp`, `wave_widget.cpp`, `shared_syntax_cache.cpp`, `diff_precomputation_service.cpp`

The rendering module provides GPU-accelerated visualization.

#### DiffRenderer (PImpl)

The core rendering engine. Parses unified diff patches, lays out lines with gutter and line numbers, applies syntax highlighting, and renders via instanced OpenGL 4.3 draw calls.

Features:
- **Character-level inline diff highlighting** -- Prefix/suffix matching on adjacent `+`/`-` lines to highlight exactly which characters changed within a line.
- **Binary search for syntax color lookup** -- Efficient mapping from character offset to syntax highlight color.
- **Viewport cache with integer pixel snapping** -- Avoids re-generating render data when the viewport hasn't moved significantly.
- **Dark/light color palettes** -- `setDarkMode(bool)` switches between two complete color sets.
- **Binary file detection** -- Shows a placeholder indicator instead of attempting to render binary content.
- **Text selection** -- Tracks selection range for mouse-based text selection in `DiffPanelWidget`.

#### FontAtlas

FreeType-based glyph atlas packed into an OpenGL texture. Covers the ASCII printable range (32-126) with configurable font size. Used by `DiffRenderer` for all text rendering.

#### SharedSyntaxCache

Thread-safe LRU cache (5,000 entries) for parsed syntax highlighting results. Key = `{content_hash, language, is_dark_mode}`. Uses `std::shared_mutex` for concurrent read access from the diff precomputation thread pool.

#### DiffPrecomputationService

Background thread pool (`QThreadPool`) that pre-parses diffs when sessions are loaded. Caches results for up to 10 sessions x 100 diffs. Emits `precomputationComplete(sessionId)` when all diffs for a session are ready.

#### BoidsWidget / WaveWidget

OpenGL compute shader animations for splash and background areas:
- **BoidsWidget** -- Craig Reynolds flocking simulation with separation, alignment, and cohesion forces.
- **WaveWidget** -- Gerstner wave simulation with multiple wave components and configurable parameters.

### jules_ui

**Files:** `src/ui/main_window.cpp`, `session_list_widget.cpp`, `session_detail_widget.cpp`, `new_session_dialog.cpp`, `settings_dialog.cpp`, `system_tray.cpp`, `diff_panel_widget.cpp`, `tray_popup_widget.cpp`, `feedback_dialog.cpp`, and supporting widgets.

The UI module contains all Qt widgets.

- **MainWindow** -- Split-pane layout (session list | session detail). Manages theme detection (`QPalette::window().color().lightness() < 128`), close-to-tray behavior, window state persistence, and keyboard shortcuts (Ctrl+N, Ctrl+R, Ctrl+F).

- **SessionListWidget** -- Grouped session list (Today / This Week / Older) with search field, keyboard navigation (skips group headers), context menus (Copy Session ID, Open in Browser), and colored state indicators matching Jules conventions.

- **SessionDetailWidget** -- Activity feed with rich markdown rendering (headers, lists, blockquotes, links, horizontal rules). Includes plan approval and feedback action buttons. Embeds a `DiffPanelWidget` in a vertical splitter below the activity feed. Chat bubbles reflow on resize via `QVBoxLayout`.

- **DiffPanelWidget** -- `QOpenGLWidget` hosting the `DiffRenderer`. Supports mouse-based text selection and Ctrl+C copy. Adaptive memory management: releases GPU resources when the window is hidden and re-initializes on show.

- **SystemTray** -- `QSystemTrayIcon` with animated tray icons:
  - Loading bounce animation (6 frames)
  - Running loop animation (6 frames, smooth interpolation)
  - Colored status dot overlays via `QPainter` for error/attention/paused/failed states
  - Theme adaptation: `setIsMask(true)` on monochrome base icons so the desktop environment can tint them appropriately.

- **SettingsDialog** -- Tabbed dialog for API key, theme selection, font size, hotkey configuration (with inline hotkey capture widget), notification preferences, and repository folder management.

- **NewSessionDialog** -- Dialog for creating new sessions with source/repository selection, branch input, and filename autocomplete integration.

- **TrayPopupWidget** -- Popup panel anchored near the tray icon showing recent sessions, a quick session creation field, and settings/quit actions.

- **FeedbackDialog** -- Dialog for submitting feedback on session results.

## Signal Wiring

All inter-module communication uses Qt signals and slots. The wiring is centralized in `src/main.cpp` (~560 LOC). Key signal chains:

```
API Timer tick
  -> JulesApiClient::fetchSessions()
  -> sessionsReceived(sessions)
  -> SessionRepository::saveSessions()
  -> SessionListWidget::refresh()

Session selected
  -> JulesApiClient::getActivities(sessionId)
  -> activitiesReceived(activities)
  -> SessionDetailWidget::setSession(updated)
  -> DiffPrecomputationService::precomputeAll()

Theme changed
  -> MainWindow::themeChanged(theme)
  -> DiffPanelWidget::setDarkMode(isDark)
  -> SystemTray::updateTheme(isDark)
  -> SessionListWidget / SessionDetailWidget repaint

Network restored
  -> NetworkMonitor::connectivityRestored()
  -> OfflineSyncManager::syncPendingQueue()
  -> JulesApiClient::createSession() for each queued item
```

The tray state is derived from the highest-priority session state across all active sessions, with priority: NeedsAttention > Running > Planning/Queued > Failed > Paused > Idle.

## Database Schema

### Main Database (`jules-linux.db`)

SQLite with WAL mode. Schema is managed through versioned migrations in `database.cpp`.

```sql
-- v1: sessions
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    title TEXT, status TEXT, created_at TEXT, updated_at TEXT,
    repository TEXT, branch TEXT, ...
);

-- v2: activities
CREATE TABLE activities (
    id TEXT PRIMARY KEY,
    session_id TEXT, type TEXT, content TEXT, created_at TEXT, ...
);

-- v3: pending sessions (offline queue)
CREATE TABLE pending_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT, repository TEXT, instructions TEXT,
    created_at TEXT, retry_count INTEGER DEFAULT 0
);
```

### Diffs Database (`diffs.db`)

Separate database for patch storage, keeping the main database compact for fast session queries.

## Rendering Pipeline

```
DiffPanelWidget::paintGL()
  -> DiffRenderer::render(viewportTop, viewportHeight)
     1. Check viewport cache (integer-snapped pixel comparison)
     2. If cache miss: generateRenderData()
        a. Parse unified diff into DiffLine[]
        b. Compute character-level inline diffs (prefix/suffix matching)
        c. Binary search syntax cache for each line
        d. Generate glyph instances + background rect instances
     3. Upload instance buffers to GPU
     4. Draw instanced quads (text glyphs + background rects)
```

The renderer uses two OpenGL shader programs:
- **Text shader** -- Renders textured quads from the font atlas with per-glyph color.
- **Rect shader** -- Renders colored rectangles for line backgrounds, gutter, selection highlights, and inline diff highlights.

Both use instanced rendering (`glDrawArraysInstanced`) with a single quad VAO and per-instance attribute buffers for position, size, color, and texture coordinates.

## Theming

Colors are centralized in `include/ui/app_colors.h`. Every color function takes a `bool dark` parameter:

```cpp
static QColor background(bool dark);
static QColor accent(bool dark);
static QColor destructive(bool dark);
static QColor textPrimary(bool dark);
static QColor textSecondary(bool dark);
static QColor separator(bool dark);
// ... ~30 color definitions
```

Theme detection uses `QPalette::window().color().lightness() < 128` to determine dark mode. The `MainWindow::themeChanged` signal propagates the change to all widgets:
- `DiffRenderer` switches between dark and light `DiffColors` palettes.
- `SystemTray` updates icon masking for desktop environment tinting.
- Widgets using `AppColors` re-query with the new dark mode flag.

The app supports three theme modes: System (follows desktop preference), Light, and Dark.

## Testing

27+ test suites using Google Test and Qt Test. Tests cover:

- **API client** -- Response parsing, hash caching, error handling
- **Session repository** -- CRUD operations, migration verification
- **Diff renderer** -- Patch parsing, layout computation, highlighting
- **UI widgets** -- Settings dialog, session list, hotkey edit, feedback dialog
- **Infrastructure** -- Network monitor, offline sync, syntax cache, precomputation service, diff panel widget, tray popup, notification manager, filename autocomplete

Test conventions:
- One test file per class, named `<class>_test.cpp`
- Tests requiring a `QApplication` instance link against `Qt6::Gui` and `Qt6::Widgets`
- The `jules_api` library requires `jules_data` listed twice in link dependencies due to a circular reference

Run all tests: `cd build && ctest --output-on-failure`
