import Foundation
import CoreGraphics
import simd
import AppKit
import Combine

// MARK: - Data Structures

/// Represents a file diff section with layout information
@MainActor
struct DiffSection {
    let index: Int
    let filename: String?
    let language: String?
    let diffResult: DiffResult
    let globalLineStart: Int      // First global line index (the header line)
    let globalLineEnd: Int        // Last global line index (exclusive)
    let yOffset: CGFloat          // Y position of this section's header
    let contentHeight: CGFloat    // Height of diff content (excluding header)
    let linesAdded: Int
    let linesRemoved: Int
    let isNewFile: Bool
    let maxContentWidth: CGFloat  // Maximum width of any line in this section (in characters * monoAdvance)

    /// Height of file header - scales with font size
    /// Base calculation: lineHeight * 1.75 (provides room for text + padding)
    static var headerHeight: CGFloat {
        let lineHeight = CGFloat(FontSizeManager.shared.diffLineHeight)
        return max(35, ceil(lineHeight * 1.75))
    }

    /// Height of file footer - scales with font size
    static var footerHeight: CGFloat {
        let lineHeight = CGFloat(FontSizeManager.shared.diffLineHeight)
        return max(8, ceil(lineHeight * 0.4))
    }

    /// Spacing between sections - scales with font size
    static var sectionSpacing: CGFloat {
        let lineHeight = CGFloat(FontSizeManager.shared.diffLineHeight)
        return max(32, ceil(lineHeight * 1.5))
    }

    /// Total height including header and footer
    var totalHeight: CGFloat { Self.headerHeight + contentHeight + Self.footerHeight }
}

/// Represents a line in the global coordinate system
struct GlobalLine {
    let globalIndex: Int          // Index in the global lines array
    let sectionIndex: Int         // Which section this belongs to
    let localLineIndex: Int       // Index within section's diffResult.lines (-1 for header/spacer)
    let lineType: GlobalLineType
    let yOffset: CGFloat          // Global Y position of this line
}

/// Type of global line
enum GlobalLineType {
    case fileHeader              // File header with filename, +N -M
    case diffLine                // Actual diff content line
    case spacer                  // Visual spacer between files
}

/// Position in the global text coordinate system (for selection)
struct GlobalTextPosition: Equatable, Hashable {
    let globalLineIndex: Int
    let charIndex: Int
}

// MARK: - UnifiedDiffViewModel

/// ViewModel that manages all diff sections for unified Metal rendering.
/// This replaces the per-tile FluxViewModel approach with a single unified model.
@MainActor
final class UnifiedDiffViewModel: ObservableObject {

    // MARK: - Layout Data

    /// All file sections
    private(set) var sections: [DiffSection] = []

    /// All lines in global coordinate system
    private(set) var globalLines: [GlobalLine] = []

    /// Total content height (for document view sizing)
    private(set) var totalContentHeight: CGFloat = 0

    /// Line manager for efficient visible range queries
    private let lineManager = LineManager()

    // MARK: - Configuration

    /// Line height from FontSizeManager
    var lineHeight: CGFloat {
        CGFloat(FontSizeManager.shared.diffLineHeight)
    }

    /// Gutter width for line numbers - scales with font size
    var gutterWidth: Float {
        let lineHeight = Float(FontSizeManager.shared.diffLineHeight)
        return max(80.0, lineHeight * 4.0)
    }

    /// Content offset after gutter - scales with font size
    var contentOffsetX: Float {
        let lineHeight = Float(FontSizeManager.shared.diffLineHeight)
        return max(10.0, lineHeight * 0.5)
    }

    /// Top/bottom padding
    let verticalPadding: CGFloat = 16

    /// Horizontal padding (similar to activity view)
    let horizontalPadding: Float = 24.0

    /// Corner radius for section rounded corners
    let sectionCornerRadius: Float = 6.0

    /// Border width for sections (1 pixel)
    let sectionBorderWidth: Float = 1.0

    // MARK: - Content Clipping Adjustments
    // These variables control the alignment of content clipping within diff sections.
    // Adjust these to fine-tune how content is clipped at section boundaries.

    /// Offset applied to the left clipping boundary (positive = clip more from left, negative = clip less)
    let contentClipLeftOffset: Float = 10.0

    /// Offset applied to the right clipping boundary (positive = clip more from right, negative = clip less)
    let contentClipRightOffset: Float = 10.0

    /// Inset for line backgrounds from the gutter edge (adjusts where colored backgrounds start)
    let lineBackgroundLeftInset: Float = 0.0

    /// Inset for line backgrounds from the right section edge
    let lineBackgroundRightInset: Float = 0.0

    // MARK: - Rendering State

    /// Current viewport for visible line calculation
    private var viewportTop: CGFloat = 0
    private var viewportBottom: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var viewportWidth: CGFloat = 1500  // Default width for background rendering

    /// Per-section horizontal scroll offsets
    private var sectionScrollOffsets: [Int: CGFloat] = [:]

    /// Mono advance (character width) - updated when font atlas is available
    private var monoAdvance: CGFloat = 8.0

    /// Tracks whether monoAdvance has been updated from the renderer
    /// Used to prevent showing scrollbar before content is properly rendered
    private(set) var hasValidMonoAdvance: Bool = false

    /// Cached syntax colors per line (keyed by DiffLine UUID)
    private var charColorCache: [UUID: [SIMD4<Float>]] = [:]

    /// Token cache for syntax highlighting
    private var tokenCache: [UUID: [StyledToken]] = [:]

    /// Maximum cache size
    private let maxCacheSize = 5000

    /// Cached visible range for differential updates
    private var cachedVisibleRange: Range<Int>?
    private var cachedInstances: [InstanceData]?
    private var cachedBoldInstances: [InstanceData]?  // Bold instances for header filenames
    private var cachedRects: [RectInstance]?
    private var needsFullRegen: Bool = true
    private var cachedScrollOffsets: [Int: CGFloat] = [:]  // Scroll offsets when cache was generated

    /// Per-section instance caching for efficient scroll updates
    private struct SectionCache {
        var instances: [InstanceData]
        var rects: [RectInstance]
        var scrollOffset: CGFloat
    }
    private var sectionCaches: [Int: SectionCache] = [:]

    /// Generation counter for syntax parsing.
    /// Incremented on appearance changes to invalidate in-flight parsing results.
    /// This prevents race conditions where an older parsing (started before appearance change)
    /// could overwrite newer colors with stale values.
    private var syntaxParsingGeneration: Int = 0

    // MARK: - Selection State

    var selectionStart: GlobalTextPosition?
    var selectionEnd: GlobalTextPosition?
    private var selectionDirty = false  // Track if only selection changed (lighter-weight update)

    // MARK: - Session Tracking

    private var currentSessionId: String = ""

    /// Hash of last processed diffs for change detection
    private var lastDiffsHash: Int = 0

    /// Callback to force immediate GPU buffer clear when session changes
    /// This ensures stale content from previous session is removed before new content loads
    var onSessionChangeRequiresGPUClear: (() -> Void)?

    // MARK: - Font Size Subscription

    private var fontSizeCancellable: AnyCancellable?

    // MARK: - Initialization

    init() {
        setupFontSizeSubscription()
    }

    private func setupFontSizeSubscription() {
        // NOTE: Removed .receive(on: DispatchQueue.main) to eliminate async delay.
        // Since UnifiedDiffViewModel is @MainActor and the publisher sends from main thread,
        // the sink closure executes synchronously, enabling immediate font size response.
        fontSizeCancellable = FontSizeManager.shared.diffFontSizeChanged
            .sink { [weak self] _ in
                guard let self = self else { return }
                // CRITICAL FIX: When font size changes, we need to rebuild sections completely
                // because all Y positions and content heights depend on lineHeight.
                // Reset lastDiffsHash to force a full rebuild on next updateContent call.
                // Without this, the hash check in updateContent would skip the rebuild,
                // leaving sections with stale Y positions that cause overlapping.
                self.lastDiffsHash = 0
                self.rebuildLayout()
                self.invalidateRenderCache()
                self.objectWillChange.send()
            }
    }

