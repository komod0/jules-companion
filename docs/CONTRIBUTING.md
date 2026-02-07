# Contributing

Contributions are welcome! This guide covers the development setup, code conventions, and pull request process.

## Development Setup

### Prerequisites

- CMake 3.24+
- Qt 6.4+ with modules: Core, Gui, Widgets, Network, Sql, OpenGL, OpenGLWidgets, DBus, Test
- FreeType 2
- XCB + xcb-keysyms (optional, for X11 hotkeys)
- OpenGL 4.3+ capable GPU
- GCC 12+ or Clang 15+ (C++20 support required)

### Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel
```

### Run Tests

```bash
cd build && ctest --output-on-failure
```

All 31 test suites must pass before submitting a pull request.

### Run the Application

```bash
./build/jules-linux
```

## Code Style

### C++

- **Standard**: C++20
- **Namespace**: All code in the `jules` namespace (exception: `SettingsManager` in global namespace)
- **Naming**:
  - Classes: `PascalCase` (e.g., `DiffRenderer`, `SessionListWidget`)
  - Methods/functions: `camelCase` (e.g., `fetchSessions()`, `setDarkMode()`)
  - Member variables: `m_camelCase` (e.g., `m_trayIcon`, `m_isDark`)
  - Static members: `s_camelCase` (e.g., `s_loadingSequence`)
  - Constants/enums: `PascalCase` values (e.g., `TrayState::NeedsAttention`)
- **Indentation**: 4 spaces, no tabs
- **Braces**: Attach style (same line) for all constructs — functions, control structures, classes
- **Includes**: Group by category — project headers, Qt headers, standard library
- **Formatting**: A `.clang-format` config is provided in the project root; run `clang-format -i <file>` or configure your editor to format on save

### Patterns

- **PImpl**: Used for `DiffRenderer` and `SyntaxHighlighter` to hide implementation details and reduce compile-time dependencies
- **Signals/slots**: All inter-module communication uses Qt signals and slots, wired in `main.cpp`
- **Singleton**: `SettingsManager::instance()` for app-wide settings access

### File Organization

- Headers in `include/<module>/` — one header per class
- Sources in `src/<module>/` — one source file per class
- Tests in `tests/` — one test file per class, named `<class>_test.cpp`

## Pull Request Guidelines

1. **Branch from `main`** — Create a feature branch with a descriptive name
2. **Keep changes focused** — One feature or fix per PR
3. **Add tests** — New functionality should include tests in `tests/`
4. **Build clean** — `cmake --build build --parallel` must succeed with no warnings
5. **Tests pass** — All existing and new tests must pass
6. **Commit messages** — Use conventional commits: `feat:`, `fix:`, `test:`, `docs:`, `chore:`

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for module layout, dependency graph, and rendering pipeline details.

## Reporting Issues

Open an issue on GitHub with:
- Steps to reproduce
- Expected vs actual behavior
- Linux distribution and desktop environment (GNOME/KDE/etc.)
- Qt version (`qmake6 --version` or `qmake --version`)
