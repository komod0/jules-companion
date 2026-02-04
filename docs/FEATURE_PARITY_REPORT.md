# Jules Companion: macOS vs Linux Feature Parity Report

Generated: 2026-02-04

## Executive Summary

| Category | macOS | Linux | Parity |
|----------|-------|-------|--------|
| **UI Components** | 102 Swift files | 8 Qt files | **~8%** |
| **API/Networking** | Full + Gemini | Basic | **~70%** |
| **Data/Storage** | Comprehensive | Minimal | **~40%** |
| **Rendering** | Metal (advanced) | OpenGL (functional) | **~80%** |
| **Features** | Complete | Basic | **~50%** |
| **Models** | Full | Missing fields | **~85%** |

**Overall Parity: ~55%**

---

## 1. UI Components Gap Analysis

### Fully Missing Components (HIGH PRIORITY)

| Component | macOS File | Description | Priority |
|-----------|-----------|-------------|----------|
| **ActivityMessageView** | ActivityMessageView.swift | Chat bubbles with markdown | CRITICAL |
| **ActivityProgressView** | ActivityProgressView.swift | Animated progress indicator | HIGH |
| **DiffStatsBadges** | DiffStatsBadges.swift | Git +/- line counts | HIGH |
| **MergeConflictView** | MergeConflictWindow/ | Conflict resolution UI | HIGH |
| **SessionToolbarItems** | SessionToolbarItems.swift | View PR, Merge buttons | MEDIUM |
| **CenteredMenuView** | CenteredMenuView.swift | Floating menu panel | MEDIUM |
| **TaskSubtitleView** | TaskSubtitleView.swift | Session subtitle/status | MEDIUM |
| **MarkdownTextView** | MarkdownTextView.swift | Markdown rendering | HIGH |

### Partially Implemented

| Component | macOS | Linux | Missing Features |
|-----------|-------|-------|------------------|
| SessionListWidget | SidebarView | session_list_widget.cpp | Search, categorization (Today/Week/Older), pagination |
| SessionDetailWidget | ActivityView | session_detail_widget.cpp | Message streaming, markdown, expand/collapse |
| SettingsDialog | SettingsView | settings_dialog.cpp | Launch at login, network logs, key commands |
| NewSessionDialog | NewTaskFormView | new_session_dialog.cpp | Autocomplete, source picker, image attachments |

---

## 2. API/Networking Gap Analysis

### Missing Endpoints

| Endpoint | macOS | Linux | Impact |
|----------|-------|-------|--------|
| `/sources` | ✅ | ❌ | Cannot fetch repository list |
| Gemini API | ✅ | ❌ | No AI-generated activity summaries |

### Missing Features

| Feature | macOS | Linux | Description |
|---------|-------|-------|-------------|
| **Response Caching** | Hash-based | None | macOS skips JSON decode if unchanged |
| **Auto-pagination** | ✅ | ❌ | Linux requires manual token handling |
| **Multi-tier Polling** | ✅ | ❌ | macOS: 10s active, 30s backfill, 60s completed |
| **Stale Detection** | 10min check | None | Detect hung sessions |
| **Priority Handling** | Active first | None | Currently viewed session prioritized |

### Polling Strategy Comparison

```
macOS:
├── Active sessions: every 10 seconds (top 5 + viewed)
├── Backfill sessions: every 30 seconds (3 at a time)
├── Completed sessions: every 60 seconds (only needing stats)
└── Stale check: every 10 minutes

Linux:
└── All sessions: every 10 seconds (no differentiation)
```

---

## 3. Data/Storage Gap Analysis

### Database Schema Differences

| Table | macOS | Linux | Notes |
|-------|-------|-------|-------|
| sessions | ✅ | ✅ | Similar structure |
| diffs | Separate DB | Same table | macOS uses diffs.sqlite |
| sources | ✅ | ❌ | Offline source caching |
| pendingSession | ✅ | ❌ | Offline session queue |
| filePath | ✅ | ❌ | File path caching |
| repositoryScanState | ✅ | ❌ | Scan status |

### Missing Session Fields (Linux)

```cpp
// These fields exist in macOS but NOT in Linux:
std::optional<QDateTime> mergedLocallyAt;
std::optional<QString> cachedGitStatsSummary;
std::optional<QList<CachedDiff>> cachedLatestDiffs;
std::optional<QString> cachedGitStatsUpdateTime;
bool hasCachedDiffsFlag = false;
```

### Missing Struct (Linux)

```cpp
// CachedDiff struct missing entirely
struct CachedDiff {
    QString patch;
    QString language;
    QString filename;
};
```

### Caching Comparison

| Feature | macOS | Linux |
|---------|-------|-------|
| In-memory diff cache | NSCache (64MB, 50 sessions) | None |
| Activity hash caching | ✅ | ❌ |
| Async diff preloading | ✅ | ❌ |
| Memory limits | Explicit | None |
| Data stripping | ✅ (media, patches) | ❌ |

---

## 4. Rendering Gap Analysis

### Feature Parity (~80%)

| Feature | macOS Metal | Linux OpenGL | Status |
|---------|-------------|--------------|--------|
| Diff rendering | ✅ | ✅ | Functional |
| Syntax highlighting | Tree-sitter async | Tree-sitter async | ✅ Match |
| Font atlas | CoreText + Bold | FreeType only | ⚠️ Missing bold |
| Boids animation | GPU compute | GPU compute | ✅ Match |
| Wave animation | 500+ segments, MSAA | Simple quad | ⚠️ Lower quality |
| Diff loader anim | Complex animation | None | ❌ Missing |

