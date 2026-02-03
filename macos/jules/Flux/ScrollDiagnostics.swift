import Foundation
import os.signpost

/// Diagnostic logger for tracking diff scroll performance issues.
///
/// Tracks:
/// - FileDiffSection view lifecycle and height calculations
/// - TiledFluxDiffView tile creation/destruction
/// - Height consistency between different calculation paths
/// - Viewport changes and visible range calculations
/// - Pre-computation status
///
/// To enable:
/// 1. Set `ScrollDiagnostics.shared.isEnabled = true` in code, or
/// 2. Run: `defaults write com.app.jules ScrollDiagnosticsEnabled -bool true`
@MainActor
final class ScrollDiagnostics {
    static let shared = ScrollDiagnostics()

    // MARK: - Configuration

    /// Enable/disable diagnostic logging
    var isEnabled: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "ScrollDiagnosticsEnabled")
        #else
        return false
        #endif
    }()

    /// Print detailed logs for each event (can be noisy during fast scrolling)
    var verboseMode: Bool = false

    /// Track height inconsistencies (always on when enabled)
    var trackHeightInconsistencies: Bool = true

    // MARK: - Signpost for Instruments

    private let signpostLog = OSLog(subsystem: "com.jules.app", category: "ScrollDiagnostics")

    // MARK: - State Tracking

    /// Track active FileDiffSection views
    private var activeDiffSections: [String: DiffSectionInfo] = [:]

    /// Track active tiles
    private var activeTiles: [String: TileInfo] = [:]

    /// Height calculations for consistency checking
    private var heightCalculations: [String: [CGFloat]] = [:]

    /// Scroll position history
    private var scrollHistory: [(timestamp: CFAbsoluteTime, scrollY: CGFloat, viewportHeight: CGFloat)] = []
    private let maxScrollHistorySize = 100

    // MARK: - Recycling Detection

    /// Track appear/disappear events to detect rapid recycling
    private var recyclingEvents: [String: [(event: String, timestamp: CFAbsoluteTime)]] = [:]
    private let recyclingWindowSeconds: CFAbsoluteTime = 2.0  // Look for recycling within 2 seconds

    // MARK: - Scroll Container Tracking

    /// Track scroll container height changes
    private var lastScrollContainerHeight: CGFloat = 0
    private var scrollContainerHeightHistory: [(timestamp: CFAbsoluteTime, height: CGFloat)] = []

    /// Track scroll position for jump detection
    private var lastScrollPosition: CGFloat = 0
    private var scrollPositionHistory: [(timestamp: CFAbsoluteTime, position: CGFloat, source: String)] = []

    /// Track scrollbar thumb position for detecting rapid jumping
    private var scrollbarThumbHistory: [(timestamp: CFAbsoluteTime, thumbRatio: CGFloat, contentHeight: CGFloat)] = []
    private var lastScrollbarThumbRatio: CGFloat = 0

    // MARK: - Rendered Height Tracking

    /// Track actual rendered heights vs expected heights
    private var renderedHeights: [String: (expected: CGFloat, actual: CGFloat, timestamp: CFAbsoluteTime)] = [:]

    // MARK: - Types

    struct DiffSectionInfo {
        let index: Int
        let filename: String?
        let reportedHeight: CGFloat
        let lineCount: Int
        let createdAt: CFAbsoluteTime
        var lastHeightUpdate: CFAbsoluteTime
        var heightHistory: [CGFloat]
    }

    struct TileInfo {
        let diffIndex: Int
        let tileIndex: Int
        let startLine: Int
        let endLine: Int
        let height: CGFloat
        let createdAt: CFAbsoluteTime
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Toggle

    func toggle() {
        isEnabled.toggle()
        #if DEBUG
        UserDefaults.standard.set(isEnabled, forKey: "ScrollDiagnosticsEnabled")
        print("🔍 ScrollDiagnostics: \(isEnabled ? "ENABLED" : "DISABLED")")
        #endif
        if isEnabled {
            print("""

            ╔══════════════════════════════════════════════════════════════╗
            ║              ScrollDiagnostics ENABLED                        ║
            ╠══════════════════════════════════════════════════════════════╣
            ║  Tracking:                                                    ║
            ║  • FileDiffSection view lifecycle & heights                   ║
            ║  • TiledFluxDiffView tile creation/destruction               ║
            ║  • Height calculation consistency                             ║
            ║  • Viewport changes & visible ranges                          ║
            ║  • Pre-computation cache status                               ║
            ╚══════════════════════════════════════════════════════════════╝

            """)
        }
    }

    // MARK: - FileDiffSection Tracking

    /// Called when a FileDiffSection view is created
    func diffSectionCreated(
        index: Int,
        filename: String?,
        reportedHeight: CGFloat,
        lineCount: Int,
        precomputedHeight: CGFloat?,
        calculatedHeight: CGFloat?,
        sessionId: String
    ) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(index)"
        let now = CFAbsoluteTimeGetCurrent()

        let info = DiffSectionInfo(
            index: index,
            filename: filename,
            reportedHeight: reportedHeight,
            lineCount: lineCount,
            createdAt: now,
            lastHeightUpdate: now,
            heightHistory: [reportedHeight]
        )
        activeDiffSections[key] = info

        // Check for height inconsistencies
        var heightMismatch = false
        if let precomputed = precomputedHeight, let calculated = calculatedHeight {
            if abs(precomputed - calculated) > 1.0 {
                heightMismatch = true
                print("⚠️ [ScrollDiag] HEIGHT MISMATCH for \(filename ?? "diff \(index)"):")
                print("   Precomputed: \(precomputed), Calculated: \(calculated), Diff: \(precomputed - calculated)")
            }
        }

        if verboseMode || heightMismatch {
            let truncatedFilename = filename.map { $0.count > 40 ? "..." + $0.suffix(37) : $0 } ?? "diff \(index)"
            print("📦 [ScrollDiag] DiffSection CREATED: \(truncatedFilename)")
            print("   Height: \(reportedHeight), Lines: \(lineCount)")
            if let precomputed = precomputedHeight {
                print("   Precomputed: \(precomputed)")
            }
        }

        os_signpost(.event, log: signpostLog, name: "DiffSectionCreated",
                   "index=%d, height=%.1f, lines=%d", index, reportedHeight, lineCount)
    }

    /// Called when a FileDiffSection view disappears
    func diffSectionDisappeared(index: Int, sessionId: String) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(index)"
        if let info = activeDiffSections.removeValue(forKey: key) {
            let lifetime = CFAbsoluteTimeGetCurrent() - info.createdAt

            if verboseMode {
                print("📤 [ScrollDiag] DiffSection DISAPPEARED: \(info.filename ?? "diff \(index)")")
                print("   Lifetime: \(String(format: "%.2f", lifetime * 1000))ms")
                print("   Height changes: \(info.heightHistory)")
            }

            os_signpost(.event, log: signpostLog, name: "DiffSectionDisappeared",
                       "index=%d, lifetime=%.2fms", index, lifetime * 1000)
        }
    }

    /// Called when a FileDiffSection's height changes
    func diffSectionHeightChanged(
        index: Int,
        sessionId: String,
        oldHeight: CGFloat,
        newHeight: CGFloat,
        reason: String
    ) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(index)"
        if var info = activeDiffSections[key] {
            info.heightHistory.append(newHeight)
            info.lastHeightUpdate = CFAbsoluteTimeGetCurrent()
            activeDiffSections[key] = info

            let diff = newHeight - oldHeight
            let symbol = diff > 0 ? "📈" : "📉"
            print("\(symbol) [ScrollDiag] DiffSection HEIGHT CHANGED: diff \(index)")
            print("   \(oldHeight) → \(newHeight) (Δ\(diff))")
            print("   Reason: \(reason)")
            print("   History: \(info.heightHistory)")

            os_signpost(.event, log: signpostLog, name: "HeightChanged",
                       "index=%d, old=%.1f, new=%.1f, delta=%.1f",
                       index, oldHeight, newHeight, diff)
        }
    }

    // MARK: - TiledFluxDiffView Tracking

    /// Called when a tile is created
    func tileCreated(
        diffIndex: Int,
        tileIndex: Int,
        startLine: Int,
        endLine: Int,
        height: CGFloat,
        sessionId: String
    ) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)-\(tileIndex)"
        let now = CFAbsoluteTimeGetCurrent()

        activeTiles[key] = TileInfo(
            diffIndex: diffIndex,
            tileIndex: tileIndex,
            startLine: startLine,
            endLine: endLine,
            height: height,
            createdAt: now
        )

        if verboseMode {
            print("🧩 [ScrollDiag] Tile CREATED: diff \(diffIndex), tile \(tileIndex)")
            print("   Lines: \(startLine)-\(endLine), Height: \(height)")
        }

        os_signpost(.event, log: signpostLog, name: "TileCreated",
                   "diff=%d, tile=%d, lines=%d-%d, height=%.1f",
                   diffIndex, tileIndex, startLine, endLine, height)
    }

    /// Called when a tile is destroyed
    func tileDestroyed(diffIndex: Int, tileIndex: Int, sessionId: String) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)-\(tileIndex)"
        if let info = activeTiles.removeValue(forKey: key) {
            let lifetime = CFAbsoluteTimeGetCurrent() - info.createdAt

            if verboseMode {
                print("🗑️ [ScrollDiag] Tile DESTROYED: diff \(diffIndex), tile \(tileIndex)")
                print("   Lifetime: \(String(format: "%.2f", lifetime * 1000))ms")
            }

            os_signpost(.event, log: signpostLog, name: "TileDestroyed",
                       "diff=%d, tile=%d, lifetime=%.2fms",
                       diffIndex, tileIndex, lifetime * 1000)
        }
    }

    // MARK: - Viewport Tracking

    /// Called when the viewport changes
    func viewportChanged(
        scrollY: CGFloat,
        viewportHeight: CGFloat,
        totalContentHeight: CGFloat,
        visibleRange: Range<Int>,
        diffIndex: Int? = nil
    ) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        scrollHistory.append((timestamp: now, scrollY: scrollY, viewportHeight: viewportHeight))

        // Trim history
        if scrollHistory.count > maxScrollHistorySize {
            scrollHistory.removeFirst(scrollHistory.count - maxScrollHistorySize)
        }

        // Detect fast scrolling (large position changes in short time)
        if scrollHistory.count >= 2 {
            let prev = scrollHistory[scrollHistory.count - 2]
            let timeDelta = now - prev.timestamp
            let scrollDelta = abs(scrollY - prev.scrollY)

            // Fast scroll detection: > 500pt change in < 100ms
            if timeDelta < 0.1 && scrollDelta > 500 {
                print("⚡ [ScrollDiag] FAST SCROLL DETECTED")
                print("   Δscroll: \(scrollDelta), Δtime: \(String(format: "%.0f", timeDelta * 1000))ms")
                print("   Velocity: \(String(format: "%.0f", scrollDelta / CGFloat(timeDelta)))pt/s")

                os_signpost(.event, log: signpostLog, name: "FastScroll",
                           "delta=%.0f, velocity=%.0f", scrollDelta, scrollDelta / CGFloat(timeDelta))
            }
        }

        if verboseMode {
            let diffInfo = diffIndex.map { " (diff \($0))" } ?? ""
            print("🔭 [ScrollDiag] Viewport\(diffInfo): scrollY=\(scrollY), height=\(viewportHeight)")
            print("   Total content: \(totalContentHeight), Visible lines: \(visibleRange)")
        }
    }

    // MARK: - Pre-computation Tracking

    /// Called when pre-computation starts
    func precomputationStarted(sessionId: String, diffCount: Int) {
        guard isEnabled else { return }

        print("🔄 [ScrollDiag] Pre-computation STARTED for session \(sessionId.prefix(8))...")
        print("   Diffs to process: \(diffCount)")

        os_signpost(.begin, log: signpostLog, name: "Precomputation",
                   "session=%{public}s, count=%d", sessionId, diffCount)
    }

    /// Called when pre-computation completes
    func precomputationCompleted(sessionId: String, diffCount: Int, duration: CFAbsoluteTime) {
        guard isEnabled else { return }

        print("✅ [ScrollDiag] Pre-computation COMPLETED for session \(sessionId.prefix(8))...")
        print("   Processed: \(diffCount) diffs in \(String(format: "%.2f", duration * 1000))ms")

        os_signpost(.end, log: signpostLog, name: "Precomputation",
                   "session=%{public}s, count=%d, duration=%.2fms",
                   sessionId, diffCount, duration * 1000)
    }

    /// Called when using pre-computed vs on-demand calculation
    func precomputationCacheHit(index: Int, hit: Bool) {
        guard isEnabled && verboseMode else { return }

        let symbol = hit ? "💾" : "⏳"
        print("\(symbol) [ScrollDiag] Precompute cache \(hit ? "HIT" : "MISS") for diff \(index)")
    }

    // MARK: - Multi-Tile Creation Tracking

    /// Track when a multi-tile diff starts creating tiles
    private var multiTileCreationStart: [String: (startTime: CFAbsoluteTime, expectedTiles: Int, createdTiles: Int)] = [:]

    /// Called when TiledFluxDiffView starts creating tiles for a multi-tile diff
    func multiTileDiffStarted(diffIndex: Int, sessionId: String, tileCount: Int, totalHeight: CGFloat, lineCount: Int) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)"
        let now = CFAbsoluteTimeGetCurrent()
        multiTileCreationStart[key] = (startTime: now, expectedTiles: tileCount, createdTiles: 0)

        print("🏗️ [ScrollDiag] MULTI-TILE DIFF STARTING: diff \(diffIndex)")
        print("   Tiles available: \(tileCount), Height: \(totalHeight), Lines: \(lineCount)")
        print("   ✅ Using lazy tile loading (only visible tiles will be created)")

        os_signpost(.begin, log: signpostLog, name: "MultiTileDiffCreation",
                   "diff=%d, tiles=%d, height=%.0f, lines=%d",
                   diffIndex, tileCount, totalHeight, lineCount)
    }

    /// Called when a tile is created as part of multi-tile diff
    func multiTileTileCreated(diffIndex: Int, tileIndex: Int, sessionId: String) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)"
        if var info = multiTileCreationStart[key] {
            info.createdTiles += 1
            multiTileCreationStart[key] = info

            let duration = (CFAbsoluteTimeGetCurrent() - info.startTime) * 1000

            // With lazy loading, report after initial visible tiles are created (typically 3-5 tiles)
            // rather than waiting for all tiles. Check if we've been loading for a reasonable time
            // and have created at least one tile, or if all tiles are created.
            let isInitialLoadComplete = info.createdTiles >= min(5, info.expectedTiles) || info.createdTiles >= info.expectedTiles

            if isInitialLoadComplete && info.createdTiles <= min(5, info.expectedTiles) {
                let symbol = duration > 100 ? "🟡" : "🟢"

                print("\(symbol) [ScrollDiag] MULTI-TILE DIFF INITIAL LOAD: diff \(diffIndex)")
                print("   Created \(info.createdTiles)/\(info.expectedTiles) visible tiles in \(String(format: "%.2f", duration))ms")

                os_signpost(.end, log: signpostLog, name: "MultiTileDiffCreation",
                           "diff=%d, tiles=%d/%d, duration=%.2fms",
                           diffIndex, info.createdTiles, info.expectedTiles, duration)

                multiTileCreationStart.removeValue(forKey: key)
            } else if info.createdTiles >= info.expectedTiles {
                // All tiles have been created (user scrolled through entire diff)
                print("🟢 [ScrollDiag] MULTI-TILE DIFF ALL TILES: diff \(diffIndex)")
                print("   All \(info.createdTiles) tiles created")

                multiTileCreationStart.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Height Consistency Tracking

    /// Track height calculation for consistency checking
    func trackHeightCalculation(
        identifier: String,
        source: String,
        height: CGFloat
    ) {
        guard isEnabled && trackHeightInconsistencies else { return }

        if heightCalculations[identifier] == nil {
            heightCalculations[identifier] = []
        }
        heightCalculations[identifier]?.append(height)

        // Check for inconsistencies
        if let heights = heightCalculations[identifier], heights.count > 1 {
            let uniqueHeights = Set(heights.map { Int($0) })
            if uniqueHeights.count > 1 {
                print("⚠️ [ScrollDiag] HEIGHT INCONSISTENCY for \(identifier):")
                print("   Source: \(source)")
                print("   Heights: \(heights)")

                os_signpost(.event, log: signpostLog, name: "HeightInconsistency",
                           "id=%{public}s, heights=%{public}s",
                           identifier, heights.description)
            }
        }
    }

    // MARK: - View Recycling Detection

    /// Track view appear/disappear to detect rapid recycling (LazyVStack issue)
    func trackViewLifecycle(diffIndex: Int, sessionId: String, event: String) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)"
        let now = CFAbsoluteTimeGetCurrent()

        // Initialize if needed
        if recyclingEvents[key] == nil {
            recyclingEvents[key] = []
        }

        // Add this event
        recyclingEvents[key]?.append((event: event, timestamp: now))

        // Trim old events outside the window
        recyclingEvents[key] = recyclingEvents[key]?.filter { now - $0.timestamp < recyclingWindowSeconds }

        // Detect rapid recycling: multiple appear/disappear pairs in short time
        if let events = recyclingEvents[key] {
            let recentAppears = events.filter { $0.event == "appear" }.count
            let recentDisappears = events.filter { $0.event == "disappear" }.count

            // If we have 3+ appears in the recycling window, that's aggressive recycling
            if recentAppears >= 3 {
                print("🔄 [ScrollDiag] RAPID RECYCLING DETECTED: diff \(diffIndex)")
                print("   \(recentAppears) appears, \(recentDisappears) disappears in last \(recyclingWindowSeconds)s")
                print("   Events: \(events.map { $0.event }.joined(separator: " → "))")

                os_signpost(.event, log: signpostLog, name: "RapidRecycling",
                           "diff=%d, appears=%d, disappears=%d",
                           diffIndex, recentAppears, recentDisappears)
            }
        }
    }

    // MARK: - Scroll Container Height Tracking

    /// Called when the scroll container's total content height changes
    func scrollContainerHeightChanged(newHeight: CGFloat, sessionId: String, diffCount: Int) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let delta = newHeight - lastScrollContainerHeight

        // Only log if there's a meaningful change (> 1pt)
        if abs(delta) > 1 {
            print("📐 [ScrollDiag] SCROLL CONTAINER HEIGHT CHANGED:")
            print("   \(lastScrollContainerHeight) → \(newHeight) (Δ\(String(format: "%.1f", delta)))")
            print("   Diffs: \(diffCount), Session: \(sessionId.prefix(8))...")

            scrollContainerHeightHistory.append((timestamp: now, height: newHeight))

            // Trim history to last 20 entries
            if scrollContainerHeightHistory.count > 20 {
                scrollContainerHeightHistory.removeFirst(scrollContainerHeightHistory.count - 20)
            }

            os_signpost(.event, log: signpostLog, name: "ContainerHeightChanged",
                       "old=%.1f, new=%.1f, delta=%.1f",
                       lastScrollContainerHeight, newHeight, delta)
        }

        lastScrollContainerHeight = newHeight
    }

    // MARK: - Scroll Position Jump Detection

    /// Called when the scroll position changes - detects unexpected jumps
    func scrollPositionChanged(newPosition: CGFloat, source: String, sessionId: String) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let delta = newPosition - lastScrollPosition

        // Detect large jumps (> 100pt) that aren't from user scrolling
        if abs(delta) > 100 && source != "user_scroll" {
            print("⚠️ [ScrollDiag] SCROLL POSITION JUMP DETECTED:")
            print("   \(lastScrollPosition) → \(newPosition) (Δ\(String(format: "%.1f", delta)))")
            print("   Source: \(source)")

            os_signpost(.event, log: signpostLog, name: "ScrollPositionJump",
                       "old=%.1f, new=%.1f, delta=%.1f, source=%{public}s",
                       lastScrollPosition, newPosition, delta, source)
        }

        scrollPositionHistory.append((timestamp: now, position: newPosition, source: source))

        // Trim history to last 50 entries
        if scrollPositionHistory.count > 50 {
            scrollPositionHistory.removeFirst(scrollPositionHistory.count - 50)
        }

        lastScrollPosition = newPosition
    }

    /// Track the current scroll offset (for use with GeometryReader in parent)
    func trackScrollOffset(scrollY: CGFloat, containerHeight: CGFloat, contentHeight: CGFloat, sessionId: String) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()

        // Calculate visible percentage
        let visiblePercent = containerHeight / contentHeight * 100
        let scrollPercent = contentHeight > containerHeight ? scrollY / (contentHeight - containerHeight) * 100 : 0

        if verboseMode {
            print("📜 [ScrollDiag] Scroll offset: \(String(format: "%.1f", scrollY))pt")
            print("   Container: \(String(format: "%.1f", containerHeight))pt, Content: \(String(format: "%.1f", contentHeight))pt")
            print("   Visible: \(String(format: "%.1f", visiblePercent))%, Progress: \(String(format: "%.1f", scrollPercent))%")
        }

        // Track the position
        scrollPositionHistory.append((timestamp: now, position: scrollY, source: "geometry_reader"))

        // Trim history
        if scrollPositionHistory.count > 50 {
            scrollPositionHistory.removeFirst(scrollPositionHistory.count - 50)
        }
    }

    // MARK: - Rendered Height Tracking

    /// Called when a diff's actual rendered height is measured (via GeometryReader)
    func trackRenderedHeight(diffIndex: Int, sessionId: String, expectedHeight: CGFloat, actualHeight: CGFloat) {
        guard isEnabled else { return }

        let key = "\(sessionId)-\(diffIndex)"
        let now = CFAbsoluteTimeGetCurrent()

        // Check if height differs from expected
        let delta = actualHeight - expectedHeight
        if abs(delta) > 1 {
            print("📏 [ScrollDiag] RENDERED HEIGHT MISMATCH: diff \(diffIndex)")
            print("   Expected: \(expectedHeight), Actual: \(actualHeight) (Δ\(String(format: "%.1f", delta)))")

            os_signpost(.event, log: signpostLog, name: "RenderedHeightMismatch",
                       "diff=%d, expected=%.1f, actual=%.1f, delta=%.1f",
                       diffIndex, expectedHeight, actualHeight, delta)
        }

        // Check if height changed since last measurement
        if let previous = renderedHeights[key] {
            let heightChange = actualHeight - previous.actual
            if abs(heightChange) > 1 {
                print("📐 [ScrollDiag] DIFF HEIGHT CHANGED: diff \(diffIndex)")
                print("   Previous: \(previous.actual) → Current: \(actualHeight) (Δ\(String(format: "%.1f", heightChange)))")

                os_signpost(.event, log: signpostLog, name: "DiffHeightChanged",
                           "diff=%d, old=%.1f, new=%.1f, delta=%.1f",
                           diffIndex, previous.actual, actualHeight, heightChange)
            }
        }

        renderedHeights[key] = (expected: expectedHeight, actual: actualHeight, timestamp: now)
    }

    // MARK: - Scrollbar Thumb Position Tracking

    /// Track scrollbar thumb position to detect jumping during fast scrolling.
    /// thumbRatio is the scroll position as a ratio of total content (0.0 = top, 1.0 = bottom)
    func trackScrollbarThumbPosition(scrollY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, sessionId: String) {
        guard isEnabled else { return }

        // Calculate thumb position ratio
        let maxScroll = max(0, contentHeight - viewportHeight)
        let thumbRatio = maxScroll > 0 ? scrollY / maxScroll : 0

        let now = CFAbsoluteTimeGetCurrent()

        // Detect rapid thumb position changes (jumping)
        if !scrollbarThumbHistory.isEmpty {
            let lastEntry = scrollbarThumbHistory.last!
            let timeDelta = now - lastEntry.timestamp
            let ratioDelta = abs(thumbRatio - lastEntry.thumbRatio)
            let contentHeightDelta = abs(contentHeight - lastEntry.contentHeight)

            // If thumb position changed significantly (>5%) without proportional scrolling,
            // or if content height changed, that indicates scrollbar jumping
            if timeDelta < 0.1 && (ratioDelta > 0.05 || contentHeightDelta > 50) {
                print("⚠️ [ScrollDiag] SCROLLBAR THUMB JUMP DETECTED:")
                print("   Thumb ratio: \(String(format: "%.3f", lastEntry.thumbRatio)) → \(String(format: "%.3f", thumbRatio)) (Δ\(String(format: "%.3f", ratioDelta)))")
                print("   Content height: \(String(format: "%.1f", lastEntry.contentHeight)) → \(String(format: "%.1f", contentHeight)) (Δ\(String(format: "%.1f", contentHeightDelta)))")
                print("   Time delta: \(String(format: "%.0f", timeDelta * 1000))ms")

                os_signpost(.event, log: signpostLog, name: "ScrollbarThumbJump",
                           "ratio_delta=%.3f, height_delta=%.1f, time_delta=%.0fms",
                           ratioDelta, contentHeightDelta, timeDelta * 1000)
            }
        }

        // Store history
        scrollbarThumbHistory.append((timestamp: now, thumbRatio: thumbRatio, contentHeight: contentHeight))

        // Trim history to last 50 entries
        if scrollbarThumbHistory.count > 50 {
            scrollbarThumbHistory.removeFirst(scrollbarThumbHistory.count - 50)
        }

        lastScrollbarThumbRatio = thumbRatio
    }

    // MARK: - Summary Report

    /// Generate a summary of current scroll diagnostics state
    func generateReport() -> String {
        guard isEnabled else {
            return "ScrollDiagnostics is disabled. Set isEnabled = true to enable."
        }

        var report = """

        ╔══════════════════════════════════════════════════════════════╗
        ║              ScrollDiagnostics Report                         ║
        ╠══════════════════════════════════════════════════════════════╣

        Active DiffSections: \(activeDiffSections.count)
        Active Tiles: \(activeTiles.count)
        Scroll History Entries: \(scrollHistory.count)

        """

        // List active diff sections
        if !activeDiffSections.isEmpty {
            report += "\n── Active DiffSections ────────────────────────────────────────\n"
            for (_, info) in activeDiffSections.sorted(by: { $0.value.index < $1.value.index }) {
                let lifetime = CFAbsoluteTimeGetCurrent() - info.createdAt
                report += "  \(info.index): \(info.filename ?? "unknown")\n"
                report += "     Height: \(info.reportedHeight), Lines: \(info.lineCount)\n"
                report += "     Lifetime: \(String(format: "%.2f", lifetime))s\n"
                if info.heightHistory.count > 1 {
                    report += "     ⚠️ Height changed \(info.heightHistory.count - 1) times: \(info.heightHistory)\n"
                }
            }
        }

        // List active tiles
        if !activeTiles.isEmpty {
            report += "\n── Active Tiles ───────────────────────────────────────────────\n"
            for (_, info) in activeTiles.sorted(by: { ($0.value.diffIndex, $0.value.tileIndex) < ($1.value.diffIndex, $1.value.tileIndex) }) {
                report += "  Diff \(info.diffIndex), Tile \(info.tileIndex): lines \(info.startLine)-\(info.endLine), h=\(info.height)\n"
            }
        }

        // Height inconsistencies
        let inconsistencies = heightCalculations.filter { $0.value.count > 1 && Set($0.value.map { Int($0) }).count > 1 }
        if !inconsistencies.isEmpty {
            report += "\n── Height Inconsistencies ─────────────────────────────────────\n"
            for (id, heights) in inconsistencies {
                report += "  \(id): \(heights)\n"
            }
        }

        // Recycling stats
        let rapidRecyclers = recyclingEvents.filter { $0.value.count >= 3 }
        if !rapidRecyclers.isEmpty {
            report += "\n── Rapid Recycling Detected ───────────────────────────────────\n"
            for (key, events) in rapidRecyclers.sorted(by: { $0.value.count > $1.value.count }) {
                let appears = events.filter { $0.event == "appear" }.count
                let disappears = events.filter { $0.event == "disappear" }.count
                report += "  \(key): \(appears) appears, \(disappears) disappears\n"
            }
        }

        // Rendered height mismatches
        let mismatches = renderedHeights.filter { abs($0.value.actual - $0.value.expected) > 1 }
        if !mismatches.isEmpty {
            report += "\n── Rendered Height Mismatches ─────────────────────────────────\n"
            for (key, info) in mismatches {
                let delta = info.actual - info.expected
                report += "  \(key): expected \(info.expected), actual \(info.actual) (Δ\(delta))\n"
            }
        }

        // Scroll container height history
        if scrollContainerHeightHistory.count > 1 {
            report += "\n── Container Height History ───────────────────────────────────\n"
            for entry in scrollContainerHeightHistory.suffix(10) {
                report += "  \(entry.height)\n"
            }
        }

        report += "\n╚══════════════════════════════════════════════════════════════╝\n"

        return report
    }

    // MARK: - Reset

    /// Clear all tracked state
    func reset() {
        activeDiffSections.removeAll()
        activeTiles.removeAll()
        heightCalculations.removeAll()
        scrollHistory.removeAll()
        recyclingEvents.removeAll()
        scrollContainerHeightHistory.removeAll()
        scrollPositionHistory.removeAll()
        renderedHeights.removeAll()
        scrollbarThumbHistory.removeAll()
        lastScrollContainerHeight = 0
        lastScrollPosition = 0
        lastScrollbarThumbRatio = 0
    }
}
