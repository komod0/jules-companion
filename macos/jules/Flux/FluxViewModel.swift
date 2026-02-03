import Foundation
import Metal
import CoreGraphics
import SwiftUI
import Combine
import AppKit

// MARK: - NSColor to SIMD4<Float> Helper

extension NSColor {
    /// Convert NSColor to SIMD4<Float> for Metal rendering
    var simd4: SIMD4<Float> {
        guard let c = self.usingColorSpace(.sRGB) else {
            return SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
        }
        return SIMD4<Float>(
            Float(c.redComponent),
            Float(c.greenComponent),
            Float(c.blueComponent),
            Float(c.alphaComponent)
        )
    }
}

// MARK: - Scroll Performance Profiler

/// Simple profiler to measure scroll path performance
///
/// To enable profiling:
/// 1. In DEBUG builds: Set `ScrollProfiler.shared.enabled = true` anywhere, or
/// 2. Run in terminal: `defaults write com.app.jules ScrollProfilerEnabled -bool true`
/// 3. Or press Cmd+Shift+P in a diff view to toggle (requires adding the shortcut)
///
/// Output is printed to Xcode console every 60 scroll frames.
@MainActor
class ScrollProfiler {
    static let shared = ScrollProfiler()

    var enabled: Bool = {
        #if DEBUG
        // Check UserDefaults for persistent toggle
        return UserDefaults.standard.bool(forKey: "ScrollProfilerEnabled")
        #else
        return false
        #endif
    }()

    private var sampleCount = 0
    private let sampleInterval = 60  // Log every N samples

    /// Toggle profiling on/off (persists to UserDefaults in DEBUG)
    func toggle() {
        enabled.toggle()
        #if DEBUG
        UserDefaults.standard.set(enabled, forKey: "ScrollProfilerEnabled")
        #endif
        print("📊 Scroll Profiler: \(enabled ? "ENABLED" : "DISABLED")")
    }

    // Accumulated times (in milliseconds)
    private var setViewportTimes: [Double] = []
    private var updateTotalTimes: [Double] = []
    private var lineIterationTimes: [Double] = []
    private var updateInstancesTimes: [Double] = []
    private var bufferCreationTimes: [Double] = []
    private var memoryCopyTimes: [Double] = []

    // Line iteration sub-phase times (in milliseconds)
    private var lineSetupTimes: [Double] = []
    private var lineNumbersTimes: [Double] = []
    private var diffHighlightsTimes: [Double] = []
    private var selectionHighlightTimes: [Double] = []
    private var charRenderingTimes: [Double] = []

    // Instance counts
    private var instanceCounts: [Int] = []
    private var rectCounts: [Int] = []

    func record(
        setViewport: Double,
        updateTotal: Double,
        lineIteration: Double,
        updateInstances: Double,
        bufferCreation: Double,
        memoryCopy: Double,
        instanceCount: Int,
        rectCount: Int,
        // Line iteration sub-phases (optional for backwards compatibility)
        lineSetup: Double = 0,
        lineNumbers: Double = 0,
        diffHighlights: Double = 0,
        selectionHighlight: Double = 0,
        charRendering: Double = 0
    ) {
        guard enabled else { return }

        setViewportTimes.append(setViewport)
        updateTotalTimes.append(updateTotal)
        lineIterationTimes.append(lineIteration)
        updateInstancesTimes.append(updateInstances)
        bufferCreationTimes.append(bufferCreation)
        memoryCopyTimes.append(memoryCopy)
        instanceCounts.append(instanceCount)
        rectCounts.append(rectCount)

        // Record sub-phase times
        lineSetupTimes.append(lineSetup)
        lineNumbersTimes.append(lineNumbers)
        diffHighlightsTimes.append(diffHighlights)
        selectionHighlightTimes.append(selectionHighlight)
        charRenderingTimes.append(charRendering)

        sampleCount += 1
        if sampleCount >= sampleInterval {
            printStats()
            reset()
        }
    }

    private func printStats() {
        guard !setViewportTimes.isEmpty else { return }

        func stats(_ arr: [Double]) -> (avg: Double, max: Double, p95: Double) {
            let sorted = arr.sorted()
            let avg = arr.reduce(0, +) / Double(arr.count)
            let max = sorted.last ?? 0
            let p95Idx = Int(Double(sorted.count) * 0.95)
            let p95 = sorted[min(p95Idx, sorted.count - 1)]
            return (avg, max, p95)
        }

        let viewport = stats(setViewportTimes)
        let total = stats(updateTotalTimes)
        let iteration = stats(lineIterationTimes)
        let instances = stats(updateInstancesTimes)
        let bufCreate = stats(bufferCreationTimes)
        let memCopy = stats(memoryCopyTimes)

        // Line iteration sub-phases
        let lineSetup = stats(lineSetupTimes)
        let lineNums = stats(lineNumbersTimes)
        let diffHi = stats(diffHighlightsTimes)
        let selHi = stats(selectionHighlightTimes)
        let charRend = stats(charRenderingTimes)

        let avgInstances = instanceCounts.reduce(0, +) / max(1, instanceCounts.count)
        let avgRects = rectCounts.reduce(0, +) / max(1, rectCounts.count)

        print("""

        ═══════════════════════════════════════════════════════════
        SCROLL PROFILER (last \(sampleInterval) frames)
        ═══════════════════════════════════════════════════════════
        Phase                    Avg (ms)    P95 (ms)    Max (ms)
        ───────────────────────────────────────────────────────────
        setViewport              \(String(format: "%6.3f", viewport.avg))      \(String(format: "%6.3f", viewport.p95))      \(String(format: "%6.3f", viewport.max))
        update() total           \(String(format: "%6.3f", total.avg))      \(String(format: "%6.3f", total.p95))      \(String(format: "%6.3f", total.max))
          └─ line iteration      \(String(format: "%6.3f", iteration.avg))      \(String(format: "%6.3f", iteration.p95))      \(String(format: "%6.3f", iteration.max))
             ├─ line setup       \(String(format: "%6.3f", lineSetup.avg))      \(String(format: "%6.3f", lineSetup.p95))      \(String(format: "%6.3f", lineSetup.max))
             ├─ line numbers     \(String(format: "%6.3f", lineNums.avg))      \(String(format: "%6.3f", lineNums.p95))      \(String(format: "%6.3f", lineNums.max))
             ├─ diff highlights  \(String(format: "%6.3f", diffHi.avg))      \(String(format: "%6.3f", diffHi.p95))      \(String(format: "%6.3f", diffHi.max))
             ├─ selection        \(String(format: "%6.3f", selHi.avg))      \(String(format: "%6.3f", selHi.p95))      \(String(format: "%6.3f", selHi.max))
             └─ char rendering   \(String(format: "%6.3f", charRend.avg))      \(String(format: "%6.3f", charRend.p95))      \(String(format: "%6.3f", charRend.max))
        updateInstances()        \(String(format: "%6.3f", instances.avg))      \(String(format: "%6.3f", instances.p95))      \(String(format: "%6.3f", instances.max))
          └─ buffer creation     \(String(format: "%6.3f", bufCreate.avg))      \(String(format: "%6.3f", bufCreate.p95))      \(String(format: "%6.3f", bufCreate.max))
          └─ memory copy         \(String(format: "%6.3f", memCopy.avg))      \(String(format: "%6.3f", memCopy.p95))      \(String(format: "%6.3f", memCopy.max))
        ───────────────────────────────────────────────────────────
        Avg instances: \(avgInstances)  |  Avg rects: \(avgRects)
        ═══════════════════════════════════════════════════════════

        """)
    }