    // MARK: - Content Updates

    /// Update sections from diffs array
    func updateContent(
        diffs: [(patch: String, language: String?, filename: String?)],
        sessionId: String
    ) {
        // Compute hash of current diffs for change detection
        let newHash = computeDiffsHash(diffs)

        // CRITICAL: When session changes, IMMEDIATELY clear all content before processing.
        // This prevents showing stale diffs from the previous session when rapidly paginating.
        // Without this, the Metal view could continue showing old content until the new
        // content is fully processed and rendered.
        let sessionChanged = sessionId != currentSessionId
        if sessionChanged {
            // Clear all visual state immediately
            sections = []
            globalLines = []
            totalContentHeight = 0
            charColorCache.removeAll()
            tokenCache.removeAll()
            sectionScrollOffsets.removeAll()
            invalidateRenderCache()

            // Update tracking state
            currentSessionId = sessionId
            lastDiffsHash = 0  // Reset hash so we always process new diffs

            // CRITICAL FIX: Force immediate GPU buffer clear BEFORE loading new content.
            // When paginating rapidly (A→B→A), the render updates via objectWillChange can get
            // coalesced, causing stale content from session A to persist. By forcing a synchronous
            // GPU clear here, we ensure the Metal view shows empty content before any new diffs load.
            onSessionChangeRequiresGPUClear?()

            // If no diffs provided, notify immediately and return
            // This ensures the view clears even when navigating to a session without loaded diffs
            if diffs.isEmpty {
                objectWillChange.send()
                return
            }
        }

        // Skip if nothing changed (same session, same content)
        if !sessionChanged && newHash == lastDiffsHash {
            return
        }

        // Detect what kind of change occurred
        let changeType = detectChangeType(oldSections: sections, newDiffs: diffs)

        lastDiffsHash = newHash

        switch changeType {
        case .none:
            return

        case .fullRebuild:
            // Session changed or structure changed significantly
            buildSections(from: diffs, sessionId: sessionId)
            rebuildLayout()
            parseSyntaxAsync()

        case .appendOnly(let startIndex):
            // New files added at end - preserve existing sections
            appendSections(from: diffs, startingAt: startIndex, sessionId: sessionId)
            rebuildLayout()
            parseSyntaxAsync()

        case .contentChanged(let indices):
            // Specific files changed - update only those sections
            updateSections(at: indices, from: diffs, sessionId: sessionId)
            // Don't need full layout rebuild, just re-parse affected sections
            parseSyntaxAsync(onlyIndices: indices)
        }

        invalidateRenderCache()
        objectWillChange.send()
    }

    /// Compute a hash of diffs for change detection
    private func computeDiffsHash(_ diffs: [(patch: String, language: String?, filename: String?)]) -> Int {
        var hasher = Hasher()
        for diff in diffs {
            hasher.combine(diff.patch)
            hasher.combine(diff.filename)
            hasher.combine(diff.language)
        }
        return hasher.finalize()
    }

    /// Detect what type of change occurred
    private enum ChangeType {
        case none
        case fullRebuild
        case appendOnly(startIndex: Int)
        case contentChanged(indices: [Int])
    }

    private func detectChangeType(
        oldSections: [DiffSection],
        newDiffs: [(patch: String, language: String?, filename: String?)]
    ) -> ChangeType {
        // No existing sections = full rebuild
        if oldSections.isEmpty {
            return newDiffs.isEmpty ? .none : .fullRebuild
        }

        // Check if existing sections still match (by filename)
        var changedIndices: [Int] = []
        let minCount = min(oldSections.count, newDiffs.count)

        for i in 0..<minCount {
            let oldFilename = oldSections[i].filename
            let newFilename = newDiffs[i].filename

            if oldFilename != newFilename {
                // Filename changed = structure changed, need full rebuild
                return .fullRebuild
            }

            // Same filename, but content might have changed
            // We can detect this by checking if the patch hash changed
            // For now, we'll rely on the overall hash check above
            // But we could do per-file hash checking here for finer granularity
        }

        // If new diffs are longer, it's append-only
        if newDiffs.count > oldSections.count {
            return .appendOnly(startIndex: oldSections.count)
        }

        // If new diffs are shorter, need full rebuild (files removed)
        if newDiffs.count < oldSections.count {
            return .fullRebuild
        }

        // Same count, same filenames, but hash changed = content changed somewhere
        // For now, treat as full rebuild (could be optimized with per-file hashing)
        return .fullRebuild
    }

    /// Append new sections without rebuilding existing ones
    private func appendSections(
        from diffs: [(patch: String, language: String?, filename: String?)],
        startingAt startIndex: Int,
        sessionId: String
    ) {
        guard startIndex < diffs.count else { return }

        // Get current end position
        var currentY: CGFloat = sections.isEmpty ? verticalPadding : (
            sections.last.map { $0.yOffset + $0.totalHeight + DiffSection.sectionSpacing } ?? verticalPadding
        )
        var globalLineIndex = globalLines.count

        for index in startIndex..<diffs.count {
            let diff = diffs[index]

            // Add spacer lines
            for _ in 0..<3 {
                globalLines.append(GlobalLine(
                    globalIndex: globalLineIndex,
                    sectionIndex: index,
                    localLineIndex: -1,
                    lineType: .spacer,
                    yOffset: currentY
                ))
                currentY += DiffSection.sectionSpacing / 3
                globalLineIndex += 1
            }

            // Parse this diff
            let precomputed = DiffPrecomputationService.shared.getPrecomputed(
                sessionId: sessionId,
                index: index
            )

            let diffResult: DiffResult
            let contentHeight: CGFloat

            if let p = precomputed {
                diffResult = p.contentDiffResult
                // CRITICAL FIX: Always recalculate contentHeight using current lineHeight.
                // The precomputed contentHeight was calculated with lineHeight at precomputation time,
                // which may differ from current lineHeight (e.g., after font size changes).
                // Using stale contentHeight causes section backgrounds to be sized incorrectly,
                // leading to overlapping sections.
                contentHeight = CGFloat(diffResult.lines.count) * lineHeight
            } else {
                let fullResult = FluxDiffer.fromPatch(
                    patch: diff.patch,
                    language: diff.language,
                    filename: diff.filename
                )
                let contentLines = fullResult.lines.filter { $0.type != .fileHeader }
                diffResult = DiffResult(
                    lines: contentLines,
                    originalText: fullResult.originalText,
                    newText: fullResult.newText,
                    language: fullResult.language
                )
                contentHeight = CGFloat(contentLines.count) * lineHeight
            }

            let fullParse = FluxDiffer.fromPatch(
                patch: diff.patch,
                language: diff.language,
                filename: diff.filename
            )
            let headerLine = fullParse.lines.first { $0.type == .fileHeader }

            let globalLineStart = globalLineIndex

            // Add file header line
            let headerY = currentY
            globalLines.append(GlobalLine(
                globalIndex: globalLineIndex,
                sectionIndex: index,
                localLineIndex: -1,
                lineType: .fileHeader,
                yOffset: currentY
            ))
            currentY += DiffSection.headerHeight
            globalLineIndex += 1

            // Add content lines
            for (localIdx, _) in diffResult.lines.enumerated() {
                globalLines.append(GlobalLine(
                    globalIndex: globalLineIndex,
                    sectionIndex: index,
                    localLineIndex: localIdx,
                    lineType: .diffLine,
                    yOffset: currentY
                ))
                currentY += lineHeight
                globalLineIndex += 1
            }

            // Calculate max line width (in characters) for this section
            // Account for tabs which render as 4 spaces each
            let maxLineChars = diffResult.lines.map { line -> Int in
                var width = 0
                for char in line.content {
                    if char == "\t" {
                        width += 4
                    } else {
                        width += 1
                    }
                }
                return width
            }.max() ?? 0
            let maxContentWidth = CGFloat(maxLineChars)

            let section = DiffSection(
                index: index,
                filename: diff.filename ?? headerLine?.fileName,
                language: diff.language ?? diffResult.language,
                diffResult: diffResult,
                globalLineStart: globalLineStart,
                globalLineEnd: globalLineIndex,
                yOffset: headerY,
                contentHeight: contentHeight,
                linesAdded: headerLine?.linesAdded ?? 0,
                linesRemoved: headerLine?.linesRemoved ?? 0,
                isNewFile: headerLine?.isNewFile ?? false,
                maxContentWidth: maxContentWidth
            )

            sections.append(section)
        }

        // Update total height
        totalContentHeight = currentY + verticalPadding
    }

