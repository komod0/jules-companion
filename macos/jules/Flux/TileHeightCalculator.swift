import Foundation
import CoreGraphics

/// Pre-calculates the height of all diff lines using font metrics on a background thread.
/// This decouples layout from rendering, eliminating scrollbar jumping and instability.
///
/// Key benefits:
/// - Heights are computed once upfront, not during scroll
/// - Layout is completely deterministic
/// - No layout recalculation during scrolling
@MainActor
final class TileHeightCalculator {
    static let shared = TileHeightCalculator()

    // MARK: - Types

    /// Pre-calculated layout for a diff
    struct DiffLayout {
        /// Total height of all content in points
        let totalHeight: CGFloat

        /// Y offset for each line (cumulative)
        let lineOffsets: [CGFloat]

        /// Height of each line
        let lineHeights: [CGFloat]

        /// Pre-computed tile boundaries
        let tiles: [TileLayout]

        /// Line height used for this layout
        let lineHeight: CGFloat

        /// Number of content lines (excluding file headers)
        let contentLineCount: Int
    }

    /// Pre-computed tile layout
    struct TileLayout: Identifiable {
        let id: Int
        let startLine: Int
        let endLine: Int
        let yOffset: CGFloat
        let height: CGFloat
    }

    // MARK: - Properties

    /// Cache of computed layouts
    private var layoutCache: [LayoutCacheKey: DiffLayout] = [:]

    /// Maximum cache entries
    private let maxCacheEntries = 20

    /// Maximum tile height in points (matches TiledFluxDiffView)
    private let maxTileHeightPoints: CGFloat = 4000

    // MARK: - Cache Key

    private struct LayoutCacheKey: Hashable {
        let diffId: ObjectIdentifier
        let lineCount: Int
        let lineHeight: CGFloat
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Get or compute the layout for a diff result.
    /// This is a synchronous call that returns cached results when available.
    /// For very large diffs, consider calling `precomputeLayoutAsync` first.
    func getLayout(for diffResult: DiffResult, lineHeight: CGFloat) -> DiffLayout {
        let key = LayoutCacheKey(
            diffId: ObjectIdentifier(diffResult.lines as AnyObject),
            lineCount: diffResult.lines.count,
            lineHeight: lineHeight
        )

        if let cached = layoutCache[key] {
            return cached
        }

        let layout = computeLayout(for: diffResult, lineHeight: lineHeight)
        cacheLayout(layout, for: key)
        return layout
    }

    /// Asynchronously pre-compute layout for a diff result.
    /// Call this when loading a new diff to avoid blocking the main thread.
    func precomputeLayoutAsync(
        for diffResult: DiffResult,
        lineHeight: CGFloat,
        completion: @escaping (DiffLayout) -> Void
    ) {
        let key = LayoutCacheKey(
            diffId: ObjectIdentifier(diffResult.lines as AnyObject),
            lineCount: diffResult.lines.count,
            lineHeight: lineHeight
        )

        // Return cached if available
        if let cached = layoutCache[key] {
            completion(cached)
            return
        }

        // Capture what we need for background computation
        let lines = diffResult.lines

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layout = Self.computeLayoutSync(
                lines: lines,
                lineHeight: lineHeight,
                maxTileHeightPoints: self?.maxTileHeightPoints ?? 4000
            )

            DispatchQueue.main.async { [weak self] in
                self?.cacheLayout(layout, for: key)
                completion(layout)
            }
        }
    }

    /// Get the Y offset for a specific line index
    func lineOffset(in layout: DiffLayout, lineIndex: Int) -> CGFloat {
        guard lineIndex >= 0, lineIndex < layout.lineOffsets.count else {
            return 0
        }
        return layout.lineOffsets[lineIndex]
    }

    /// Get the tile index that contains a specific Y position
    func tileIndex(in layout: DiffLayout, forY y: CGFloat) -> Int {
        for (index, tile) in layout.tiles.enumerated() {
            if y >= tile.yOffset && y < tile.yOffset + tile.height {
                return index
            }
        }
        return max(0, layout.tiles.count - 1)
    }