### Missing Shader Features (Linux)

- Subpixel AA (dual-source blending)
- Bold font atlas
- Rect rendering via SDF
- Diff loader animation shaders

### UI Integration Gap

| Feature | macOS | Linux |
|---------|-------|-------|
| Horizontal scrollbar | Custom with drag | Not implemented |
| Keyboard shortcuts | Cmd+C copy | Not visible |
| Right-click menu | ✅ | ❌ |
| Dynamic theming | ✅ | Hardcoded colors |
| Auto-scroll during drag | ✅ | ❌ |

---

## 5. Features Gap Analysis

### Critical Missing Features

| Feature | macOS | Linux | Priority |
|---------|-------|-------|----------|
| **Notifications** | UNUserNotificationCenter | None | CRITICAL |
| **Merge Conflicts** | Full visual UI | None | HIGH |
| **Auto-Updates** | Sparkle | None | HIGH |
| **Voice Input** | macOS 26.0+ | None | MEDIUM |
| **Screenshot/Canvas** | Full capture + annotate | None | MEDIUM |

### Feature Status

| Feature | macOS | Linux | Parity |
|---------|-------|-------|--------|
| Global Hotkeys | HotKey lib | XCB + DBus Portal | ✅ Linux MORE sophisticated |
| System Tray | NSStatusItem | QSystemTrayIcon | ✅ Both work |
| Settings | Comprehensive | Basic | ⚠️ macOS more complete |

---

## 6. Model Parity Analysis

### Session Computed Properties Missing (Linux)

```cpp
// All of these need to be added:
bool isMergedLocally() const;
QString gitStatsSummary() const;
bool hasDiffsAvailable() const;
QList<CachedDiff> latestDiffs() const;
qint64 timeSinceLastUpdate() const;
bool isStaleActive() const;
bool needsActivityFetchForStats() const;
bool hasCachedGitStats() const;
bool areCachedGitStatsStale() const;
QString latestProgressTitle() const;
```

### Static Methods Missing (Linux)

```cpp
static QString computeGitStatsSummary(const QList<Activity>& activities);
static QList<CachedDiff> computeLatestDiffs(const QList<Activity>& activities);
static void splitPatchByFile(const QString& patch, QList<CachedDiff>& out);
static QString detectLanguage(const QString& patch);
```

### SessionState Missing Properties (Linux)

```cpp
QString menuIconName() const;
QString iconName() const;
QColor color() const;
QString displayName() const;
```

---

## 7. Priority Action Items

### CRITICAL (Do First)

1. **Add CachedDiff struct** to Linux header
2. **Add missing Session fields** (5 fields)
3. **Implement notifications** using DBus org.freedesktop.Notifications
4. **Add getSources() endpoint** to API client

### HIGH PRIORITY

5. **Add multi-tier polling** (10s/30s/60s strategy)
6. **Implement response caching** (hash-based)
7. **Add merge conflict UI** (basic version)
8. **Add bold font atlas** for header rendering
9. **Implement horizontal scrollbar** for diff panel

### MEDIUM PRIORITY

10. **Add session computed properties** (10 methods)
11. **Add git stats badges** to UI
12. **Implement diff stats parsing**
13. **Add search/filter** to session list
14. **Add auto-updates** via AppImage mechanism

### LOW PRIORITY

15. **Add voice input** (speech recognition)
16. **Add screenshot/canvas** feature
17. **Add network logging** to settings
18. **Port diff loader animation**
19. **Add MSAA to wave rendering**

---

## 8. Recommended Implementation Order

### Phase 1: Core Data Model (1-2 days)
- Add CachedDiff struct
- Add missing Session fields
- Add computed properties
- Add static helper methods

### Phase 2: API Enhancements (1-2 days)
- Add getSources() endpoint
- Implement response hash caching
- Add multi-tier polling strategy
- Add stale session detection

### Phase 3: Database Upgrades (1 day)
- Add migrations for new fields
- Add diff caching layer
- Add activity persistence
- Add offline support tables

### Phase 4: UI Improvements (2-3 days)
- Add git stats badges
- Improve session detail with markdown
- Add message bubbles styling
- Add horizontal scrollbar to diff panel

### Phase 5: Features (3-5 days)
- Implement notifications (DBus)
- Add merge conflict basic UI
- Add auto-update mechanism
- Add keyboard shortcuts

---

## Appendix: File Mapping

### macOS Files → Linux Equivalents

| macOS | Linux | Status |
|-------|-------|--------|
| AppDelegate.swift | main.cpp, system_tray.cpp | Partial |
| APIService.swift | jules_api_client.cpp | Partial |
| DataManager.swift | main.cpp (partial) | Partial |
| SessionRepository.swift | session_repository.cpp | Partial |
| Models.swift | jules_api_client.h | Partial |
| SidebarView.swift | session_list_widget.cpp | Partial |
| ActivityView.swift | session_detail_widget.cpp | Partial |
| SettingsView.swift | settings_dialog.cpp | Partial |
| FontSizeManager.swift | settings_manager.cpp | Partial |
| Flux/*.swift | src/rendering/*.cpp | Partial |
| MergeConflictWindow/*.swift | None | Missing |
| Canvas/*.swift | None | Missing |
| NotificationManager.swift | None | Missing |
| VoiceInputView.swift | None | Missing |