    /// Update specific sections in-place
    private func updateSections(
        at indices: [Int],
        from diffs: [(patch: String, language: String?, filename: String?)],
        sessionId: String
    ) {
        // This would update specific sections without rebuilding everything
        // For now, fall back to full rebuild
        // TODO: Implement true incremental update
        buildSections(from: diffs, sessionId: sessionId)
        rebuildLayout()
    }

    /// Build sections from diffs
    private func buildSections(
        from diffs: [(patch: String, language: String?, filename: String?)],
        sessionId: String
    ) {
        var newSections: [DiffSection] = []
        var newGlobalLines: [GlobalLine] = []
        var currentY: CGFloat = verticalPadding
        var globalLineIndex = 0

        for (index, diff) in diffs.enumerated() {
            // Get precomputed diff result if available
            let precomputed = DiffPrecomputationService.shared.getPrecomputed(
                sessionId: sessionId,
                index: index
            )

            let diffResult: DiffResult
            let contentHeight: CGFloat

            if let p = precomputed {
                diffResult = p.contentDiffResult
                // CRITICAL FIX: Always recalculate contentHeight using current lineHeight.
                // The precomputed contentHeight was calculated with lineHeight at precomputation time,
                // which may differ from current lineHeight (e.g., after font size changes).
                // Using stale contentHeight causes section backgrounds to be sized incorrectly,
                // leading to overlapping sections.
                contentHeight = CGFloat(diffResult.lines.count) * lineHeight
            } else {
                // Fall back to on-demand computation
                let fullResult = FluxDiffer.fromPatch(
                    patch: diff.patch,
                    language: diff.language,
                    filename: diff.filename
                )
                // Filter out file header (we render it separately)
                let contentLines = fullResult.lines.filter { $0.type != .fileHeader }
                diffResult = DiffResult(
                    lines: contentLines,
                    originalText: fullResult.originalText,
                    newText: fullResult.newText,
                    language: fullResult.language
                )
                contentHeight = CGFloat(contentLines.count) * lineHeight
            }

            // Extract file info from original parse
            let fullParse = FluxDiffer.fromPatch(
                patch: diff.patch,
                language: diff.language,
                filename: diff.filename
            )
            let headerLine = fullParse.lines.first { $0.type == .fileHeader }

            let globalLineStart = globalLineIndex

            // Add spacer lines before this section (except first)
            if index > 0 {
                for _ in 0..<3 {
                    newGlobalLines.append(GlobalLine(
                        globalIndex: globalLineIndex,
                        sectionIndex: index,
                        localLineIndex: -1,
                        lineType: .spacer,
                        yOffset: currentY
                    ))
                    currentY += DiffSection.sectionSpacing / 3
                    globalLineIndex += 1
                }
            }

            // Add file header line
            let headerY = currentY
            newGlobalLines.append(GlobalLine(
                globalIndex: globalLineIndex,
                sectionIndex: index,
                localLineIndex: -1,
                lineType: .fileHeader,
                yOffset: currentY
            ))
            currentY += DiffSection.headerHeight
            globalLineIndex += 1

            // Add content lines
            for (localIdx, _) in diffResult.lines.enumerated() {
                newGlobalLines.append(GlobalLine(
                    globalIndex: globalLineIndex,
                    sectionIndex: index,
                    localLineIndex: localIdx,
                    lineType: .diffLine,
                    yOffset: currentY
                ))
                currentY += lineHeight
                globalLineIndex += 1
            }

            // Calculate max line width (in characters) for this section
            // Account for tabs which render as 4 spaces each
            let maxLineChars = diffResult.lines.map { line -> Int in
                var width = 0
                for char in line.content {
                    if char == "\t" {
                        width += 4
                    } else {
                        width += 1
                    }
                }
                return width
            }.max() ?? 0
            let maxContentWidth = CGFloat(maxLineChars)

            let section = DiffSection(
                index: index,
                filename: diff.filename ?? headerLine?.fileName,
                language: diff.language ?? diffResult.language,
                diffResult: diffResult,
                globalLineStart: globalLineStart,
                globalLineEnd: globalLineIndex,
                yOffset: headerY,
                contentHeight: contentHeight,
                linesAdded: headerLine?.linesAdded ?? 0,
                linesRemoved: headerLine?.linesRemoved ?? 0,
                isNewFile: headerLine?.isNewFile ?? false,
                maxContentWidth: maxContentWidth
            )

            newSections.append(section)
        }

        // Add bottom padding
        currentY += verticalPadding

        self.sections = newSections
        self.globalLines = newGlobalLines
        self.totalContentHeight = currentY
    }

    /// Rebuild line manager after content or font size changes
    private func rebuildLayout() {
        lineManager.rebuild(
            lineCount: globalLines.count,
            lineHeight: Float(lineHeight)
        )
    }

    // MARK: - Viewport & Visible Range

    /// Update viewport for visible line calculation
    func setViewport(top: CGFloat, height: CGFloat, width: CGFloat? = nil) {
        viewportTop = top
        viewportHeight = height
        viewportBottom = top + height
        if let width = width {
            viewportWidth = max(width, 500)  // Ensure minimum width
        }
    }

    // MARK: - Per-Section Horizontal Scrolling

    /// Find the section index at a given Y coordinate (in global/document coordinates)
    func sectionIndex(atY y: CGFloat) -> Int? {
        for section in sections {
            let sectionTop = section.yOffset
            let sectionBottom = section.yOffset + section.totalHeight
            if y >= sectionTop && y < sectionBottom {
                return section.index
            }
        }
        return nil
    }

    /// Get horizontal scroll offset for a section
    func scrollOffsetX(forSection sectionIndex: Int) -> CGFloat {
        return sectionScrollOffsets[sectionIndex] ?? 0
    }

    /// Calculate max horizontal scroll for a section based on its content width
    func maxScrollX(forSection sectionIndex: Int) -> CGFloat {
        guard sectionIndex >= 0 && sectionIndex < sections.count else { return 0 }
        let section = sections[sectionIndex]
        // Content width = horizontal padding + gutter + offset + max chars * monoAdvance + right padding
        // The horizontal padding is the left margin of the section
        // Add generous right padding (100) so the last character can be easily selected
        let contentPixelWidth = CGFloat(horizontalPadding) + CGFloat(gutterWidth) + CGFloat(contentOffsetX) + section.maxContentWidth * monoAdvance + 100
        // Max scroll = content width - viewport width (if content is wider than viewport)
        let maxScroll = max(0, contentPixelWidth - viewportWidth)
        return maxScroll
    }

    /// Get the visible bounds of a section within the current viewport
    func sectionVisibleBounds(forSection sectionIndex: Int, viewportTop: CGFloat, viewportHeight: CGFloat) -> NSRect? {
        guard sectionIndex >= 0 && sectionIndex < sections.count else { return nil }
        let section = sections[sectionIndex]

        let sectionTop = section.yOffset
        let sectionBottom = section.yOffset + section.totalHeight
        let viewportBottom = viewportTop + viewportHeight

        // Check if section is visible
        guard sectionBottom > viewportTop && sectionTop < viewportBottom else { return nil }

        // Clip to visible portion
        let visibleTop = max(sectionTop, viewportTop)
        let visibleBottom = min(sectionBottom, viewportBottom)

        return NSRect(
            x: 0,
            y: visibleTop,
            width: viewportWidth,
            height: visibleBottom - visibleTop
        )
    }