    private func reset() {
        sampleCount = 0
        setViewportTimes.removeAll()
        updateTotalTimes.removeAll()
        lineIterationTimes.removeAll()
        updateInstancesTimes.removeAll()
        bufferCreationTimes.removeAll()
        memoryCopyTimes.removeAll()
        instanceCounts.removeAll()
        rectCounts.removeAll()
        // Line iteration sub-phases
        lineSetupTimes.removeAll()
        lineNumbersTimes.removeAll()
        diffHighlightsTimes.removeAll()
        selectionHighlightTimes.removeAll()
        charRenderingTimes.removeAll()
    }
}

@MainActor
class FluxViewModel: ObservableObject {
    @Published var diffResult: DiffResult?
    @Published var isLoading: Bool = true

    // Selection state
    struct TextPosition: Equatable {
        let visualLineIndex: Int
        let charIndex: Int
    }
    @Published var selectionStart: TextPosition?
    @Published var selectionEnd: TextPosition?

    // Layout - dynamic line height based on font size
    var lineHeight: Float {
        return FontSizeManager.shared.diffLineHeight
    }
    private let gutterWidth: Float = 80.0
    private let contentOffsetX: Float = 10.0 // Content starts 10px after gutter

    // MARK: - Text Alignment Tuning
    // Adjust these values to fine-tune text alignment with backgrounds

    // baselineRatio: Where the text baseline sits within the line (0.0 = top, 1.0 = bottom)
    // Increase to move text down, decrease to move text up
    private let baselineRatio: Float = 0.78
    // Additional vertical offset in points (positive = down, negative = up)
    private let textVerticalOffset: Float = 5
    // Horizontal offset in points (positive = right, negative = left)
    // Compensates for glyph cell padding in the font atlas
    private let textHorizontalOffset: Float = -4

    // Subscription for font size changes
    private var fontSizeCancellable: AnyCancellable?

    // Virtualization
    private var visibleRange: Range<Float> = 0..<1000
    private var viewportHeight: Float = 1000

    // Total content height for scroll clamping
    var totalContentHeight: Float {
        return Float(visualLines.count) * lineHeight
    }

    // MARK: - Phase 2: LineManager for Layout Caching
    private let lineManager = LineManager()

    // MARK: - Phase 4: Differential Updates
    /// Tracks state to detect scroll-only changes
    private struct RenderState: Equatable {
        var scrollY: Float = 0
        var viewportHeight: Float = 0
        var lineCount: Int = 0
        var contentHash: Int = 0  // Hash of diff content for change detection
        var selectionStart: TextPosition?
        var selectionEnd: TextPosition?
    }
    private var lastRenderState = RenderState()

    /// Cached instance buffers for scroll-only updates
    private var cachedInstances: [InstanceData]?
    private var cachedRects: [RectInstance]?
    private var cachedVisibleRange: Range<Int>?

    /// Flag to force full regeneration
    private var needsFullRegen: Bool = true

    /// Generation counter for syntax parsing.
    /// Incremented on appearance changes to invalidate in-flight parsing results.
    /// This prevents race conditions where an older parsing (started before appearance change)
    /// could overwrite newer colors with stale values.
    private var syntaxParsingGeneration: Int = 0

    // State
    private let pieceTable: PieceTable

    // FIXED: Add cache size limit to prevent unbounded growth
    // Note: Syntax caches are relatively small (~15-20MB for 10k lines)
    // MEMORY FIX: Reduced from 50000 to 5000 to limit memory usage
    // For very large diffs, we trim aggressively to keep memory bounded
    private let maxCacheSize = 5000 // Lower threshold for better memory management
    private var tokenCache: [UUID: [StyledToken]] = [:]

    // Pre-computed character colors for O(1) lookup during rendering
    // Maps line UUID -> array of SIMD4<Float> colors, one per character
    // FIXED: Limited by maxCacheSize (same as tokenCache) to prevent unbounded growth
    private var charColorCache: [UUID: [SIMD4<Float>]] = [:]

    // Config
    let language: String

    // Temporary: Disable folding for diff view
    private let enableFolding: Bool = false

    struct VisualLine {
        let isFold: Bool
        let diffLineIndex: Int
        let foldCount: Int
    }

    private var visualLines: [VisualLine] = []

    init(original: String, added: String, language: String = "swift") {
        self.language = language
        self.pieceTable = PieceTable(original: original, added: added)
        // Initialize with empty result and trigger async load
        self.diffResult = nil
        self.performDiffAsync(original: original, added: added)
        self.setupFontSizeSubscription()
    }

    // New init for pre-computed result
    init(diffResult: DiffResult, language: String = "swift") {
        // Use language from DiffResult if available, otherwise use provided or default
        self.language = diffResult.language ?? language
        // PieceTable needs original/added. If they are empty in DiffResult (from patch),
        // editing won't work, but viewing is fine.
        self.pieceTable = PieceTable(original: diffResult.originalText, added: diffResult.newText)
        self.diffResult = diffResult
        self.isLoading = false
        self.visualLines = self.computeFolds(diff: diffResult, enableFolding: self.enableFolding)

        // Phase 2: Rebuild LineManager with new line count
        self.lineManager.rebuild(lineCount: self.visualLines.count, lineHeight: self.lineHeight)
        self.needsFullRegen = true

        // Trigger syntax parsing
        self.parseSyntaxAsync()
        self.setupFontSizeSubscription()
    }

