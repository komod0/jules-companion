//
//  MergeConflictViewModel.swift
//  jules
//
//  ViewModel for Metal-based merge conflict rendering.
//  Manages conflict parsing, line layout, and instance generation for GPU rendering.
//

import Foundation
import CoreGraphics
import simd
import AppKit
import Combine

// MARK: - Conflict Line Types

/// Type of line in the merge conflict view
enum ConflictLineType: Equatable {
    case normal           // Regular code line (outside conflicts)
    case currentMarker    // <<<<<<< marker
    case currentContent   // Content in "ours" section
    case separator        // ======= marker
    case incomingContent  // Content in "theirs" section
    case incomingMarker   // >>>>>>> marker
}

// MARK: - Conflict Line Model

/// Represents a single line in the merge conflict view
struct ConflictLine: Identifiable, Equatable {
    let id = UUID()
    let type: ConflictLineType
    let content: String
    let lineNumber: Int?        // Original line number (nil for conflict markers)
    let conflictIndex: Int?     // Which conflict this line belongs to (nil for normal lines)
}

// MARK: - Conflict Region Model

/// Represents a single merge conflict region
struct ConflictRegion: Identifiable, Equatable {
    let id: UUID
    let startLineIndex: Int     // Line index of <<<<<<< marker
    let separatorLineIndex: Int // Line index of ======= marker
    let endLineIndex: Int       // Line index of >>>>>>> marker
    let currentContent: String  // "Ours" content
    let incomingContent: String // "Theirs" content
    var resolution: ConflictResolutionChoice?  // User's choice (nil = unresolved)

    var isResolved: Bool { resolution != nil }
}

// MARK: - Text Position

/// Position in the text for selection purposes
struct ConflictTextPosition: Equatable, Hashable {
    let lineIndex: Int
    let charIndex: Int
}

// MARK: - MergeConflictViewModel

/// ViewModel that manages merge conflict content for Metal rendering.
@MainActor
final class MergeConflictViewModel: ObservableObject {

    // MARK: - Content Data

    /// All lines in the document
    private(set) var lines: [ConflictLine] = []

    /// All conflict regions
    private(set) var conflicts: [ConflictRegion] = []

    /// Total content height
    private(set) var totalContentHeight: CGFloat = 0

    /// The raw text content
    private(set) var rawContent: String = ""

    /// Language for syntax highlighting
    var language: String? = "swift"

    // MARK: - Layout Configuration

    /// Line height from FontSizeManager
    var lineHeight: CGFloat {
        CGFloat(FontSizeManager.shared.diffLineHeight)
    }

    /// Gutter width for line numbers
    var gutterWidth: Float {
        let lh = Float(FontSizeManager.shared.diffLineHeight)
        return max(60.0, lh * 3.0)
    }

    /// Content offset after gutter
    var contentOffsetX: Float {
        let lh = Float(FontSizeManager.shared.diffLineHeight)
        return max(10.0, lh * 0.5)
    }

    /// Horizontal padding
    let horizontalPadding: Float = 16.0

    /// Vertical padding
    let verticalPadding: CGFloat = 16

    // MARK: - Viewport State

    private var viewportTop: CGFloat = 0
    private var viewportBottom: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var viewportWidth: CGFloat = 800

    /// Horizontal scroll offset
    private var scrollOffsetX: CGFloat = 0

    /// Mono advance (character width)
    private var monoAdvance: CGFloat = 8.0

    /// Tracks whether monoAdvance has been set
    private(set) var hasValidMonoAdvance: Bool = false

    // MARK: - Syntax Highlighting Cache

    /// Cached syntax colors per line (keyed by line UUID)
    private var charColorCache: [UUID: [SIMD4<Float>]] = [:]

    // MARK: - Render Cache

    private var cachedInstances: [InstanceData]?
    private var cachedRects: [RectInstance]?
    private var cachedVisibleRange: Range<Int>?
    private var needsFullRegen: Bool = true
    private var cachedScrollOffsetX: CGFloat = 0

    /// Generation counter for syntax parsing.
    /// Incremented on appearance changes to invalidate in-flight parsing results.
    /// This prevents race conditions where an older parsing (started before appearance change)
    /// could overwrite newer colors with stale values.
    private var syntaxParsingGeneration: Int = 0