    /// Get the full frame of a section (for scrollbar positioning)
    /// Returns the section frame with horizontal padding applied to match the rendered section
    func sectionFrame(forSection sectionIndex: Int) -> NSRect? {
        guard sectionIndex >= 0 && sectionIndex < sections.count else { return nil }
        let section = sections[sectionIndex]

        // Section is rendered with horizontal padding on each side
        let sectionWidth = viewportWidth - CGFloat(horizontalPadding) * 2

        return NSRect(
            x: CGFloat(horizontalPadding),
            y: section.yOffset,
            width: sectionWidth,
            height: section.totalHeight
        )
    }

    /// Set horizontal scroll offset for a section
    /// Note: This does NOT invalidate the render cache for performance.
    /// The cache check in generateInstances will detect scroll offset changes.
    func setScrollOffsetX(_ offset: CGFloat, forSection sectionIndex: Int) {
        let maxScroll = maxScrollX(forSection: sectionIndex)
        let clampedOffset = max(0, min(offset, maxScroll))
        sectionScrollOffsets[sectionIndex] = clampedOffset
    }

    /// Adjust horizontal scroll offset for a section by delta
    func adjustScrollOffsetX(delta: CGFloat, forSection sectionIndex: Int) {
        let currentOffset = scrollOffsetX(forSection: sectionIndex)
        setScrollOffsetX(currentOffset - delta, forSection: sectionIndex)
    }

    /// Called when viewport width changes (e.g., window resize) to clamp scroll offsets
    /// Returns true if any scroll offsets were adjusted
    @discardableResult
    func handleViewportWidthChange(newWidth: CGFloat) -> Bool {
        guard newWidth != viewportWidth else { return false }
        viewportWidth = max(newWidth, 500)

        // Clamp all section scroll offsets to new max values
        var anyChanged = false
        for sectionIndex in sectionScrollOffsets.keys {
            let currentOffset = sectionScrollOffsets[sectionIndex] ?? 0
            let maxScroll = maxScrollX(forSection: sectionIndex)
            let clampedOffset = max(0, min(currentOffset, maxScroll))
            if clampedOffset != currentOffset {
                sectionScrollOffsets[sectionIndex] = clampedOffset
                anyChanged = true
            }
        }

        if anyChanged {
            invalidateRenderCache()
        }

        return anyChanged
    }

    /// Check if a section needs horizontal scrolling (content wider than viewport)
    func sectionNeedsHorizontalScroll(_ sectionIndex: Int) -> Bool {
        return maxScrollX(forSection: sectionIndex) > 0
    }

    /// Get all sections that need horizontal scrolling
    func sectionsNeedingHorizontalScroll() -> [Int] {
        return sections.indices.filter { sectionNeedsHorizontalScroll($0) }
    }

    /// Update mono advance from font atlas (call when renderer is available)
    func updateMonoAdvance(_ advance: CGFloat) {
        monoAdvance = advance
        hasValidMonoAdvance = true
    }

    /// Get visible line range for current viewport
    func visibleLineRange() -> Range<Int> {
        guard !globalLines.isEmpty else { return 0..<0 }

        // Find first visible line (binary search would be faster but this is simple)
        var firstVisible = 0
        for (i, line) in globalLines.enumerated() {
            let lineBottom = line.yOffset + lineHeight
            if lineBottom > viewportTop {
                firstVisible = i
                break
            }
        }

        // Find last visible line
        var lastVisible = globalLines.count - 1
        for i in stride(from: globalLines.count - 1, through: 0, by: -1) {
            if globalLines[i].yOffset < viewportBottom {
                lastVisible = i
                break
            }
        }

        // Add buffer for smooth scrolling
        let buffer = 20
        let bufferedFirst = max(0, firstVisible - buffer)
        let bufferedLast = min(globalLines.count, lastVisible + buffer + 1)

        return bufferedFirst..<bufferedLast
    }

    // MARK: - Instance Generation