    private func setupFontSizeSubscription() {
        // Subscribe to font size changes to trigger view updates
        // NOTE: Removed .receive(on: DispatchQueue.main) to eliminate async delay.
        // Since FluxViewModel is @MainActor and the publisher sends from main thread,
        // the sink closure executes synchronously, enabling immediate font size response.
        fontSizeCancellable = FontSizeManager.shared.diffFontSizeChanged
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Rebuild LineManager with new line height - this is critical!
                // Without this, lineManager.lineY() returns positions based on the old
                // cached line height, causing text to be mispositioned when font size changes.
                self.lineManager.rebuild(lineCount: self.visualLines.count, lineHeight: self.lineHeight)
                // CRITICAL: Recalculate visible range with new line height BEFORE triggering render.
                // Without this, the visible range (stored in pixels) is interpreted using the new
                // line height, causing incorrect line calculations. For example, if the old visible
                // range was 0..<2000px with lineHeight 20 (100 lines), and lineHeight increases to 25,
                // update() would calculate 2000/25=80 lines visible instead of 100, causing lines
                // at the bottom to not render. By calling setViewport, we recalculate visibleRange
                // using the stored viewportHeight and new lineHeight.
                self.setViewport(height: self.viewportHeight, scrollY: 0)
                // Invalidate render cache to force regeneration with new layout
                self.invalidateRenderCache()
                self.objectWillChange.send()
            }
    }

    private func performDiffAsync(original: String, added: String) {
        let enableFolding = self.enableFolding
        let currentLineHeight = self.lineHeight
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FluxDiffer.diff(oldText: original, newText: added)
            guard let self = self else { return }

            let folds = self.computeFolds(diff: result, enableFolding: enableFolding)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.diffResult = result
                self.visualLines = folds

                // Phase 2: Rebuild LineManager with new line count
                self.lineManager.rebuild(lineCount: folds.count, lineHeight: currentLineHeight)
                self.needsFullRegen = true

                // OPTIMIZATION: isLoading is @Published, so setting it automatically
                // sends objectWillChange - no need to call it again manually
                self.isLoading = false

                // Trigger Syntax Parsing after Diff is ready
                self.parseSyntaxAsync()
            }
        }
    }

    nonisolated private func computeFolds(diff: DiffResult, enableFolding: Bool) -> [VisualLine] {
        var visual = [VisualLine]()
        let threshold = 5

        var i = 0
        while i < diff.lines.count {
            let line = diff.lines[i]

            // Never fold file headers or spacers
            if line.type == .fileHeader || line.type == .spacer {
                visual.append(VisualLine(isFold: false, diffLineIndex: i, foldCount: 0))
                i += 1
                continue
            }

            if enableFolding && line.type == .common {
                var run = 0
                var j = i
                // Don't fold across file headers or spacers
                while j < diff.lines.count && diff.lines[j].type == .common {
                    run += 1
                    j += 1
                }

                if run > threshold {
                    visual.append(VisualLine(isFold: true, diffLineIndex: i, foldCount: run))
                    i += run
                    continue
                }
            }

            visual.append(VisualLine(isFold: false, diffLineIndex: i, foldCount: 0))
            i += 1
        }
        return visual
    }

    /// Phase 4: Optimized viewport culling using LineManager
    /// Determines which lines need to be rendered based on scroll position
    /// Uses generous buffering for smooth scrolling without pop-in
    func setViewport(height: Float, scrollY: Float) {
        let start = CACurrentMediaTime()

        self.viewportHeight = height

        let totalHeight = Float(visualLines.count) * lineHeight

        // FAST SCROLL FIX: Clamp scroll position to valid content bounds
        // During fast scrollbar dragging, scroll position can momentarily exceed bounds
        // which causes invalid visible range calculations and visual artifacts
        let maxScrollY = max(0, totalHeight - height)
        let clampedScrollY = max(0, min(scrollY, maxScrollY))

        // IMPORTANT: Detect if view is sized to show all content (embedded in parent ScrollView)
        // When the view height equals or exceeds total content height, render ALL lines
        // This fixes the issue where virtualization renders only a subset of lines
        // when the diff view is inside a SwiftUI ScrollView that handles scrolling
        // (in that case, scrollY is always 0 because the parent handles scrolling)
        //
        // FAST SCROLL FIX: Also treat as full-height when height is 0 or very small
        // During rapid tile creation in LazyVStack, view.bounds.height may be 0 initially
        // Rendering all content prevents partial renders that cause "space at top/bottom"
        let isFullHeightView = height >= totalHeight || height <= lineHeight || visualLines.count == 0

        // Phase 2: Use LineManager for O(1) visible range lookup
        let viewportTop = clampedScrollY
        let viewportBottom = clampedScrollY + height

        // Get visible line range from LineManager (includes buffer)
        // If full-height view, render all lines
        let visibleLineRange: Range<Int>
        if isFullHeightView {
            // Render all lines when view is sized to show all content
            visibleLineRange = 0..<visualLines.count
        } else {
            visibleLineRange = lineManager.visibleLineRange(
                viewportTop: viewportTop,
                viewportBottom: viewportBottom,
                buffer: max(50, Int(ceil(height / lineHeight)))
            )
        }

        // Convert to pixel range for compatibility
        // FAST SCROLL FIX: Handle empty range and edge cases properly
        let rangeStart: Float
        let rangeEnd: Float
        if visibleLineRange.isEmpty {
            rangeStart = 0
            rangeEnd = totalHeight
        } else {
            rangeStart = lineManager.lineY(visibleLineRange.lowerBound)
            // upperBound is exclusive, so we need upperBound - 1 for the last visible line
            let lastLineIndex = min(visibleLineRange.upperBound - 1, lineManager.lineCount - 1)
            rangeEnd = lastLineIndex >= 0 ? lineManager.lineY(lastLineIndex) + lineHeight : totalHeight
        }
        self.visibleRange = rangeStart..<max(rangeStart, rangeEnd)

        // Track viewport changes for diagnostics
        ScrollDiagnostics.shared.viewportChanged(
            scrollY: CGFloat(clampedScrollY),
            viewportHeight: CGFloat(height),
            totalContentHeight: CGFloat(totalHeight),
            visibleRange: visibleLineRange
        )

        // Phase 4: Check if we can reuse cached instances (scroll-only change)
        let newState = RenderState(
            scrollY: scrollY,
            viewportHeight: height,
            lineCount: visualLines.count,
            contentHash: diffResult?.lines.count ?? 0,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd
        )

        // Determine if this is a scroll-only change
        if !needsFullRegen &&
           cachedInstances != nil &&
           newState.lineCount == lastRenderState.lineCount &&
           newState.contentHash == lastRenderState.contentHash &&
           newState.selectionStart == lastRenderState.selectionStart &&
           newState.selectionEnd == lastRenderState.selectionEnd {
            // Check if new visible range is subset of cached range
            if let cachedRange = cachedVisibleRange,
               visibleLineRange.lowerBound >= cachedRange.lowerBound &&
               visibleLineRange.upperBound <= cachedRange.upperBound {
                // Scroll-only: can reuse cached buffers, just update uniforms
                lastRenderState = newState
                lastProfilingSetViewportTime = (CACurrentMediaTime() - start) * 1000
                return
            }
        }

        // Need to regenerate - visible range changed, invalidate cached instances
        // This is crucial: when the visible range expands beyond the cached range,
        // we must regenerate the instance buffers to include the new lines
        lastRenderState = newState
        cachedVisibleRange = visibleLineRange
        cachedInstances = nil  // Force regeneration in update()
        cachedRects = nil

        // Record for profiling
        lastProfilingSetViewportTime = (CACurrentMediaTime() - start) * 1000  // ms
    }

    /// Force a full regeneration of instance buffers (call after content changes)
    func invalidateRenderCache() {
        needsFullRegen = true
        cachedInstances = nil
        cachedRects = nil
        cachedVisibleRange = nil
    }

    /// Called when the system appearance (light/dark mode) changes.
    /// This clears the syntax color cache since colors were computed for the old appearance,
    /// then triggers re-parsing of syntax with new colors.
    func invalidateForAppearanceChange() {
        // Increment generation to invalidate any in-flight syntax parsing.
        // This prevents a race condition where parsing started before the appearance change
        // could complete after our new parsing and overwrite the cache with stale colors.
        syntaxParsingGeneration += 1

        // Clear syntax color cache - colors were computed for the old appearance
        charColorCache.removeAll()
        tokenCache.removeAll()

        // Clear the render cache to force regeneration with new colors
        invalidateRenderCache()

        // Trigger immediate re-render for background colors.
        // Since charColorCache is cleared, syntax will use default text color temporarily.
        // When parsing completes, another objectWillChange.send() will update syntax colors.
        objectWillChange.send()

        // Re-parse syntax highlighting with new appearance.
        if diffResult != nil {
            parseSyntaxAsync()
        }
    }

    // Profiling state - stored to pass to renderer
    var lastProfilingSetViewportTime: Double = 0

    func update(renderer: FluxRenderer) {
        let updateStart = CACurrentMediaTime()

        guard let diff = diffResult, !isLoading else {
            renderer.updateInstances([], rects: [], profilingSetViewportTime: 0)
            return
        }

        // SYNC FIX: Detect lineHeight changes that the async Combine subscription hasn't processed yet.
        // When font size changes, SwiftUI re-renders synchronously but our Combine subscription
        // (.receive(on: DispatchQueue.main)) fires asynchronously. This can cause a race where
        // SwiftUI creates views with NEW lineHeight but LineManager still has OLD lineHeight.
        // By checking here, we catch this race and rebuild immediately before rendering.
        let currentLineHeight = self.lineHeight
        if lineManager.lineHeight != currentLineHeight {
            lineManager.rebuild(lineCount: visualLines.count, lineHeight: currentLineHeight)
            setViewport(height: viewportHeight, scrollY: 0)
            invalidateRenderCache()
            // Reset cached state to force regeneration with new line height
            needsFullRegen = true
        }

        // Phase 4: Check if we can use cached instances (scroll-only update)
        // FIXED: Also verify the current visible range is actually covered by cached range
        // This prevents using stale cache when scrolling back up after scrolling down
        if !needsFullRegen,
           let cached = cachedInstances,
           let cachedR = cachedRects,
           let cachedRange = cachedVisibleRange {
            // Calculate current visible range to verify it's covered by cache
            let currentVisibleRange = lineManager.visibleLineRange(
                viewportTop: visibleRange.lowerBound,
                viewportBottom: visibleRange.upperBound,
                buffer: 0
            )

            // Only use cache if current range is fully within cached range
            if currentVisibleRange.lowerBound >= cachedRange.lowerBound &&
               currentVisibleRange.upperBound <= cachedRange.upperBound {
                // Scroll-only change: reuse existing buffers, just update uniforms
                // The renderer will handle the scroll offset via uniforms
                renderer.updateInstances(
                    cached,
                    rects: cachedR,
                    profilingSetViewportTime: lastProfilingSetViewportTime,
                    profilingUpdateStart: updateStart,
                    profilingLineIterationTime: 0,  // No iteration needed
                    profilingLineSetupTime: 0,
                    profilingLineNumbersTime: 0,
                    profilingDiffHighlightsTime: 0,
                    profilingSelectionTime: 0,
                    profilingCharRenderingTime: 0
                )
                return
            }
            // Current range not covered by cache - fall through to regenerate
        }

        // Reset the full regen flag
        needsFullRegen = false

        let atlas = renderer.fontAtlasManager

        // Phase 4: Use cached monoAdvance for O(1) lookup
        let monoAdvance: Float = atlas.monoAdvance

        // Phase 2: Use LineManager for visible line range
        let visibleLineRange = lineManager.visibleLineRange(
            viewportTop: visibleRange.lowerBound,
            viewportBottom: visibleRange.upperBound,
            buffer: 0  // Already buffered in setViewport
        )

        let validStart = visibleLineRange.lowerBound
        let validEnd = visibleLineRange.upperBound

        if validStart >= validEnd {
             renderer.updateInstances([], rects: [], profilingSetViewportTime: 0)
             return
        }

        // Phase 4: Pre-allocate arrays with estimated capacity to reduce reallocations
        // Estimate: average 40 chars per line, plus 2-3 rects per line
        let estimatedLines = validEnd - validStart
        let estimatedCharsPerLine = 40
        var instances: [InstanceData] = []
        instances.reserveCapacity(estimatedLines * estimatedCharsPerLine)
        var rects: [RectInstance] = []
        rects.reserveCapacity(estimatedLines * 3)

        let lineIterationStart = CACurrentMediaTime()

        // Sub-phase timing accumulators (in seconds, converted to ms at the end)
        var lineSetupTime: Double = 0
        var lineNumbersTime: Double = 0
        var diffHighlightsTime: Double = 0
        var selectionHighlightTime: Double = 0
        var charRenderingTime: Double = 0

        // Colors - adaptive based on appearance (ayu-theme for light mode)
        let colAdded = AppColors.diffEditorAddedBg.simd4
        let colRemoved = AppColors.diffEditorRemovedBg.simd4
        let colTextDefault = AppColors.diffEditorText.simd4
        let colGutterText = AppColors.diffEditorGutter.simd4
        let colHighlight = AppColors.diffEditorHighlight.simd4
        let colFold = AppColors.diffEditorFold.simd4
        let colSelection = AppColors.diffEditorSelection.simd4
        let colFileHeaderBg = AppColors.diffEditorFileHeaderBg.simd4
        let colFileHeaderText = AppColors.diffEditorFileHeaderText.simd4
        let colModifiedIndicator = AppColors.diffEditorModifiedIndicator.simd4
        let colAddedText = AppColors.diffEditorAddedText.simd4
        let colRemovedText = AppColors.diffEditorRemovedText.simd4
        let colGutterSeparator = AppColors.diffEditorGutterSeparator.simd4

        // Normalize selection range if exists
        var normalizedSelStart: TextPosition?
        var normalizedSelEnd: TextPosition?
        if let start = selectionStart, let end = selectionEnd {
            if start.visualLineIndex < end.visualLineIndex ||
               (start.visualLineIndex == end.visualLineIndex && start.charIndex <= end.charIndex) {
                normalizedSelStart = start
                normalizedSelEnd = end
            } else {
                normalizedSelStart = end
                normalizedSelEnd = start
            }
        }

        // Gutter separator line - always draw full height to prevent gaps during fast scrolling
        // Using totalContentHeight instead of visibleRange ensures the separator is never cut off
        rects.append(RectInstance(
            origin: [gutterWidth - 2, 0],
            size: [1, totalContentHeight],
            color: colGutterSeparator
        ))

        for vIdx in validStart..<validEnd {
            let vLine = visualLines[vIdx]
            // Phase 2: Use LineManager for O(1) Y position lookup
            let currentY: Float = lineManager.lineY(vIdx)

            // PIXEL-PERFECT FIX: Compute next line's Y position once per line iteration.
            // Using the difference (nextLineY - currentY) for background heights ensures
            // adjacent line backgrounds share exact edges, preventing sub-pixel gaps
            // caused by floating-point rasterization errors in Metal.
            let nextLineY = vIdx + 1 < lineManager.lineCount ? lineManager.lineY(vIdx + 1) : totalContentHeight
            let effectiveLineHeight = nextLineY - currentY

            if vLine.isFold {
                // Render fold indicator
                rects.append(RectInstance(
                    origin: [0, currentY],
                    size: [1500, effectiveLineHeight],
                    color: colFold
                ))

                // Fold text "... (N lines)"
                let text = "... (\(vLine.foldCount) lines)"
                var x: Float = floor(gutterWidth + contentOffsetX)
                let baselineY = floor(currentY + (lineHeight * baselineRatio) + textVerticalOffset)
                let asciiGlyphs = atlas.asciiGlyphs

                for char in text {
                    let descriptor: FontAtlasManager.GlyphDescriptor?
                    if let asciiValue = char.asciiValue, asciiValue < 128 {
                        descriptor = asciiGlyphs[Int(asciiValue)]
                    } else if let glyphIndex = atlas.charToGlyph[char] {
                        descriptor = atlas.glyphDescriptors[glyphIndex]
                    } else {
                        descriptor = nil
                    }

                    if let descriptor = descriptor {
                        let charBaselineY = baselineY - descriptor.sizeFloat.y
                        instances.append(InstanceData(
                            origin: [floor(x + textHorizontalOffset), charBaselineY],
                            size: descriptor.sizeFloat,
                            uvMin: descriptor.uvMin,
                            uvMax: descriptor.uvMax,
                            color: colGutterText
                        ))
                        x += descriptor.advanceFloat
                    } else {
                        x += monoAdvance
                    }
                }
                continue
            }

            let line = diff.lines[vLine.diffLineIndex]

            // FILE HEADER RENDERING
            if line.type == .fileHeader {
                // Background for entire header (use effectiveLineHeight for consistency)
                rects.append(RectInstance(
                    origin: [0, currentY],
                    size: [1500, effectiveLineHeight],
                    color: colFileHeaderBg
                ))

                var x: Float = floor(gutterWidth + contentOffsetX)
                let baselineY = floor(currentY + (lineHeight * baselineRatio) + textVerticalOffset)
                let asciiGlyphs = atlas.asciiGlyphs

                // Helper to get glyph descriptor with ASCII fast-path
                func getGlyph(_ char: Character) -> FontAtlasManager.GlyphDescriptor? {
                    if let asciiValue = char.asciiValue, asciiValue < 128 {
                        return asciiGlyphs[Int(asciiValue)]
                    } else if let glyphIndex = atlas.charToGlyph[char] {
                        return atlas.glyphDescriptors[glyphIndex]
                    }
                    return nil
                }

                // Render "M" indicator if file was modified (not new)
                if !line.isNewFile && ((line.linesAdded ?? 0) > 0 || (line.linesRemoved ?? 0) > 0) {
                    if let descriptor = getGlyph("M") {
                        let charBaselineY = baselineY - descriptor.sizeFloat.y
                        instances.append(InstanceData(
                            origin: [floor(x + textHorizontalOffset), charBaselineY],
                            size: descriptor.sizeFloat,
                            uvMin: descriptor.uvMin,
                            uvMax: descriptor.uvMax,
                            color: colModifiedIndicator
                        ))
                        x += descriptor.advanceFloat + 10.0
                    }
                }

                // Render filename
                if let fileName = line.fileName {
                    for char in fileName {
                        if let descriptor = getGlyph(char) {
                            let charBaselineY = baselineY - descriptor.sizeFloat.y
                            instances.append(InstanceData(
                                origin: [floor(x + textHorizontalOffset), charBaselineY],
                                size: descriptor.sizeFloat,
                                uvMin: descriptor.uvMin,
                                uvMax: descriptor.uvMax,
                                color: colFileHeaderText
                            ))
                            x += descriptor.advanceFloat
                        } else {
                            x += monoAdvance
                        }
                    }
                }

                // Render stats (+N -M)
                if let added = line.linesAdded, let removed = line.linesRemoved {
                    x += 20.0 // Spacing

                    // Render "+N" in green
                    let addedStr = "+\(added)"
                    for char in addedStr {
                        if let descriptor = getGlyph(char) {
                            let charBaselineY = baselineY - descriptor.sizeFloat.y
                            instances.append(InstanceData(
                                origin: [floor(x + textHorizontalOffset), charBaselineY],
                                size: descriptor.sizeFloat,
                                uvMin: descriptor.uvMin,
                                uvMax: descriptor.uvMax,
                                color: colAddedText
                            ))
                            x += descriptor.advanceFloat
                        } else {
                            x += monoAdvance
                        }
                    }

                    x += 10.0 // Spacing

                    // Render "-M" in red
                    let removedStr = "-\(removed)"
                    for char in removedStr {
                        if let descriptor = getGlyph(char) {
                            let charBaselineY = baselineY - descriptor.sizeFloat.y
                            instances.append(InstanceData(
                                origin: [floor(x + textHorizontalOffset), charBaselineY],
                                size: descriptor.sizeFloat,
                                uvMin: descriptor.uvMin,
                                uvMax: descriptor.uvMax,
                                color: colRemovedText
                            ))
                            x += descriptor.advanceFloat
                        } else {
                            x += monoAdvance
                        }
                    }
                }

                continue
            }

            // SPACER RENDERING
            if line.type == .spacer {
                // Just render empty space - no background, no text
                continue
            }

            // NORMAL LINE RENDERING
            // Sub-phase 1: Line setup (array conversion, baseline, background)
            let lineSetupStart = CACurrentMediaTime()
            let chars = Array(line.content)
            let baselineY = floor(currentY + (lineHeight * baselineRatio) + textVerticalOffset)

            // Line Background
            // Use effectiveLineHeight (computed at top of loop) to ensure backgrounds share exact edges
            let bgColor = line.type == .added ? colAdded : (line.type == .removed ? colRemoved : SIMD4<Float>(0, 0, 0, 0))
            if line.type != .common {
                rects.append(RectInstance(
                    origin: [0, currentY],
                    size: [1500, effectiveLineHeight],
                    color: bgColor
                ))
            }
            lineSetupTime += CACurrentMediaTime() - lineSetupStart

            // Sub-phase 2: Line Numbers (pixel aligned)
            let lineNumbersStart = CACurrentMediaTime()
            // OPTIMIZATION: Line numbers are always digits (ASCII), use fast-path with pre-computed Floats
            let asciiGlyphsForGutter = atlas.asciiGlyphs
            var gutterX: Float = 10.0

            if let oldNum = line.originalLineNumber {
                let text = String(oldNum)
                for char in text {
                    // Digits are always ASCII, use direct array lookup with pre-computed Floats
                    if let asciiValue = char.asciiValue,
                       let descriptor = asciiGlyphsForGutter[Int(asciiValue)] {
                        let charBaselineY = baselineY - descriptor.sizeFloat.y
                        instances.append(InstanceData(
                            origin: [floor(gutterX + textHorizontalOffset), charBaselineY],
                            size: descriptor.sizeFloat,
                            uvMin: descriptor.uvMin,
                            uvMax: descriptor.uvMax,
                            color: colGutterText
                        ))
                        gutterX += descriptor.advanceFloat
                    }
                }
            }

            gutterX = 40.0
            if let newNum = line.newLineNumber {
                let text = String(newNum)
                for char in text {
                    // Digits are always ASCII, use direct array lookup with pre-computed Floats
                    if let asciiValue = char.asciiValue,
                       let descriptor = asciiGlyphsForGutter[Int(asciiValue)] {
                        let charBaselineY = baselineY - descriptor.sizeFloat.y
                        instances.append(InstanceData(
                            origin: [floor(gutterX + textHorizontalOffset), charBaselineY],
                            size: descriptor.sizeFloat,
                            uvMin: descriptor.uvMin,
                            uvMax: descriptor.uvMax,
                            color: colGutterText
                        ))
                        gutterX += descriptor.advanceFloat
                    }
                }
            }
            lineNumbersTime += CACurrentMediaTime() - lineNumbersStart

            // Sub-phase 3: Character-level diff highlights (for modified lines)
            let diffHighlightsStart = CACurrentMediaTime()
            // OPTIMIZATION: Instead of checking every character, iterate through change ranges directly
            if let changes = line.tokenChanges, !changes.isEmpty {
                for range in changes {
                    let startX = floor(gutterWidth + contentOffsetX + Float(range.lowerBound) * monoAdvance)
                    let rangeWidth = floor(Float(range.count) * monoAdvance)
                    rects.append(RectInstance(
                        origin: [startX, currentY],
                        size: [rangeWidth, effectiveLineHeight],
                        color: colHighlight
                    ))
                }
            }
            diffHighlightsTime += CACurrentMediaTime() - diffHighlightsStart

            // Sub-phase 4: Render selection highlight
            let selectionStart = CACurrentMediaTime()
            if let selStart = normalizedSelStart, let selEnd = normalizedSelEnd {
                if vIdx >= selStart.visualLineIndex && vIdx <= selEnd.visualLineIndex {
                    var startChar = 0
                    var endChar = chars.count

                    if vIdx == selStart.visualLineIndex {
                        startChar = min(selStart.charIndex, chars.count)
                    }
                    if vIdx == selEnd.visualLineIndex {
                        endChar = min(selEnd.charIndex, chars.count)
                    }

                    if startChar < endChar {
                        let selX = floor(gutterWidth + contentOffsetX + Float(startChar) * monoAdvance)
                        let selWidth = floor(Float(endChar - startChar) * monoAdvance)

                        rects.append(RectInstance(
                            origin: [selX, currentY],
                            size: [selWidth, effectiveLineHeight],
                            color: colSelection
                        ))
                    }
                }
            }
            selectionHighlightTime += CACurrentMediaTime() - selectionStart

            // Sub-phase 5: Draw text with syntax highlighting (using pre-computed colors for O(1) lookup)
            let charRenderingStart = CACurrentMediaTime()
            let cachedColors = charColorCache[line.id]
            var x: Float = floor(gutterWidth + contentOffsetX)
            let asciiGlyphs = atlas.asciiGlyphs  // Cache reference for faster access

            // OPTIMIZATION: Use index-based iteration (faster than enumerated())
            for charIndex in chars.indices {
                let char = chars[charIndex]

                // OPTIMIZATION: Skip whitespace - spaces/tabs are invisible and common
                if char == " " {
                    x += monoAdvance
                    continue
                } else if char == "\t" {
                    x += monoAdvance * 4  // Tabs are typically 4 spaces
                    continue
                }

                // Use pre-computed color if available, otherwise default
                let color = cachedColors?[charIndex] ?? colTextDefault

                // OPTIMIZATION: Use ASCII fast-path for O(1) lookup (most code is ASCII)
                let descriptor: FontAtlasManager.GlyphDescriptor?
                if let asciiValue = char.asciiValue, asciiValue < 128 {
                    descriptor = asciiGlyphs[Int(asciiValue)]
                } else if let glyphIndex = atlas.charToGlyph[char] {
                    descriptor = atlas.glyphDescriptors[glyphIndex]
                } else {
                    descriptor = nil
                }

                if let descriptor = descriptor {
                    // OPTIMIZATION: Use pre-computed Float values (no CGFloat->Float conversion)
                    let charBaselineY = baselineY - descriptor.sizeFloat.y

                    instances.append(InstanceData(
                        origin: [floor(x + textHorizontalOffset), charBaselineY],
                        size: descriptor.sizeFloat,
                        uvMin: descriptor.uvMin,
                        uvMax: descriptor.uvMax,
                        color: color
                    ))
                    x += descriptor.advanceFloat
                } else {
                    x += monoAdvance
                }
            }
            charRenderingTime += CACurrentMediaTime() - charRenderingStart
        }

        let lineIterationEnd = CACurrentMediaTime()
        let lineIterationTime = (lineIterationEnd - lineIterationStart) * 1000  // ms

        // Phase 4: Cache instances for scroll-only updates
        // Store a copy so future scroll-only changes can reuse the buffer
        self.cachedInstances = instances
        self.cachedRects = rects
        self.cachedVisibleRange = validStart..<validEnd

        renderer.updateInstances(
            instances,
            rects: rects,
            profilingSetViewportTime: lastProfilingSetViewportTime,
            profilingUpdateStart: updateStart,
            profilingLineIterationTime: lineIterationTime,
            profilingLineSetupTime: lineSetupTime * 1000,
            profilingLineNumbersTime: lineNumbersTime * 1000,
            profilingDiffHighlightsTime: diffHighlightsTime * 1000,
            profilingSelectionTime: selectionHighlightTime * 1000,
            profilingCharRenderingTime: charRenderingTime * 1000
        )
    }

    /// Returns the priority for a token scope (higher = applied last, wins over lower priority)
    /// This ensures proper layering: comments > strings > keywords > functions > types > numbers > variables
    nonisolated private static func tokenPriority(for scope: String) -> Int {
        // Lowest priority first (will be overwritten)
        if scope.contains("variable") || scope.contains("identifier") { return 0 }
        if scope.contains("property") { return 1 }
        if scope.contains("type") { return 2 }
        if scope.contains("function") || scope.contains("method") { return 3 }
        if scope.contains("number") || scope.contains("boolean") { return 4 }
        if scope.contains("keyword") || scope.contains("operator") { return 5 }
        if scope.contains("string") { return 6 }
        // Highest priority (comments should never be overwritten)
        if scope.contains("comment") { return 7 }
        return 0 // Default to lowest priority for unknown scopes
    }

    private func parseSyntaxAsync() {
        guard let diff = diffResult else { return }

        // Capture the current generation to detect if this parsing becomes stale.
        // If appearance changes while we're parsing, the generation will increment
        // and we should discard our results to avoid overwriting newer colors.
        let parsingGeneration = syntaxParsingGeneration

        let lines = diff.lines
        let lang = self.language

        // Phase 1: Check SharedSyntaxCache for already-parsed lines (on main thread)
        // This prevents re-parsing when tiles are recycled during fast scrolling
        let contentLines = lines.filter { $0.type != .fileHeader && $0.type != .spacer }
        let sharedCache = SharedSyntaxCache.shared

        // Check which lines are already in the shared cache
        var cachedResults: [UUID: (tokens: [StyledToken], colors: [SIMD4<Float>])] = [:]
        var uncachedLines: [(index: Int, line: DiffLine)] = []

        for (index, line) in contentLines.enumerated() {
            guard line.content.count > 0 else { continue }
            if let cached = sharedCache.get(content: line.content, language: lang) {
                cachedResults[line.id] = cached
            } else {
                uncachedLines.append((index, line))
            }
        }

        // If all lines are cached, use them directly without background parsing
        if uncachedLines.isEmpty {
            self.tokenCache = cachedResults.mapValues { $0.tokens }
            self.charColorCache = cachedResults.mapValues { $0.colors }

            if self.tokenCache.count > self.maxCacheSize || self.charColorCache.count > self.maxCacheSize {
                self.trimCachesToVisibleRange()
            }

            self.invalidateRenderCache()
            self.objectWillChange.send()
            return
        }

        // FIXED: Pre-populate charColorCache with cached results BEFORE background parsing
        // This ensures lines found in SharedSyntaxCache have colors available immediately
        // for rendering, rather than waiting for background parsing to complete.
        // Without this, there's a window where some lines have cached colors (from previous
        // updateSyntaxHighlighting calls) and some don't, causing inconsistent highlighting.
        for (id, cached) in cachedResults {
            self.charColorCache[id] = cached.colors
            self.tokenCache[id] = cached.tokens
        }

        // FIXED: Capture the current appearance BEFORE going to background thread.
        // NSColor dynamic providers need NSAppearance.current to resolve correctly.
        // Background threads don't inherit the app's appearance, causing wrong colors.
        let currentAppearance = NSApp.effectiveAppearance
        let isDarkMode = currentAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil

        // Phase 2: Parse uncached lines in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self, currentAppearance, isDarkMode] in
            // Set the appearance for this thread so NSColor resolves correctly
            NSAppearance.current = currentAppearance
            var newCache: [UUID: [StyledToken]] = [:]
            var newColorCache: [UUID: [SIMD4<Float>]] = [:]

            // Start with cached results
            for (id, cached) in cachedResults {
                newCache[id] = cached.tokens
                newColorCache[id] = cached.colors
            }

            // Create parser instance for this background task (tree-sitter isn't thread-safe)
            let parser = FluxParser()
            // Use adaptive default text color
            let defaultColor = AppColors.diffEditorText.simd4

            // Build full text from all line contents for bulk parsing
            // This is more efficient (single parse) and handles multi-line constructs better
            let fullText = contentLines.map { $0.content }.joined(separator: "\n")

            // Parse the full text at once - returns tokens mapped to line indices
            let lineTokens = parser.parseFullContent(text: fullText, languageName: lang)

            // Entries to add to shared cache
            var newSharedCacheEntries: [(content: String, id: UUID, tokens: [StyledToken], colors: [SIMD4<Float>])] = []

            // Helper function to build UTF-16 to grapheme cluster mapping
            func buildUtf16ToGraphemeMapping(for content: String) -> [Int] {
                var mapping: [Int] = []
                mapping.reserveCapacity(content.utf16.count + 1)
                var graphemeIdx = 0
                for char in content {
                    let utf16Count = char.utf16.count
                    for _ in 0..<utf16Count {
                        mapping.append(graphemeIdx)
                    }
                    graphemeIdx += 1
                }
                // Add sentinel for end-of-string
                mapping.append(graphemeIdx)
                return mapping
            }

            // Map parsed tokens back to diff lines (only for uncached lines)
            for (contentIndex, line) in uncachedLines {
                let content = line.content
                let graphemeCount = content.count  // Grapheme cluster count
                guard graphemeCount > 0 else { continue }

                if let tokens = lineTokens[contentIndex], !tokens.isEmpty {
                    newCache[line.id] = tokens

                    // Build UTF-16 to grapheme cluster mapping
                    // Token ranges from FluxParser are in UTF-16 code units, but rendering
                    // iterates over Characters (grapheme clusters)
                    let utf16ToGrapheme = buildUtf16ToGraphemeMapping(for: content)

                    // Sort tokens by priority so higher-priority tokens (comments, strings)
                    // are applied last and overwrite lower-priority tokens (variables, identifiers)
                    let sortedTokens = tokens.sorted { token1, token2 in
                        FluxViewModel.tokenPriority(for: token1.scope) < FluxViewModel.tokenPriority(for: token2.scope)
                    }

                    // Pre-compute per-character colors for O(1) lookup during render
                    var colors = [SIMD4<Float>](repeating: defaultColor, count: graphemeCount)
                    for token in sortedTokens {
                        if let c = token.color.usingColorSpace(.sRGB) {
                            let simdColor = SIMD4<Float>(
                                Float(c.redComponent),
                                Float(c.greenComponent),
                                Float(c.blueComponent),
                                Float(c.alphaComponent)
                            )
                            // Convert UTF-16 range to grapheme cluster range
                            let utf16Start = token.range.location
                            let utf16End = token.range.location + token.range.length
                            let start = utf16Start < utf16ToGrapheme.count ? utf16ToGrapheme[utf16Start] : graphemeCount
                            let end = utf16End < utf16ToGrapheme.count ? utf16ToGrapheme[utf16End] : graphemeCount
                            for i in start..<end {
                                colors[i] = simdColor
                            }
                        }
                    }
                    newColorCache[line.id] = colors

                    // Queue for shared cache
                    newSharedCacheEntries.append((line.content, line.id, tokens, colors))
                } else if !line.content.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Fallback: parse individual line if bulk parsing missed it
                    let tokens = parser.parse(text: line.content, languageName: lang)
                    if !tokens.isEmpty {
                        newCache[line.id] = tokens

                        // Build UTF-16 to grapheme cluster mapping for fallback path
                        let utf16ToGrapheme = buildUtf16ToGraphemeMapping(for: content)

                        let sortedTokens = tokens.sorted { token1, token2 in
                            FluxViewModel.tokenPriority(for: token1.scope) < FluxViewModel.tokenPriority(for: token2.scope)
                        }

                        var colors = [SIMD4<Float>](repeating: defaultColor, count: graphemeCount)
                        for token in sortedTokens {
                            if let c = token.color.usingColorSpace(.sRGB) {
                                let simdColor = SIMD4<Float>(
                                    Float(c.redComponent),
                                    Float(c.greenComponent),
                                    Float(c.blueComponent),
                                    Float(c.alphaComponent)
                                )
                                // Convert UTF-16 range to grapheme cluster range
                                let utf16Start = token.range.location
                                let utf16End = token.range.location + token.range.length
                                let start = utf16Start < utf16ToGrapheme.count ? utf16ToGrapheme[utf16Start] : graphemeCount
                                let end = utf16End < utf16ToGrapheme.count ? utf16ToGrapheme[utf16End] : graphemeCount
                                for i in start..<end {
                                    colors[i] = simdColor
                                }
                            }
                        }
                        newColorCache[line.id] = colors

                        // Queue for shared cache
                        newSharedCacheEntries.append((line.content, line.id, tokens, colors))
                    }
                }
            }

            DispatchQueue.main.async { [weak self, isDarkMode] in
                guard let self = self else { return }

                // Check if this parsing is still current.
                // If appearance changed while we were parsing, discard results to avoid
                // overwriting the cache with colors computed for the old appearance.
                guard parsingGeneration == self.syntaxParsingGeneration else {
                    // Parsing is stale - a newer appearance change has occurred.
                    // Don't apply these colors; a new parsing is in progress.
                    return
                }

                // Store newly parsed entries in shared cache with explicit appearance flag
                // This ensures cached colors match the appearance they were computed for
                let sharedCache = SharedSyntaxCache.shared
                sharedCache.batchSet(entries: newSharedCacheEntries, language: lang, isDarkMode: isDarkMode)

                // Update local caches
                self.tokenCache = newCache
                self.charColorCache = newColorCache

                // If either cache is too large, trim both to visible range only
                if self.tokenCache.count > self.maxCacheSize || self.charColorCache.count > self.maxCacheSize {
                    self.trimCachesToVisibleRange()
                }

                // FIXED: Invalidate render cache so next render uses new syntax colors
                // Without this, the Phase 4 caching optimization would reuse old instances
                // that were rendered before syntax highlighting was available
                self.invalidateRenderCache()

                self.objectWillChange.send()
            }
        }
    }
    
    // FIXED: Add method to trim caches when they grow too large
    private func trimCachesToVisibleRange() {
        guard let diff = diffResult else { return }
        
        let startVisualIndex = Int(visibleRange.lowerBound / lineHeight)
        let endVisualIndex = Int(visibleRange.upperBound / lineHeight) + 1
        let validStart = max(0, startVisualIndex)
        let validEnd = min(visualLines.count, endVisualIndex)
        
        // Keep a buffer around visible range
        let bufferLines = 200
        let keepStart = max(0, validStart - bufferLines)
        let keepEnd = min(visualLines.count, validEnd + bufferLines)
        
        var visibleLineIds = Set<UUID>()
        for vIdx in keepStart..<keepEnd {
            if vIdx < visualLines.count {
                let vLine = visualLines[vIdx]
                if vLine.diffLineIndex < diff.lines.count {
                    visibleLineIds.insert(diff.lines[vLine.diffLineIndex].id)
                }
            }
        }
        
        // Remove entries not in visible range
        tokenCache = tokenCache.filter { visibleLineIds.contains($0.key) }
        charColorCache = charColorCache.filter { visibleLineIds.contains($0.key) }
    }

    // MARK: - Selection Methods
    
    func screenToTextPosition(screenX: Float, screenY: Float, scrollY: Float, monoAdvance: Float) -> TextPosition? {
        // Adjust for scroll
        let adjustedY = screenY + scrollY
        
        // Calculate visual line index
        let visualLineIndex = Int(adjustedY / lineHeight)
        guard visualLineIndex >= 0 && visualLineIndex < visualLines.count else { return nil }
        
        // Check if click is in content area (past gutter)
        guard screenX >= gutterWidth else { return nil }
        
        // Calculate character index
        let contentX = screenX - gutterWidth - contentOffsetX
        let charIndex = max(0, Int(contentX / monoAdvance))
        
        return TextPosition(visualLineIndex: visualLineIndex, charIndex: charIndex)
    }
    
    func setSelection(start: TextPosition?, end: TextPosition?) {
        self.selectionStart = start
        self.selectionEnd = end
        // Phase 4: Selection changes require buffer regeneration
        self.invalidateRenderCache()
        self.objectWillChange.send()
    }

    func clearSelection() {
        self.selectionStart = nil
        self.selectionEnd = nil
        // Phase 4: Selection changes require buffer regeneration
        self.invalidateRenderCache()
        self.objectWillChange.send()
    }

    /// Selects the entire line at the given visual line index (for double-click selection)
    func selectLine(at visualLineIndex: Int) {
        guard visualLineIndex >= 0 && visualLineIndex < visualLines.count,
              let diff = diffResult else { return }

        let vLine = visualLines[visualLineIndex]

        // Don't select fold lines
        if vLine.isFold { return }

        let line = diff.lines[vLine.diffLineIndex]
        let lineLength = line.content.count

        let start = TextPosition(visualLineIndex: visualLineIndex, charIndex: 0)
        let end = TextPosition(visualLineIndex: visualLineIndex, charIndex: lineLength)

        setSelection(start: start, end: end)
    }

    func getSelectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd, let diff = diffResult else { return nil }
        
        // Normalize selection (start should be before end)
        let (normalStart, normalEnd) = start.visualLineIndex <= end.visualLineIndex ||
            (start.visualLineIndex == end.visualLineIndex && start.charIndex <= end.charIndex)
            ? (start, end) : (end, start)
        
        var selectedText = ""
        
        for vIdx in normalStart.visualLineIndex...normalEnd.visualLineIndex {
            guard vIdx < visualLines.count else { break }
            let vLine = visualLines[vIdx]
            
            // Skip fold lines
            if vLine.isFold { continue }
            
            let line = diff.lines[vLine.diffLineIndex]
            let chars = Array(line.content)
            
            if vIdx == normalStart.visualLineIndex && vIdx == normalEnd.visualLineIndex {
                // Selection within single line
                let startIdx = min(normalStart.charIndex, chars.count)
                let endIdx = min(normalEnd.charIndex, chars.count)
                if startIdx < endIdx {
                    selectedText += String(chars[startIdx..<endIdx])
                }
            } else if vIdx == normalStart.visualLineIndex {
                // First line of multi-line selection
                let startIdx = min(normalStart.charIndex, chars.count)
                selectedText += String(chars[startIdx...]) + "\n"
            } else if vIdx == normalEnd.visualLineIndex {
                // Last line of multi-line selection
                let endIdx = min(normalEnd.charIndex, chars.count)
                selectedText += String(chars[..<endIdx])
            } else {
                // Middle lines
                selectedText += line.content + "\n"
            }
        }
        
        return selectedText.isEmpty ? nil : selectedText
    }
    
    // MARK: - Memory Management

    /// Explicitly release all cached data to free memory.
    /// Call this when the view is about to be removed or hidden.
    /// This is more aggressive than deinit - it can be called while the view is still alive.
    func releaseMemory() {
        // Clear all caches
        tokenCache.removeAll(keepingCapacity: false)
        charColorCache.removeAll(keepingCapacity: false)

        // Release cached render data
        cachedInstances = nil
        cachedRects = nil
        cachedVisibleRange = nil

        // Force full regeneration next time
        needsFullRegen = true
    }

    // FIXED: Add cleanup
    deinit {
        fontSizeCancellable?.cancel()
        fontSizeCancellable = nil
        // Use removeAll(keepingCapacity: false) to actually deallocate memory
        tokenCache.removeAll(keepingCapacity: false)
        charColorCache.removeAll(keepingCapacity: false)
        // Phase 4: Clean up cached instances
        cachedInstances = nil
        cachedRects = nil
        cachedVisibleRange = nil
    }
}