    // MARK: - Selection State

    var selectionStart: ConflictTextPosition?
    var selectionEnd: ConflictTextPosition?
    private var selectionDirty = false

    // MARK: - Font Size Subscription

    private var fontSizeCancellable: AnyCancellable?

    // MARK: - Conflict Actions Callback

    /// Callback when user wants to resolve a conflict
    var onResolveConflict: ((UUID, ConflictResolutionChoice) -> Void)?

    // MARK: - Initialization

    init() {
        setupFontSizeSubscription()
    }

    private func setupFontSizeSubscription() {
        fontSizeCancellable = FontSizeManager.shared.diffFontSizeChanged
            .sink { [weak self] _ in
                // Use Task to defer the state update and avoid
                // "Publishing changes from within view updates" warning.
                // The font size publisher might fire during a view update cycle.
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.rebuildLayout()
                    self.invalidateRenderCache()
                    self.objectWillChange.send()
                }
            }
    }

    // MARK: - Content Updates

    /// Update content from raw text
    func updateContent(_ text: String) {
        guard text != rawContent else { return }
        rawContent = text
        parseContent()
        rebuildLayout()
        clampViewportToContent()
        parseSyntaxAsync()
        invalidateRenderCache()
        objectWillChange.send()
    }

    /// Clamp viewport to content bounds after content changes
    /// This prevents stale scroll positions when content shrinks (e.g., after resolving a conflict)
    private func clampViewportToContent() {
        guard totalContentHeight > 0 else { return }

        // Calculate max valid scroll position
        let maxScrollY = max(0, totalContentHeight - viewportHeight)

        // If viewport extends beyond content, clamp it
        if viewportTop > maxScrollY {
            viewportTop = maxScrollY
            viewportBottom = viewportTop + viewportHeight
        }
    }

    /// Parse text content into lines and conflicts
    private func parseContent() {
        let textLines = rawContent.components(separatedBy: "\n")
        var parsedLines: [ConflictLine] = []
        var parsedConflicts: [ConflictRegion] = []

        var currentConflictIndex: Int? = nil
        var conflictStartLine: Int? = nil
        var conflictSeparatorLine: Int? = nil
        var currentContent: [String] = []
        var incomingContent: [String] = []
        var inCurrentSection = false
        var inIncomingSection = false
        var displayLineNumber = 1

        for (index, line) in textLines.enumerated() {
            if line.hasPrefix("<<<<<<<") {
                // Start of conflict
                currentConflictIndex = parsedConflicts.count
                conflictStartLine = parsedLines.count
                inCurrentSection = true
                inIncomingSection = false
                currentContent = []
                incomingContent = []

                parsedLines.append(ConflictLine(
                    type: .currentMarker,
                    content: line,
                    lineNumber: nil,
                    conflictIndex: currentConflictIndex
                ))
            } else if line.hasPrefix("=======") && inCurrentSection {
                // Separator
                conflictSeparatorLine = parsedLines.count
                inCurrentSection = false
                inIncomingSection = true

                parsedLines.append(ConflictLine(
                    type: .separator,
                    content: line,
                    lineNumber: nil,
                    conflictIndex: currentConflictIndex
                ))
            } else if line.hasPrefix(">>>>>>>") && inIncomingSection {
                // End of conflict
                let endLineIndex = parsedLines.count

                parsedLines.append(ConflictLine(
                    type: .incomingMarker,
                    content: line,
                    lineNumber: nil,
                    conflictIndex: currentConflictIndex
                ))

                // Create conflict region
                if let startLine = conflictStartLine, let sepLine = conflictSeparatorLine {
                    parsedConflicts.append(ConflictRegion(
                        id: UUID(),
                        startLineIndex: startLine,
                        separatorLineIndex: sepLine,
                        endLineIndex: endLineIndex,
                        currentContent: currentContent.joined(separator: "\n"),
                        incomingContent: incomingContent.joined(separator: "\n"),
                        resolution: nil
                    ))
                }

                currentConflictIndex = nil
                conflictStartLine = nil
                conflictSeparatorLine = nil
                inCurrentSection = false
                inIncomingSection = false
            } else if inCurrentSection {
                // Content in "current" section
                currentContent.append(line)
                parsedLines.append(ConflictLine(
                    type: .currentContent,
                    content: line,
                    lineNumber: displayLineNumber,
                    conflictIndex: currentConflictIndex
                ))
                displayLineNumber += 1
            } else if inIncomingSection {
                // Content in "incoming" section
                incomingContent.append(line)
                parsedLines.append(ConflictLine(
                    type: .incomingContent,
                    content: line,
                    lineNumber: displayLineNumber,
                    conflictIndex: currentConflictIndex
                ))
                displayLineNumber += 1
            } else {
                // Normal line
                parsedLines.append(ConflictLine(
                    type: .normal,
                    content: line,
                    lineNumber: displayLineNumber,
                    conflictIndex: nil
                ))
                displayLineNumber += 1
            }
        }

        self.lines = parsedLines
        self.conflicts = parsedConflicts
    }

    /// Rebuild layout calculations
    private func rebuildLayout() {
        totalContentHeight = verticalPadding * 2 + CGFloat(lines.count) * lineHeight
    }

    // MARK: - Viewport & Visible Range

    /// Update viewport for visible line calculation
    func setViewport(top: CGFloat, height: CGFloat, width: CGFloat? = nil) {
        viewportHeight = height
        if let width = width {
            viewportWidth = max(width, 400)
        }

        // Clamp viewport top to valid content bounds
        // This prevents rendering issues when scroll position is stale after content shrinks
        let maxScrollY = max(0, totalContentHeight - height)
        viewportTop = min(top, maxScrollY)
        viewportTop = max(0, viewportTop)
        viewportBottom = viewportTop + height
    }

    /// Get horizontal scroll offset
    func getScrollOffsetX() -> CGFloat {
        return scrollOffsetX
    }

    /// Set horizontal scroll offset
    func setScrollOffsetX(_ offset: CGFloat) {
        let maxScroll = maxScrollX()
        scrollOffsetX = max(0, min(offset, maxScroll))
    }

    /// Adjust horizontal scroll by delta
    func adjustScrollOffsetX(delta: CGFloat) {
        setScrollOffsetX(scrollOffsetX - delta)
    }

    /// Calculate max horizontal scroll
    func maxScrollX() -> CGFloat {
        // Calculate based on longest line
        let maxLineLength = lines.map { $0.content.count }.max() ?? 0
        let contentWidth = CGFloat(horizontalPadding) + CGFloat(gutterWidth) + CGFloat(contentOffsetX) +
            CGFloat(maxLineLength) * monoAdvance + 100
        return max(0, contentWidth - viewportWidth)
    }

    /// Update mono advance from font atlas
    func updateMonoAdvance(_ advance: CGFloat) {
        monoAdvance = advance
        hasValidMonoAdvance = true
    }

    /// Get visible line range
    func visibleLineRange() -> Range<Int> {
        guard !lines.isEmpty else { return 0..<0 }

        let firstVisible = max(0, Int(floor((viewportTop - verticalPadding) / lineHeight)))
        let lastVisible = min(lines.count - 1, Int(ceil((viewportBottom - verticalPadding) / lineHeight)))

        // Handle case where viewport is scrolled beyond content bounds
        // This can happen when content shrinks (e.g., after accepting a conflict resolution)
        // and the scroll position hasn't been adjusted yet
        guard firstVisible <= lastVisible else {
            // Return the last visible portion of content as a fallback
            let safeStart = max(0, lines.count - Int(viewportHeight / lineHeight) - 10)
            return safeStart..<lines.count
        }

        // Add buffer for smooth scrolling
        let buffer = 10
        let bufferedFirst = max(0, firstVisible - buffer)
        let bufferedLast = min(lines.count, lastVisible + buffer + 1)

        return bufferedFirst..<bufferedLast
    }

    // MARK: - Conflict Info for Button Positioning

    /// Get conflict regions with their Y positions for button overlay
    func conflictButtonPositions() -> [(conflict: ConflictRegion, yPosition: CGFloat)] {
        return conflicts.filter { !$0.isResolved }.map { conflict in
            let yPos = verticalPadding + CGFloat(conflict.startLineIndex) * lineHeight
            return (conflict, yPos)
        }
    }

    // MARK: - Instance Generation

    /// Generate Metal instances for visible lines
    func generateInstances(
        renderer: FluxRenderer
    ) -> (instances: [InstanceData], rects: [RectInstance], isCacheHit: Bool) {
        let visibleRange = visibleLineRange()

        guard !visibleRange.isEmpty else {
            return ([], [], true)
        }

        // Check cache
        let scrollOffsetMatch = scrollOffsetX == cachedScrollOffsetX
        if !needsFullRegen,
           !selectionDirty,
           scrollOffsetMatch,
           let cached = cachedInstances,
           let cachedR = cachedRects,
           let prevRange = cachedVisibleRange,
           visibleRange.lowerBound >= prevRange.lowerBound,
           visibleRange.upperBound <= prevRange.upperBound {
            return (cached, cachedR, true)
        }

        needsFullRegen = false
        selectionDirty = false
        cachedScrollOffsetX = scrollOffsetX

        let atlas = renderer.fontAtlasManager
        let monoAdvanceFloat = atlas.monoAdvance
        let lh = Float(lineHeight)

        // Update monoAdvance
        self.monoAdvance = CGFloat(monoAdvanceFloat)

        // Pre-allocate
        var instances: [InstanceData] = []
        var rects: [RectInstance] = []
        instances.reserveCapacity(visibleRange.count * 50)
        rects.reserveCapacity(visibleRange.count * 3)

        // Colors
        let colCurrentBg = AppColors.conflictEditorCurrentBg.simd4
        let colIncomingBg = AppColors.conflictEditorIncomingBg.simd4
        let colMarkerBg = AppColors.conflictEditorMarkerBg.simd4
        let colMarkerText = AppColors.conflictEditorMarkerText.simd4
        let colTextDefault = AppColors.diffEditorText.simd4
        let colGutterText = AppColors.diffEditorGutter.simd4
        let colGutterBg = AppColors.diffEditorGutterBg.simd4
        let colEditorBg = AppColors.diffEditorBackground.simd4
        let colSelection = AppColors.diffEditorSelection.simd4
        let colGutterSeparator = AppColors.diffEditorGutterSeparator.simd4

        // Text alignment
        let baselineRatio: Float = 0.78
        let textVerticalOffset: Float = lh * 0.25
        let textHorizontalOffset: Float = -4

        let sectionScrollX = Float(scrollOffsetX)
        let contentAreaX = horizontalPadding + gutterWidth
        let contentRightEdge = Float(viewportWidth) - horizontalPadding

        // Editor background
        rects.append(RectInstance(
            origin: [0, 0],
            size: [Float(viewportWidth), Float(totalContentHeight)],
            color: colEditorBg
        ))

        // Gutter background
        rects.append(RectInstance(
            origin: [0, 0],
            size: [horizontalPadding + gutterWidth, Float(totalContentHeight)],
            color: colGutterBg
        ))

        // Gutter separator
        rects.append(RectInstance(
            origin: [horizontalPadding + gutterWidth - 1, 0],
            size: [1, Float(totalContentHeight)],
            color: colGutterSeparator
        ))

        // Normalize selection
        var normalizedSelStart: ConflictTextPosition?
        var normalizedSelEnd: ConflictTextPosition?
        if let start = selectionStart, let end = selectionEnd {
            if start.lineIndex < end.lineIndex ||
               (start.lineIndex == end.lineIndex && start.charIndex <= end.charIndex) {
                normalizedSelStart = start
                normalizedSelEnd = end
            } else {
                normalizedSelStart = end
                normalizedSelEnd = start
            }
        }

        let asciiGlyphs = atlas.asciiGlyphs

        // Render visible lines
        for lineIdx in visibleRange {
            let line = lines[lineIdx]
            let currentY = Float(verticalPadding) + Float(lineIdx) * lh
            let baselineY = floor(currentY + (lh * baselineRatio) + textVerticalOffset)
            let chars = Array(line.content)

            // Line background based on type
            let lineBgColor: SIMD4<Float>?
            switch line.type {
            case .currentMarker, .separator, .incomingMarker:
                lineBgColor = colMarkerBg
            case .currentContent:
                lineBgColor = colCurrentBg
            case .incomingContent:
                lineBgColor = colIncomingBg
            case .normal:
                lineBgColor = nil
            }

            if let bgColor = lineBgColor {
                rects.append(RectInstance(
                    origin: [contentAreaX, currentY],
                    size: [contentRightEdge - contentAreaX, lh],
                    color: bgColor
                ))
            }

            // Line number (only for content lines)
            if let lineNum = line.lineNumber {
                var gutterX: Float = horizontalPadding + 4.0
                for char in String(lineNum) {
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

            // Selection highlight
            if let selStart = normalizedSelStart, let selEnd = normalizedSelEnd {
                if lineIdx >= selStart.lineIndex && lineIdx <= selEnd.lineIndex {
                    var startChar = 0
                    var endChar = chars.count

                    if lineIdx == selStart.lineIndex {
                        startChar = min(selStart.charIndex, chars.count)
                    }
                    if lineIdx == selEnd.lineIndex {
                        endChar = min(selEnd.charIndex, chars.count)
                    }

                    if startChar < endChar {
                        var selX = floor(contentAreaX + contentOffsetX + Float(startChar) * monoAdvanceFloat - sectionScrollX)
                        var selWidth = floor(Float(endChar - startChar) * monoAdvanceFloat)

                        // Clip to content area
                        if selX < contentAreaX {
                            let clip = contentAreaX - selX
                            selWidth -= clip
                            selX = contentAreaX
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

            // Text content
            let textColor: SIMD4<Float>
            switch line.type {
            case .currentMarker, .separator, .incomingMarker:
                textColor = colMarkerText
            default:
                textColor = colTextDefault
            }

            // Use syntax colors if available
            let cachedColors = charColorCache[line.id]
            var x: Float = floor(contentAreaX + contentOffsetX) - sectionScrollX

            for charIndex in chars.indices {
                let char = chars[charIndex]

                // Skip whitespace rendering
                if char == " " {
                    x += monoAdvanceFloat
                    continue
                } else if char == "\t" {
                    x += monoAdvanceFloat * 4
                    continue
                }

                let color = cachedColors?[charIndex] ?? textColor

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
                    // Clip to content area
                    if charX + descriptor.sizeFloat.x > contentAreaX && charX < contentRightEdge {
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

        // Cache results
        cachedInstances = instances
        cachedRects = rects
        cachedVisibleRange = visibleRange

        return (instances, rects, false)
    }

    // MARK: - Render Cache Management

    func invalidateRenderCache() {
        needsFullRegen = true
        cachedInstances = nil
        cachedRects = nil
        cachedVisibleRange = nil
    }

    /// Called when appearance changes
    func invalidateForAppearanceChange() {
        // Increment generation to invalidate any in-flight syntax parsing.
        // This prevents a race condition where parsing started before the appearance change
        // could complete after our new parsing and overwrite the cache with stale colors.
        syntaxParsingGeneration += 1

        charColorCache.removeAll()
        invalidateRenderCache()

        // Trigger immediate re-render for background colors.
        // Since charColorCache is cleared, syntax will use default text color temporarily.
        // When parsing completes, another objectWillChange.send() will update syntax colors.
        objectWillChange.send()

        // Re-parse syntax highlighting with new appearance.
        if !lines.isEmpty {
            parseSyntaxAsync()
        }
    }

    // MARK: - Selection

    /// Convert screen coordinates to text position
    func screenToTextPosition(
        screenX: Float,
        screenY: Float,
        scrollY: Float,
        monoAdvance: Float
    ) -> ConflictTextPosition? {
        let globalY = screenY + scrollY

        // Find line at Y position
        let lineIndex = Int(floor((globalY - Float(verticalPadding)) / Float(lineHeight)))
        guard lineIndex >= 0 && lineIndex < lines.count else { return nil }

        // Check if in content area
        let contentAreaX = horizontalPadding + gutterWidth
        guard screenX >= contentAreaX else { return nil }

        // Calculate character index
        let contentX = screenX - contentAreaX - contentOffsetX
        let charIndex = max(0, Int(contentX / monoAdvance))

        return ConflictTextPosition(lineIndex: lineIndex, charIndex: charIndex)
    }

    func setSelection(start: ConflictTextPosition?, end: ConflictTextPosition?) {
        selectionStart = start
        selectionEnd = end
        selectionDirty = true
    }

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        selectionDirty = true
    }

    /// Get selected text
    func getSelectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }

        let (normalStart, normalEnd) = start.lineIndex <= end.lineIndex ||
            (start.lineIndex == end.lineIndex && start.charIndex <= end.charIndex)
            ? (start, end) : (end, start)

        var selectedText = ""

        for lineIdx in normalStart.lineIndex...normalEnd.lineIndex {
            guard lineIdx < lines.count else { break }
            let line = lines[lineIdx]
            let chars = Array(line.content)

            if lineIdx == normalStart.lineIndex && lineIdx == normalEnd.lineIndex {
                let startIdx = min(normalStart.charIndex, chars.count)
                let endIdx = min(normalEnd.charIndex, chars.count)
                if startIdx < endIdx {
                    selectedText += String(chars[startIdx..<endIdx])
                }
            } else if lineIdx == normalStart.lineIndex {
                let startIdx = min(normalStart.charIndex, chars.count)
                selectedText += String(chars[startIdx...]) + "\n"
            } else if lineIdx == normalEnd.lineIndex {
                let endIdx = min(normalEnd.charIndex, chars.count)
                selectedText += String(chars[..<endIdx])
            } else {
                selectedText += line.content + "\n"
            }
        }

        return selectedText.isEmpty ? nil : selectedText
    }

    // MARK: - Syntax Highlighting

    private func parseSyntaxAsync() {
        guard !lines.isEmpty else { return }

        // Capture the current generation to detect if this parsing becomes stale.
        // If appearance changes while we're parsing, the generation will increment
        // and we should discard our results to avoid overwriting newer colors.
        let parsingGeneration = syntaxParsingGeneration

        // Collect lines for parsing (exclude markers)
        var linesToParse: [(index: Int, line: ConflictLine)] = []
        for (index, line) in lines.enumerated() {
            guard !line.content.isEmpty else { continue }
            guard line.type != .currentMarker && line.type != .separator && line.type != .incomingMarker else { continue }
            if charColorCache[line.id] != nil { continue }
            linesToParse.append((index, line))
        }

        guard !linesToParse.isEmpty else { return }

        let currentAppearance = NSApp.effectiveAppearance
        let lang = language ?? "swift"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            NSAppearance.current = currentAppearance

            var newColorCache: [UUID: [SIMD4<Float>]] = [:]
            let defaultColor = AppColors.diffEditorText.simd4
            let parser = FluxParser()

            // Build full text for parsing
            let fullText = linesToParse.map { $0.line.content }.joined(separator: "\n")
            let lineTokens = parser.parseFullContent(text: fullText, languageName: lang)

            for (contentIndex, lineData) in linesToParse.enumerated() {
                let line = lineData.line
                let content = line.content
                let graphemeCount = content.count
                guard graphemeCount > 0 else { continue }

                if let tokens = lineTokens[contentIndex], !tokens.isEmpty {
                    // Build UTF-16 to grapheme mapping
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
                    utf16ToGrapheme.append(graphemeIdx)

                    var colors = [SIMD4<Float>](repeating: defaultColor, count: graphemeCount)
                    for token in tokens {
                        if let c = token.color.usingColorSpace(.sRGB) {
                            let simdColor = SIMD4<Float>(
                                Float(c.redComponent),
                                Float(c.greenComponent),
                                Float(c.blueComponent),
                                Float(c.alphaComponent)
                            )
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

            // Use Task to ensure we're not in the middle of a SwiftUI view update cycle.
            // DispatchQueue.main.async might still execute during a view update if the
            // main queue is processing work synchronously. Task defers execution properly.
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Check if this parsing is still current.
                // If appearance changed while we were parsing, discard results to avoid
                // overwriting the cache with colors computed for the old appearance.
                guard parsingGeneration == self.syntaxParsingGeneration else {
                    // Parsing is stale - a newer appearance change has occurred.
                    // Don't apply these colors; a new parsing is in progress.
                    return
                }

                for (id, colors) in newColorCache {
                    self.charColorCache[id] = colors
                }

                self.invalidateRenderCache()
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Memory Management

    func releaseMemory() {
        charColorCache.removeAll(keepingCapacity: false)
        cachedInstances = nil
        cachedRects = nil
        needsFullRegen = true
    }

    deinit {
        fontSizeCancellable?.cancel()
        charColorCache.removeAll(keepingCapacity: false)
    }
}