    /// Generate Metal instances for visible lines
    /// Note: Uses per-section horizontal scroll offsets stored in the view model
    /// Returns regular instances, bold instances (for headers), rects, and whether cache was hit
    func generateInstances(
        renderer: FluxRenderer
    ) -> (instances: [InstanceData], boldInstances: [InstanceData], rects: [RectInstance], isCacheHit: Bool) {
        let visibleRange = visibleLineRange()

        guard !visibleRange.isEmpty else {
            // When transitioning from content to no content (e.g., switching to a session
            // with no diffs), we need to return a cache MISS so GPU buffers get cleared.
            // Otherwise the old session's diffs would still be rendered.
            let isCacheMiss = needsFullRegen
            needsFullRegen = false
            return ([], [], [], !isCacheMiss)
        }

        // Check if we can reuse cached instances
        // Must also check if scroll offsets haven't changed and selection hasn't changed
        let scrollOffsetsMatch = sectionScrollOffsets == cachedScrollOffsets
        if !needsFullRegen,
           !selectionDirty,
           scrollOffsetsMatch,
           let cached = cachedInstances,
           let cachedBold = cachedBoldInstances,
           let cachedR = cachedRects,
           let prevRange = cachedVisibleRange,
           visibleRange.lowerBound >= prevRange.lowerBound,
           visibleRange.upperBound <= prevRange.upperBound {
            return (cached, cachedBold, cachedR, true)  // Cache hit - no GPU update needed
        }

        needsFullRegen = false
        selectionDirty = false
        cachedScrollOffsets = sectionScrollOffsets

        let atlas = renderer.fontAtlasManager
        let monoAdvanceFloat = atlas.monoAdvance
        let lh = Float(lineHeight)

        // Update view model's monoAdvance for scroll calculations
        self.monoAdvance = CGFloat(monoAdvanceFloat)

        // Pre-allocate
        var instances: [InstanceData] = []
        var boldInstances: [InstanceData] = []  // Bold text for headers (uses bold texture)
        var rects: [RectInstance] = []
        var gutterRects: [RectInstance] = []  // Gutter rects rendered last (on top)
        var headerRects: [RectInstance] = []  // Header rects rendered on top of everything
        var headerInstances: [InstanceData] = []  // Header text (regular weight) rendered on top
        var headerBoldInstances: [InstanceData] = []  // Header text (bold weight) for filenames
        instances.reserveCapacity(visibleRange.count * 40)
        rects.reserveCapacity(visibleRange.count * 3)

        // Colors
        let colAdded = AppColors.diffEditorAddedBg.simd4
        let colRemoved = AppColors.diffEditorRemovedBg.simd4
        let colTextDefault = AppColors.diffEditorText.simd4
        let colGutterText = AppColors.diffEditorGutter.simd4
        let colGutterBg = AppColors.diffEditorGutterBg.simd4
        let colHighlight = AppColors.diffEditorHighlight.simd4
        let colSelection = AppColors.diffEditorSelection.simd4
        let colGutterSeparator = AppColors.diffEditorGutterSeparator.simd4
        let colFileHeaderBg = AppColors.diffEditorFileHeaderBg.simd4
        let colFileHeaderText = AppColors.diffEditorFileHeaderText.simd4
        let colModifiedIndicator = AppColors.diffEditorModifiedIndicator.simd4
        let colAddedText = AppColors.diffEditorAddedText.simd4
        let colRemovedText = AppColors.diffEditorRemovedText.simd4
        let colSectionBorder = AppColors.diffEditorSectionBorder.simd4

        // Text alignment (from FluxViewModel) - offsets scale with line height
        let baselineRatio: Float = 0.78
        let textVerticalOffset: Float = lh * 0.25  // Scale with line height
        let textHorizontalOffset: Float = -4

        // Calculate max scroll offset across all visible sections for background width
        let maxSectionScrollOffset = sectionScrollOffsets.values.max() ?? 0
        let bgWidth = Float(viewportWidth) + Float(maxSectionScrollOffset) + 200

        // Normalize selection
        var normalizedSelStart: GlobalTextPosition?
        var normalizedSelEnd: GlobalTextPosition?
        if let start = selectionStart, let end = selectionEnd {
            if start.globalLineIndex < end.globalLineIndex ||
               (start.globalLineIndex == end.globalLineIndex && start.charIndex <= end.charIndex) {
                normalizedSelStart = start
                normalizedSelEnd = end
            } else {
                normalizedSelStart = end
                normalizedSelEnd = start
            }
        }

        // Gutter separator lines are now rendered per-section (see section rendering below)
        // This ensures the gutter line only appears within diff content, not in spacing between files

        // Find visible sections and render their backgrounds with rounded corners and borders
        var visibleSectionIndices = Set<Int>()
        for globalIdx in visibleRange {
            visibleSectionIndices.insert(globalLines[globalIdx].sectionIndex)
        }

        // Render section backgrounds (first, so they appear behind content)
        // Use full viewport width for sections (no horizontal padding on section box itself)
        let sectionWidth = Float(viewportWidth) - horizontalPadding * 2
        let colEditorBg = AppColors.diffEditorBackground.simd4
        let headerHeight = Float(DiffSection.headerHeight)
        let footerHeight = Float(DiffSection.footerHeight)

        for sectionIdx in visibleSectionIndices.sorted() {
            let section = sections[sectionIdx]
            let sectionY = Float(section.yOffset)
            let sectionHeight = Float(section.totalHeight)
            let contentY = sectionY + headerHeight
            let contentHeight = sectionHeight - headerHeight - footerHeight

            // Section background with rounded corners and border (entire section)
            rects.insert(RectInstance(
                origin: [horizontalPadding, sectionY],
                size: [sectionWidth, sectionHeight],
                color: colFileHeaderBg,
                cornerRadius: sectionCornerRadius,
                borderWidth: sectionBorderWidth,
                borderColor: colSectionBorder
            ), at: 0)

            // Editor background for content area (inside section, below header, through footer)
            // This gives the proper editor background color for diff content
            // Extends into footer with rounded bottom corners and leaves room for bottom border
            let contentHeightWithFooter = contentHeight + footerHeight
            let innerCornerRadius = sectionCornerRadius - sectionBorderWidth  // Match section's inner corner
            // Reduce height to leave room for bottom border
            let innerBgHeight = contentHeightWithFooter - sectionBorderWidth
            if innerBgHeight > 0 {
                rects.append(RectInstance(
                    origin: [horizontalPadding + sectionBorderWidth, contentY],
                    size: [sectionWidth - sectionBorderWidth * 2, innerBgHeight],
                    color: colEditorBg,
                    cornerRadius: innerCornerRadius
                ))

                // Gutter separator line for this section (extends close to bottom, leaving small margin)
                let separatorHeight = innerBgHeight - 4
                if separatorHeight > 0 {
                    gutterRects.append(RectInstance(
                        origin: [horizontalPadding + gutterWidth - 1, contentY],
                        size: [1, separatorHeight],
                        color: colGutterSeparator
                    ))
                }

                // Gutter background for content area (renders behind line-specific backgrounds)
                // Extends into footer with rounded bottom corners
                rects.append(RectInstance(
                    origin: [horizontalPadding + sectionBorderWidth, contentY],
                    size: [gutterWidth - sectionBorderWidth - 1, innerBgHeight],
                    color: colGutterBg,
                    cornerRadius: innerCornerRadius
                ))
            }
        }

        // Render visible lines
        for globalIdx in visibleRange {
            let globalLine = globalLines[globalIdx]
            let currentY = Float(globalLine.yOffset)
            let section = sections[globalLine.sectionIndex]

            switch globalLine.lineType {
            case .spacer:
                // Spacers are just empty space, nothing to render
                continue

            case .fileHeader:
                // Render file header - add to separate arrays so they render on top
                // Header uses viewport width (not scrolled width) so stats are always visible
                let headerWidth = Float(viewportWidth)
                let fileHeaderResult = generateFileHeaderInstances(
                    section: section,
                    y: currentY,
                    atlas: atlas,
                    monoAdvance: monoAdvanceFloat,
                    baselineRatio: baselineRatio,
                    textVerticalOffset: textVerticalOffset,
                    textHorizontalOffset: textHorizontalOffset,
                    bgWidth: headerWidth,
                    colFileHeaderBg: colFileHeaderBg,
                    colFileHeaderText: colFileHeaderText,
                    colModifiedIndicator: colModifiedIndicator,
                    colAddedText: colAddedText,
                    colRemovedText: colRemovedText
                )
                headerInstances.append(contentsOf: fileHeaderResult.instances)
                headerBoldInstances.append(contentsOf: fileHeaderResult.boldInstances)
                headerRects.append(contentsOf: fileHeaderResult.rects)

            case .diffLine:
                guard globalLine.localLineIndex >= 0,
                      globalLine.localLineIndex < section.diffResult.lines.count else {
                    continue
                }

                let line = section.diffResult.lines[globalLine.localLineIndex]
                let chars = Array(line.content)
                let baselineY = floor(currentY + (lh * baselineRatio) + textVerticalOffset)

                // Get per-section horizontal scroll offset
                let sectionScrollX = Float(scrollOffsetX(forSection: section.index))

                // Line background and gutter background (same color for added/removed lines)
                // Content is offset by horizontalPadding
                // Gutter width matches the content area for consistent appearance
                let lineGutterWidth = gutterWidth - sectionBorderWidth - 1  // Minus border and separator
                // Line background width clips at section border (with adjustable insets)
                let lineBackgroundX = horizontalPadding + gutterWidth + lineBackgroundLeftInset
                let lineContentWidth = sectionWidth - gutterWidth - sectionBorderWidth - lineBackgroundLeftInset - lineBackgroundRightInset

                if line.type == .added {
                    // Line background (clipped to section content area)
                    rects.append(RectInstance(
                        origin: [lineBackgroundX, currentY],
                        size: [lineContentWidth, lh],
                        color: colAdded
                    ))
                    // Gutter background matches line color exactly
                    gutterRects.append(RectInstance(
                        origin: [horizontalPadding + sectionBorderWidth, currentY],
                        size: [lineGutterWidth, lh],
                        color: colAdded
                    ))
                } else if line.type == .removed {
                    // Line background (clipped to section content area)
                    rects.append(RectInstance(
                        origin: [lineBackgroundX, currentY],
                        size: [lineContentWidth, lh],
                        color: colRemoved
                    ))
                    // Gutter background matches line color exactly
                    gutterRects.append(RectInstance(
                        origin: [horizontalPadding + sectionBorderWidth, currentY],
                        size: [lineGutterWidth, lh],
                        color: colRemoved
                    ))
                }
                // Context lines don't need special gutter background - section gutter bg handles it

                // Line numbers (don't scroll - stay fixed in gutter)
                // Positions scale with gutter width for proper spacing at different font sizes
                let asciiGlyphs = atlas.asciiGlyphs
                let gutterHalfWidth = gutterWidth / 2.0
                var gutterX: Float = horizontalPadding + sectionBorderWidth + 4.0  // Small padding from border

                if let oldNum = line.originalLineNumber {
                    for char in String(oldNum) {
                        if let asciiValue = char.asciiValue,
                           let descriptor = asciiGlyphs[Int(asciiValue)] {
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

                // New line number starts at half the gutter width
                gutterX = horizontalPadding + gutterHalfWidth
                if let newNum = line.newLineNumber {
                    for char in String(newNum) {
                        if let asciiValue = char.asciiValue,
                           let descriptor = asciiGlyphs[Int(asciiValue)] {
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

                // Character-level diff highlights (scroll with text, clip to content area)
                // Content is offset by horizontalPadding (with adjustable clip offsets)
                let contentGutterX = horizontalPadding + gutterWidth + contentClipLeftOffset
                let contentRightEdge = horizontalPadding + sectionWidth - sectionBorderWidth - contentClipRightOffset
                if let changes = line.tokenChanges, !changes.isEmpty {
                    for range in changes {
                        var startX = floor(contentGutterX + contentOffsetX + Float(range.lowerBound) * monoAdvanceFloat - sectionScrollX)
                        var rangeWidth = floor(Float(range.count) * monoAdvanceFloat)
                        // Clip to content area (left: gutter, right: section edge)
                        if startX < contentGutterX {
                            let clip = contentGutterX - startX
                            rangeWidth -= clip
                            startX = contentGutterX
                        }
                        if startX + rangeWidth > contentRightEdge {
                            rangeWidth = contentRightEdge - startX
                        }
                        if rangeWidth > 0 {
                            rects.append(RectInstance(
                                origin: [startX, currentY],
                                size: [rangeWidth, floor(lh)],
                                color: colHighlight
                            ))
                        }
                    }
                }

                // Selection highlight (scroll with text, clip to content area)
                if let selStart = normalizedSelStart, let selEnd = normalizedSelEnd {
                    if globalIdx >= selStart.globalLineIndex && globalIdx <= selEnd.globalLineIndex {
                        var startChar = 0
                        var endChar = chars.count

                        if globalIdx == selStart.globalLineIndex {
                            startChar = min(selStart.charIndex, chars.count)
                        }
                        if globalIdx == selEnd.globalLineIndex {
                            endChar = min(selEnd.charIndex, chars.count)
                        }

                        if startChar < endChar {
                            var selX = floor(contentGutterX + contentOffsetX + Float(startChar) * monoAdvanceFloat - sectionScrollX)
                            var selWidth = floor(Float(endChar - startChar) * monoAdvanceFloat)
                            // Clip to content area (left: gutter, right: section edge)
                            if selX < contentGutterX {
                                let clip = contentGutterX - selX
                                selWidth -= clip
                                selX = contentGutterX
                            }
                            if selX + selWidth > contentRightEdge {
                                selWidth = contentRightEdge - selX
                            }
                            if selWidth > 0 {
                                rects.append(RectInstance(
                                    origin: [selX, currentY],
                                    size: [selWidth, floor(lh)],
                                    color: colSelection
                                ))
                            }
                        }
                    }
                }

                // Text content with syntax highlighting (clip to content area)
                let cachedColors = charColorCache[line.id]
                var x: Float = floor(contentGutterX + contentOffsetX) - sectionScrollX

                for charIndex in chars.indices {
                    let char = chars[charIndex]

                    // Skip whitespace
                    if char == " " {
                        x += monoAdvanceFloat
                        continue
                    } else if char == "\t" {
                        x += monoAdvanceFloat * 4
                        continue
                    }

                    let color = cachedColors?[charIndex] ?? colTextDefault

                    let descriptor: FontAtlasManager.GlyphDescriptor?
                    if let asciiValue = char.asciiValue, asciiValue < 128 {
                        descriptor = asciiGlyphs[Int(asciiValue)]
                    } else if let glyphIndex = atlas.charToGlyph[char] {
                        descriptor = atlas.glyphDescriptors[glyphIndex]
                    } else {
                        descriptor = nil
                    }

                    if let descriptor = descriptor {
                        let charX = floor(x + textHorizontalOffset)
                        // Clip to content area: skip chars in gutter (left) or beyond section edge (right)
                        if charX + descriptor.sizeFloat.x > contentGutterX && charX < contentRightEdge {
                            let charBaselineY = baselineY - descriptor.sizeFloat.y
                            instances.append(InstanceData(
                                origin: [charX, charBaselineY],
                                size: descriptor.sizeFloat,
                                uvMin: descriptor.uvMin,
                                uvMax: descriptor.uvMax,
                                color: color
                            ))
                        }
                        x += descriptor.advanceFloat
                    } else {
                        x += monoAdvanceFloat
                    }
                }
            }
        }

        // Append gutter rects so they render on top of scrolled content
        rects.append(contentsOf: gutterRects)

        // Append header rects LAST so they render on top of everything
        rects.append(contentsOf: headerRects)

        // Append header instances (regular weight text) after main instances so they render on top
        instances.append(contentsOf: headerInstances)

        // Append header bold instances (filename text) to bold array
        boldInstances.append(contentsOf: headerBoldInstances)

        // Cache results
        cachedInstances = instances
        cachedBoldInstances = boldInstances
        cachedRects = rects
        cachedVisibleRange = visibleRange

        return (instances, boldInstances, rects, false)  // Cache miss - GPU update needed
    }

    /// Generate instances for a file header
    /// Returns regular instances and bold instances separately for proper texture binding
    private func generateFileHeaderInstances(
        section: DiffSection,
        y: Float,
        atlas: FontAtlasManager,
        monoAdvance: Float,
        baselineRatio: Float,
        textVerticalOffset: Float,
        textHorizontalOffset: Float,
        bgWidth: Float,
        colFileHeaderBg: SIMD4<Float>,
        colFileHeaderText: SIMD4<Float>,
        colModifiedIndicator: SIMD4<Float>,
        colAddedText: SIMD4<Float>,
        colRemovedText: SIMD4<Float>
    ) -> (instances: [InstanceData], boldInstances: [InstanceData], rects: [RectInstance]) {
        var instances: [InstanceData] = []      // Regular weight text (M/A indicator, stats)
        var boldInstances: [InstanceData] = []  // Bold weight text (filename)
        let rects: [RectInstance] = []  // No background rect needed - section background handles it

        let headerHeight = Float(DiffSection.headerHeight)
        let lineHeight = Float(self.lineHeight)
        // Vertically center the text in the header
        // The glyph is positioned at charBaselineY with height descriptor.sizeFloat.y
        // For centering: glyph_center = header_center
        // charBaselineY + size.y/2 = y + headerHeight/2
        // Since charBaselineY = baselineY - size.y, we get:
        // baselineY - size.y + size.y/2 = y + headerHeight/2
        // baselineY = y + headerHeight/2 + size.y/2
        // Using lineHeight as the reference height for consistent baseline:
        let baselineY = floor(y + (headerHeight + lineHeight) / 2)
        let asciiGlyphs = atlas.asciiGlyphs
        let boldAsciiGlyphs = atlas.boldAsciiGlyphs

        // Start position after horizontal padding
        var x: Float = horizontalPadding + 12.0

        // Helper to render regular weight text
        func renderText(_ text: String, color: SIMD4<Float>) {
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
                        color: color
                    ))
                    x += descriptor.advanceFloat
                } else {
                    x += monoAdvance
                }
            }
        }

        // Helper to render bold weight text (filename)
        func renderBoldText(_ text: String, color: SIMD4<Float>) {
            for char in text {
                let descriptor: FontAtlasManager.GlyphDescriptor?
                if let asciiValue = char.asciiValue, asciiValue < 128 {
                    descriptor = boldAsciiGlyphs[Int(asciiValue)]
                } else if let glyphIndex = atlas.boldCharToGlyph[char] {
                    descriptor = atlas.boldGlyphDescriptors[glyphIndex]
                } else {
                    descriptor = nil
                }

                if let descriptor = descriptor {
                    let charBaselineY = baselineY - descriptor.sizeFloat.y
                    boldInstances.append(InstanceData(
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
        }

        // Helper to render regular text at specific x position
        func renderTextAt(_ text: String, atX startX: Float, color: SIMD4<Float>) {
            var localX = startX
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
                        origin: [floor(localX + textHorizontalOffset), charBaselineY],
                        size: descriptor.sizeFloat,
                        uvMin: descriptor.uvMin,
                        uvMax: descriptor.uvMax,
                        color: color
                    ))
                    localX += descriptor.advanceFloat
                } else {
                    localX += monoAdvance
                }
            }
        }

        // Helper to render bold text at specific x position (for stats)
        func renderBoldTextAt(_ text: String, atX startX: Float, color: SIMD4<Float>) {
            var localX = startX
            for char in text {
                let descriptor: FontAtlasManager.GlyphDescriptor?
                if let asciiValue = char.asciiValue, asciiValue < 128 {
                    descriptor = boldAsciiGlyphs[Int(asciiValue)]
                } else if let glyphIndex = atlas.boldCharToGlyph[char] {
                    descriptor = atlas.boldGlyphDescriptors[glyphIndex]
                } else {
                    descriptor = nil
                }

                if let descriptor = descriptor {
                    let charBaselineY = baselineY - descriptor.sizeFloat.y
                    boldInstances.append(InstanceData(
                        origin: [floor(localX + textHorizontalOffset), charBaselineY],
                        size: descriptor.sizeFloat,
                        uvMin: descriptor.uvMin,
                        uvMax: descriptor.uvMax,
                        color: color
                    ))
                    localX += descriptor.advanceFloat
                } else {
                    localX += monoAdvance
                }
            }
        }

        // Helper to calculate text width
        func textWidth(_ text: String, bold: Bool = false) -> Float {
            let glyphs = bold ? boldAsciiGlyphs : asciiGlyphs
            let charToGlyph = bold ? atlas.boldCharToGlyph : atlas.charToGlyph
            let glyphDescriptors = bold ? atlas.boldGlyphDescriptors : atlas.glyphDescriptors

            var width: Float = 0
            for char in text {
                if let asciiValue = char.asciiValue, asciiValue < 128,
                   let descriptor = glyphs[Int(asciiValue)] {
                    width += descriptor.advanceFloat
                } else if let glyphIndex = charToGlyph[char],
                          let descriptor = glyphDescriptors[glyphIndex] {
                    width += descriptor.advanceFloat
                } else {
                    width += monoAdvance
                }
            }
            return width
        }

        // M/A indicator (regular weight)
        let indicator = section.isNewFile ? "A" : "M"
        let indicatorColor = section.isNewFile ? colAddedText : colModifiedIndicator
        renderText(indicator, color: indicatorColor)
        x += 10.0

        // +N -M stats on the right side
        let rightPadding: Float = 12.0
        var statsText = ""
        if section.linesAdded > 0 {
            statsText += "+\(section.linesAdded)"
        }
        if section.linesRemoved > 0 {
            if !statsText.isEmpty { statsText += " " }
            statsText += "-\(section.linesRemoved)"
        }

        // Calculate stats width and position (bold weight)
        let statsWidth = statsText.isEmpty ? Float(0) : textWidth(statsText, bold: true)
        let sectionRightEdge = bgWidth - horizontalPadding
        let rightX = sectionRightEdge - rightPadding - statsWidth

        // Filename with truncation (bold weight)
        let filename = section.filename ?? "Unknown file"
        let filenameStartX = x
        let spacingBeforeStats: Float = 16.0
        let maxFilenameWidth = rightX - filenameStartX - spacingBeforeStats
        let ellipsis = "…"
        let ellipsisWidth = textWidth(ellipsis, bold: true)

        let fullFilenameWidth = textWidth(filename, bold: true)
        if fullFilenameWidth <= maxFilenameWidth {
            // Filename fits, render fully with bold weight
            renderBoldText(filename, color: colFileHeaderText)
        } else {
            // Truncate filename
            let targetWidth = maxFilenameWidth - ellipsisWidth
            var truncatedFilename = ""
            var currentWidth: Float = 0

            for char in filename {
                let charWidth: Float
                if let asciiValue = char.asciiValue, asciiValue < 128,
                   let descriptor = boldAsciiGlyphs[Int(asciiValue)] {
                    charWidth = descriptor.advanceFloat
                } else if let glyphIndex = atlas.boldCharToGlyph[char],
                          let descriptor = atlas.boldGlyphDescriptors[glyphIndex] {
                    charWidth = descriptor.advanceFloat
                } else {
                    charWidth = monoAdvance
                }

                if currentWidth + charWidth > targetWidth {
                    break
                }
                truncatedFilename.append(char)
                currentWidth += charWidth
            }

            renderBoldText(truncatedFilename + ellipsis, color: colFileHeaderText)
        }

        // Render stats (bold weight)
        if !statsText.isEmpty {
            var statsX = rightX
            if section.linesAdded > 0 {
                let addedText = "+\(section.linesAdded)"
                renderBoldTextAt(addedText, atX: statsX, color: colAddedText)
                statsX += textWidth(addedText, bold: true) + textWidth(" ", bold: true)
            }
            if section.linesRemoved > 0 {
                let removedText = "-\(section.linesRemoved)"
                renderBoldTextAt(removedText, atX: statsX, color: colRemovedText)
            }
        }

        return (instances, boldInstances, rects)
    }

    // MARK: - Render Cache Management

    func invalidateRenderCache() {
        needsFullRegen = true
        cachedInstances = nil
        cachedBoldInstances = nil
        cachedRects = nil
        cachedVisibleRange = nil
        cachedScrollOffsets.removeAll()
        sectionCaches.removeAll()
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

        // Re-parse syntax highlighting with new appearance
        // This will recompute colors using the current appearance context.
        if !sections.isEmpty {
            parseSyntaxAsync()
        }
    }

    // MARK: - Selection

    /// Convert screen coordinates to global text position
    func screenToTextPosition(
        screenX: Float,
        screenY: Float,
        scrollY: Float,
        monoAdvance: Float
    ) -> GlobalTextPosition? {
        let globalY = screenY + scrollY

        // Find the global line at this Y position
        guard let lineIndex = globalLines.firstIndex(where: { line in
            let lineBottom = Float(line.yOffset) + Float(lineHeight)
            return Float(line.yOffset) <= globalY && globalY < lineBottom
        }) else {
            return nil
        }

        let globalLine = globalLines[lineIndex]

        // Only allow selection on diff lines
        guard globalLine.lineType == .diffLine else {
            return nil
        }

        // Check if click is in content area (past gutter + horizontal padding)
        let contentGutterX = horizontalPadding + gutterWidth
        guard screenX >= contentGutterX else { return nil }

        // Calculate character index
        let contentX = screenX - contentGutterX - contentOffsetX
        let charIndex = max(0, Int(contentX / monoAdvance))

        return GlobalTextPosition(globalLineIndex: lineIndex, charIndex: charIndex)
    }

    func setSelection(start: GlobalTextPosition?, end: GlobalTextPosition?) {
        selectionStart = start
        selectionEnd = end
        // Only mark selection as dirty - don't invalidate the full render cache
        // This allows reusing cached instances while only regenerating selection rects
        selectionDirty = true
        // Don't call objectWillChange.send() - the Metal view calls renderUpdate() directly
    }

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        // Only mark selection as dirty - don't invalidate the full render cache
        selectionDirty = true
        // Don't call objectWillChange.send() - the Metal view calls renderUpdate() directly
    }

    /// Select entire line at global index
    func selectLine(at globalLineIndex: Int) {
        guard globalLineIndex >= 0 && globalLineIndex < globalLines.count else { return }

        let globalLine = globalLines[globalLineIndex]
        guard globalLine.lineType == .diffLine,
              globalLine.localLineIndex >= 0 else { return }

        let section = sections[globalLine.sectionIndex]
        let line = section.diffResult.lines[globalLine.localLineIndex]
        let lineLength = line.content.count

        let start = GlobalTextPosition(globalLineIndex: globalLineIndex, charIndex: 0)
        let end = GlobalTextPosition(globalLineIndex: globalLineIndex, charIndex: lineLength)

        setSelection(start: start, end: end)
    }

    /// Get selected text
    func getSelectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }

