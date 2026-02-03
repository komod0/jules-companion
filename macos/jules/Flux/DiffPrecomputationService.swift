import Foundation
import CoreGraphics

/// Service that pre-computes DiffResults and their layouts in the background when diffs first load.
/// This eliminates the stall that occurs when scrolling to a large diff for the first time.
///
/// Key benefits:
/// - DiffResults are parsed before the user scrolls to them
/// - TileHeightCalculator layouts are pre-computed
/// - All heavy work happens on background threads
/// - Results are cached and ready when views are created
@MainActor
final class DiffPrecomputationService {
    static let shared = DiffPrecomputationService()

    // MARK: - Types

    /// Cache key for pre-computed DiffResults
    private struct CacheKey: Hashable {
        let sessionId: String
        let index: Int
    }

    /// Pre-computed result containing DiffResult and metadata
    struct PrecomputedDiff {
        let diffResult: DiffResult
        let contentDiffResult: DiffResult  // Without file headers
        let contentHeight: CGFloat
        let lineHeight: CGFloat
    }

    // MARK: - Properties

    /// Cache of pre-computed DiffResults
    private var cache: [CacheKey: PrecomputedDiff] = [:]

    /// Track which sessions are currently being pre-computed
    private var precomputingSessionIds: Set<String> = []

    /// Maximum cache entries per session (to limit memory)
    private let maxEntriesPerSession = 100

    /// Maximum number of sessions to keep in cache (oldest evicted first)
    private let maxCachedSessions = 10

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Get a pre-computed DiffResult if available, otherwise return nil
    func getPrecomputed(sessionId: String, index: Int) -> PrecomputedDiff? {
        let key = CacheKey(sessionId: sessionId, index: index)
        return cache[key]
    }

    /// Check if a DiffResult has been pre-computed
    func isPrecomputed(sessionId: String, index: Int) -> Bool {
        let key = CacheKey(sessionId: sessionId, index: index)
        return cache[key] != nil
    }

    /// Pre-compute all DiffResults for a session's diffs in the background.
    /// This should be called when diffs first become available.
    func precomputeAll(
        sessionId: String,
        diffs: [(patch: String, language: String?, filename: String?)],
        lineHeight: CGFloat
    ) {
        // Don't re-compute if already in progress
        guard !precomputingSessionIds.contains(sessionId) else { return }

        // Check if already computed (at least first diff)
        if isPrecomputed(sessionId: sessionId, index: 0) && diffs.count > 0 {
            // Already have cache - check if count matches
            let existingCount = cache.keys.filter { $0.sessionId == sessionId }.count
            if existingCount >= diffs.count {
                return  // Already fully computed
            }
        }

        precomputingSessionIds.insert(sessionId)

        // Create copies of the data we need for background processing
        // Limit to maxEntriesPerSession to prevent unbounded memory growth
        let diffsSnapshot = Array(diffs.prefix(maxEntriesPerSession))
        let lineHeightSnapshot = lineHeight
        let startTime = CFAbsoluteTimeGetCurrent()

        // Log precomputation start
        DispatchQueue.main.async {
            ScrollDiagnostics.shared.precomputationStarted(sessionId: sessionId, diffCount: diffs.count)
        }

        // Perform heavy computation (parsing patches) on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [(index: Int, precomputed: PrecomputedDiff)] = []

            for (index, diff) in diffsSnapshot.enumerated() {
                // Parse the patch - this is the main CPU-intensive work
                let diffResult = FluxDiffer.fromPatch(
                    patch: diff.patch,
                    language: diff.language,
                    filename: diff.filename
                )

                // Filter content lines (excluding file headers)
                let contentLines = diffResult.lines.filter { $0.type != .fileHeader }
                let contentDiffResult = DiffResult(
                    lines: contentLines,
                    originalText: diffResult.originalText,
                    newText: diffResult.newText,
                    language: diffResult.language
                )

                // Calculate content height (no minimum - header/footer provide adequate spacing)
                let contentHeight = CGFloat(contentLines.count) * lineHeightSnapshot

                let precomputed = PrecomputedDiff(
                    diffResult: diffResult,
                    contentDiffResult: contentDiffResult,
                    contentHeight: contentHeight,
                    lineHeight: lineHeightSnapshot
                )

                results.append((index: index, precomputed: precomputed))
            }

            // Store results and pre-warm caches on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Evict oldest sessions if we're at the limit before adding new one
                self.evictOldSessionsIfNeeded(newSessionId: sessionId)

                for result in results {
                    let key = CacheKey(sessionId: sessionId, index: result.index)
                    self.cache[key] = result.precomputed
                }

                // Pre-warm TileHeightCalculator cache on main thread
                // This ensures the layout is ready before scrolling
                for result in results {
                    _ = TileHeightCalculator.shared.getLayout(
                        for: result.precomputed.contentDiffResult,
                        lineHeight: lineHeightSnapshot
                    )
                }

                self.precomputingSessionIds.remove(sessionId)

                // Log precomputation completion
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                ScrollDiagnostics.shared.precomputationCompleted(
                    sessionId: sessionId,
                    diffCount: results.count,
                    duration: duration
                )
            }
        }
    }

    // MARK: - Private Helpers

    /// Evict oldest sessions from cache if at limit, making room for a new session
    private func evictOldSessionsIfNeeded(newSessionId: String) {
        // Get unique session IDs currently in cache
        var cachedSessionIds = Set(cache.keys.map { $0.sessionId })

        // If new session is already in cache, no eviction needed
        if cachedSessionIds.contains(newSessionId) {
            return
        }

        // If we're at the limit, evict sessions until we have room
        // Note: This is a simple FIFO-ish eviction - we just remove the first session we find
        // A more sophisticated approach would track access times, but this is sufficient
        while cachedSessionIds.count >= maxCachedSessions {
            if let sessionToEvict = cachedSessionIds.first {
                cache = cache.filter { $0.key.sessionId != sessionToEvict }
                cachedSessionIds.remove(sessionToEvict)
            } else {
                break
            }
        }
    }

    /// Clear cache for a specific session
    func clearCache(sessionId: String) {
        cache = cache.filter { $0.key.sessionId != sessionId }
    }

    /// Clear entire cache
    func clearAllCache() {
        cache.removeAll()
        precomputingSessionIds.removeAll()
    }
}