    /// Get visible tile indices for a viewport
    func visibleTileIndices(
        in layout: DiffLayout,
        viewportTop: CGFloat,
        viewportBottom: CGFloat,
        buffer: Int = 2
    ) -> Range<Int> {
        guard !layout.tiles.isEmpty else { return 0..<0 }

        var firstVisible = 0
        var lastVisible = layout.tiles.count - 1

        // Find first visible tile
        for (index, tile) in layout.tiles.enumerated() {
            if tile.yOffset + tile.height > viewportTop {
                firstVisible = index
                break
            }
        }

        // Find last visible tile
        for (index, tile) in layout.tiles.enumerated().reversed() {
            if tile.yOffset < viewportBottom {
                lastVisible = index
                break
            }
        }

        // Add buffer for prefetching
        let bufferedFirst = max(0, firstVisible - buffer)
        let bufferedLast = min(layout.tiles.count - 1, lastVisible + buffer)

        return bufferedFirst..<(bufferedLast + 1)
    }

    /// Invalidate cached layout for a diff
    func invalidate(for diffResult: DiffResult) {
        let diffId = ObjectIdentifier(diffResult.lines as AnyObject)
        layoutCache = layoutCache.filter { $0.key.diffId != diffId }
    }

    /// Clear all cached layouts
    func clearCache() {
        layoutCache.removeAll()
    }

    // MARK: - Private Methods

    private func computeLayout(for diffResult: DiffResult, lineHeight: CGFloat) -> DiffLayout {
        return Self.computeLayoutSync(
            lines: diffResult.lines,
            lineHeight: lineHeight,
            maxTileHeightPoints: maxTileHeightPoints
        )
    }

    /// Thread-safe layout computation that doesn't access shared state
    private nonisolated static func computeLayoutSync(
        lines: [DiffLine],
        lineHeight: CGFloat,
        maxTileHeightPoints: CGFloat
    ) -> DiffLayout {
        // Filter out file headers for content calculation
        let contentLines = lines.filter { $0.type != .fileHeader }
        let contentLineCount = contentLines.count

        // Pre-allocate arrays
        var lineOffsets = [CGFloat](repeating: 0, count: contentLineCount)
        var lineHeights = [CGFloat](repeating: lineHeight, count: contentLineCount)

        // Compute cumulative offsets
        var currentY: CGFloat = 0
        for i in 0..<contentLineCount {
            lineOffsets[i] = currentY
            currentY += lineHeight
        }

        let totalHeight = max(currentY, 60) // Minimum height

        // Compute tile boundaries
        var tiles: [TileLayout] = []

        if totalHeight <= maxTileHeightPoints {
            // Single tile
            tiles.append(TileLayout(
                id: 0,
                startLine: 0,
                endLine: contentLineCount,
                yOffset: 0,
                height: totalHeight
            ))
        } else {
            // Multiple tiles
            let linesPerTile = Int(maxTileHeightPoints / lineHeight)
            var currentLine = 0
            var tileIndex = 0
            var tileYOffset: CGFloat = 0

            while currentLine < contentLineCount {
                let endLine = min(currentLine + linesPerTile, contentLineCount)
                let tileLines = endLine - currentLine
                let tileHeight = CGFloat(tileLines) * lineHeight

                tiles.append(TileLayout(
                    id: tileIndex,
                    startLine: currentLine,
                    endLine: endLine,
                    yOffset: tileYOffset,
                    height: tileHeight
                ))

                tileYOffset += tileHeight
                currentLine = endLine
                tileIndex += 1
            }
        }

        return DiffLayout(
            totalHeight: totalHeight,
            lineOffsets: lineOffsets,
            lineHeights: lineHeights,
            tiles: tiles,
            lineHeight: lineHeight,
            contentLineCount: contentLineCount
        )
    }

    private func cacheLayout(_ layout: DiffLayout, for key: LayoutCacheKey) {
        // Evict old entries if cache is full
        if layoutCache.count >= maxCacheEntries {
            // Remove oldest entries (arbitrary selection)
            let keysToRemove = Array(layoutCache.keys.prefix(maxCacheEntries / 2))
            for k in keysToRemove {
                layoutCache.removeValue(forKey: k)
            }
        }

        layoutCache[key] = layout
    }
}