        // Normalize
        let (normalStart, normalEnd) = start.globalLineIndex <= end.globalLineIndex ||
            (start.globalLineIndex == end.globalLineIndex && start.charIndex <= end.charIndex)
            ? (start, end) : (end, start)

        var selectedText = ""

        for globalIdx in normalStart.globalLineIndex...normalEnd.globalLineIndex {
            guard globalIdx < globalLines.count else { break }
            let globalLine = globalLines[globalIdx]

            // Skip non-diff lines
            guard globalLine.lineType == .diffLine,
                  globalLine.localLineIndex >= 0 else { continue }

            let section = sections[globalLine.sectionIndex]
            let line = section.diffResult.lines[globalLine.localLineIndex]
            let chars = Array(line.content)

            if globalIdx == normalStart.globalLineIndex && globalIdx == normalEnd.globalLineIndex {
                // Single line selection
                let startIdx = min(normalStart.charIndex, chars.count)
                let endIdx = min(normalEnd.charIndex, chars.count)
                if startIdx < endIdx {
                    selectedText += String(chars[startIdx..<endIdx])
                }
            } else if globalIdx == normalStart.globalLineIndex {
                // First line
                let startIdx = min(normalStart.charIndex, chars.count)
                selectedText += String(chars[startIdx...]) + "\n"
            } else if globalIdx == normalEnd.globalLineIndex {
                // Last line
                let endIdx = min(normalEnd.charIndex, chars.count)
                selectedText += String(chars[..<endIdx])
            } else {
                // Middle lines
                selectedText += line.content + "\n"
            }
        }

        return selectedText.isEmpty ? nil : selectedText
    }

    // MARK: - Syntax Highlighting

    private func parseSyntaxAsync(onlyIndices: [Int]? = nil) {
        guard !sections.isEmpty else { return }

        // Capture the current generation to detect if this parsing becomes stale.
        // If appearance changes while we're parsing, the generation will increment
        // and we should discard our results to avoid overwriting newer colors.
        let parsingGeneration = syntaxParsingGeneration

        // Collect all lines that need parsing
        var linesToParse: [(sectionIndex: Int, localIndex: Int, line: DiffLine, language: String?)] = []

        // Determine which sections to parse
        let sectionsToProcess: [DiffSection]
        if let indices = onlyIndices {
            sectionsToProcess = indices.compactMap { idx in
                idx < sections.count ? sections[idx] : nil
            }
        } else {
            sectionsToProcess = sections
        }

        for section in sectionsToProcess {
            let lang = section.language
            for (localIdx, line) in section.diffResult.lines.enumerated() {
                guard !line.content.isEmpty else { continue }
                // Skip if already cached (unless we're doing incremental update)
                if onlyIndices == nil && charColorCache[line.id] != nil { continue }
                linesToParse.append((section.index, localIdx, line, lang))
            }
        }

        guard !linesToParse.isEmpty else { return }

        // Group by language for efficient parsing
        let grouped = Dictionary(grouping: linesToParse) { $0.language ?? "text" }

        // Capture the current appearance BEFORE going to background thread.
        // NSColor dynamic providers need NSAppearance.current to resolve correctly.
        // Background threads don't inherit the app's appearance, causing wrong colors.
        let currentAppearance = NSApp.effectiveAppearance

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Set the appearance for this thread so NSColor resolves correctly
            NSAppearance.current = currentAppearance

            var newColorCache: [UUID: [SIMD4<Float>]] = [:]
            let defaultColor = AppColors.diffEditorText.simd4
            let parser = FluxParser()

            // Process lines in batches to handle very large diffs
            let batchSize = 500

            for (language, lines) in grouped {
                // Process in batches to avoid memory issues with very large diffs
                var batchStart = 0
                while batchStart < lines.count {
                    let batchEnd = min(batchStart + batchSize, lines.count)
                    let batch = Array(lines[batchStart..<batchEnd])

                    // Build full text for this batch
                    let fullText = batch.map { $0.line.content }.joined(separator: "\n")
                    let lineTokens = parser.parseFullContent(text: fullText, languageName: language)

                    for (contentIndex, lineData) in batch.enumerated() {
                        let line = lineData.line
                        let content = line.content
                        let graphemeCount = content.count  // Grapheme cluster count
                        guard graphemeCount > 0 else { continue }

                        if let tokens = lineTokens[contentIndex], !tokens.isEmpty {
                            // Build UTF-16 code unit to grapheme cluster index mapping
                            // Token ranges from FluxParser are in UTF-16 code units, but we need
                            // grapheme cluster indices for rendering (which iterates over Characters)
                            var utf16ToGrapheme: [Int] = []
                            utf16ToGrapheme.reserveCapacity(content.utf16.count + 1)
                            var graphemeIdx = 0
                            for char in content {
                                let utf16Count = char.utf16.count
                                for _ in 0..<utf16Count {
                                    utf16ToGrapheme.append(graphemeIdx)
                                }
                                graphemeIdx += 1
                            }
                            // Add sentinel for end-of-string
                            utf16ToGrapheme.append(graphemeIdx)

                            // Sort by priority
                            let sortedTokens = tokens.sorted { t1, t2 in
                                Self.tokenPriority(for: t1.scope) < Self.tokenPriority(for: t2.scope)
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
                        }
                    }

                    batchStart = batchEnd
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Check if this parsing is still current.
                // If appearance changed while we were parsing, discard results to avoid
                // overwriting the cache with colors computed for the old appearance.
                guard parsingGeneration == self.syntaxParsingGeneration else {
                    // Parsing is stale - a newer appearance change has occurred.
                    // Don't apply these colors; a new parsing is in progress.
                    return
                }

                // OPTIMIZATION: Only update if we have new colors to add
                // This prevents unnecessary re-renders for completed sessions
                guard !newColorCache.isEmpty else { return }

                // Merge new colors into cache
                for (id, colors) in newColorCache {
                    self.charColorCache[id] = colors
                }

                // Trim if needed
                if self.charColorCache.count > self.maxCacheSize {
                    self.trimCache()
                }

                self.invalidateRenderCache()
                self.objectWillChange.send()
            }
        }
    }

    private func trimCache() {
        // Keep colors for visible lines plus buffer
        let visibleRange = visibleLineRange()
        let buffer = 200
        let keepStart = max(0, visibleRange.lowerBound - buffer)
        let keepEnd = min(globalLines.count, visibleRange.upperBound + buffer)

        var idsToKeep = Set<UUID>()
        for idx in keepStart..<keepEnd {
            let globalLine = globalLines[idx]
            if globalLine.lineType == .diffLine && globalLine.localLineIndex >= 0 {
                let section = sections[globalLine.sectionIndex]
                if globalLine.localLineIndex < section.diffResult.lines.count {
                    idsToKeep.insert(section.diffResult.lines[globalLine.localLineIndex].id)
                }
            }
        }

        charColorCache = charColorCache.filter { idsToKeep.contains($0.key) }
        tokenCache = tokenCache.filter { idsToKeep.contains($0.key) }
    }

    nonisolated private static func tokenPriority(for scope: String) -> Int {
        if scope.contains("variable") || scope.contains("identifier") { return 0 }
        if scope.contains("property") { return 1 }
        if scope.contains("type") { return 2 }
        if scope.contains("function") || scope.contains("method") { return 3 }
        if scope.contains("number") || scope.contains("boolean") { return 4 }
        if scope.contains("keyword") || scope.contains("operator") { return 5 }
        if scope.contains("string") { return 6 }
        if scope.contains("comment") { return 7 }
        return 0
    }

    // MARK: - Scroll to File

    /// Get Y offset for a file by name
    func yOffset(forFilename filename: String) -> CGFloat? {
        let targetLower = filename.lowercased()

        for section in sections {
            guard let sectionFilename = section.filename?.lowercased() else { continue }

            if sectionFilename == targetLower ||
               sectionFilename.hasSuffix("/\(targetLower)") ||
               sectionFilename.hasSuffix("\\\(targetLower)") {
                return section.yOffset
            }
        }

        return nil
    }

    // MARK: - Memory Management

    func releaseMemory() {
        charColorCache.removeAll(keepingCapacity: false)
        tokenCache.removeAll(keepingCapacity: false)
        cachedInstances = nil
        cachedRects = nil
        needsFullRegen = true
    }

    deinit {
        fontSizeCancellable?.cancel()
        charColorCache.removeAll(keepingCapacity: false)
        tokenCache.removeAll(keepingCapacity: false)
    }
}
