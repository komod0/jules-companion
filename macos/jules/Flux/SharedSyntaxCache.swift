import Foundation
import simd
import AppKit

/// A shared cache for syntax highlighting results that persists across tile recreation.
/// This prevents re-parsing syntax when LazyVStack recycles tiles during fast scrolling.
///
/// The cache is keyed by line content hash + language + appearance mode, not by UUID,
/// since UUIDs are recreated when tiles are recycled.
@MainActor
final class SharedSyntaxCache {
    static let shared = SharedSyntaxCache()

    /// Cache entry containing pre-computed syntax data
    struct CacheEntry {
        let tokens: [StyledToken]
        let colors: [SIMD4<Float>]
        let accessTime: CFAbsoluteTime
    }

    /// Cache key combining content hash, language, and appearance for stable lookups
    /// FIXED: Include isDarkMode to ensure cached colors match current appearance.
    /// Without this, switching between light/dark mode would serve wrong colors.
    struct CacheKey: Hashable {
        let contentHash: Int
        let language: String?
        let isDarkMode: Bool

        init(content: String, language: String?, isDarkMode: Bool) {
            self.contentHash = content.hashValue
            self.language = language
            self.isDarkMode = isDarkMode
        }
    }

    /// Helper to determine current dark mode state
    static var currentIsDarkMode: Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }

    /// Maximum number of entries to keep in cache
    /// Each entry contains [StyledToken] + [SIMD4<Float>] colors.
    /// For a typical 80-char line: ~2-3KB per entry. 5K entries ≈ 10-15MB.
    /// Reduced from 15K to limit memory pressure.
    private let maxEntries = 5_000

    /// The main cache storage
    private var cache: [CacheKey: CacheEntry] = [:]

    /// Access order for LRU eviction
    private var accessOrder: [CacheKey] = []

    /// Current session identifier for session-based cleanup
    private var currentSessionId: String?

    /// Estimated memory usage per entry (bytes)
    private let estimatedBytesPerEntry = 2500

    private init() {}

    /// Get cached syntax data for a line
    /// - Parameters:
    ///   - content: The line content
    ///   - language: The language for syntax highlighting
    ///   - isDarkMode: Optional explicit dark mode flag; uses current appearance if nil
    /// - Returns: Cached tokens and colors if available
    func get(content: String, language: String?, isDarkMode: Bool? = nil) -> (tokens: [StyledToken], colors: [SIMD4<Float>])? {
        let darkMode = isDarkMode ?? Self.currentIsDarkMode
        let key = CacheKey(content: content, language: language, isDarkMode: darkMode)
        guard let entry = cache[key] else { return nil }

        // Update access time for LRU
        updateAccessOrder(key)

        return (entry.tokens, entry.colors)
    }

    /// Store syntax data for a line
    /// - Parameters:
    ///   - content: The line content
    ///   - language: The language for syntax highlighting
    ///   - tokens: The parsed tokens
    ///   - colors: The pre-computed per-character colors
    ///   - isDarkMode: Optional explicit dark mode flag; uses current appearance if nil
    func set(content: String, language: String?, tokens: [StyledToken], colors: [SIMD4<Float>], isDarkMode: Bool? = nil) {
        let darkMode = isDarkMode ?? Self.currentIsDarkMode
        let key = CacheKey(content: content, language: language, isDarkMode: darkMode)

        // Evict if at capacity
        if cache.count >= maxEntries && cache[key] == nil {
            evictOldest()
        }

        cache[key] = CacheEntry(
            tokens: tokens,
            colors: colors,
            accessTime: CFAbsoluteTimeGetCurrent()
        )

        updateAccessOrder(key)
    }

    /// Batch get for multiple lines (more efficient than individual lookups)
    /// - Parameters:
    ///   - lines: Array of (content, id) tuples
    ///   - language: The language for syntax highlighting
    ///   - isDarkMode: Optional explicit dark mode flag; uses current appearance if nil
    /// - Returns: Dictionary mapping line IDs to cached data, only for cache hits
    func batchGet(lines: [(content: String, id: UUID)], language: String?, isDarkMode: Bool? = nil) -> [UUID: (tokens: [StyledToken], colors: [SIMD4<Float>])] {
        var results: [UUID: (tokens: [StyledToken], colors: [SIMD4<Float>])] = [:]
        let darkMode = isDarkMode ?? Self.currentIsDarkMode

        for (content, id) in lines {
            if let cached = get(content: content, language: language, isDarkMode: darkMode) {
                results[id] = cached
            }
        }

        return results
    }

    /// Batch set for multiple lines
    /// - Parameters:
    ///   - entries: Array of (content, id, tokens, colors) tuples
    ///   - language: The language for syntax highlighting
    ///   - isDarkMode: Optional explicit dark mode flag; uses current appearance if nil
    func batchSet(entries: [(content: String, id: UUID, tokens: [StyledToken], colors: [SIMD4<Float>])], language: String?, isDarkMode: Bool? = nil) {
        let darkMode = isDarkMode ?? Self.currentIsDarkMode
        for (content, _, tokens, colors) in entries {
            set(content: content, language: language, tokens: tokens, colors: colors, isDarkMode: darkMode)
        }
    }

    /// Clear all cached data
    func clear() {
        cache.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        currentSessionId = nil
    }

    /// Get current cache size
    var count: Int {
        cache.count
    }

    /// Estimated memory usage in bytes
    var estimatedMemoryUsage: Int {
        cache.count * estimatedBytesPerEntry
    }

    /// Estimated memory usage in megabytes
    var estimatedMemoryUsageMB: Double {
        Double(estimatedMemoryUsage) / (1024 * 1024)
    }

    /// Switch to a new session, clearing cache if session changed
    /// Call this when switching to a new document/file to prevent unbounded growth
    /// - Parameter sessionId: Unique identifier for the session (e.g., file path or document ID)
    func switchSession(_ sessionId: String) {
        if currentSessionId != sessionId {
            // New session - clear old cache to free memory
            clear()
            currentSessionId = sessionId
        }
    }

    /// Trim cache to target size (useful for memory pressure situations)
    /// - Parameter targetCount: Target number of entries to keep
    func trimTo(targetCount: Int) {
        guard cache.count > targetCount else { return }
        let removeCount = cache.count - targetCount
        let keysToEvict = accessOrder.prefix(removeCount)

        for key in keysToEvict {
            cache.removeValue(forKey: key)
        }
        accessOrder.removeFirst(min(removeCount, accessOrder.count))
    }

    /// Trim cache to target memory usage
    /// - Parameter targetMB: Target memory usage in megabytes
    func trimToMemory(targetMB: Double) {
        let targetBytes = Int(targetMB * 1024 * 1024)
        let targetCount = max(100, targetBytes / estimatedBytesPerEntry)
        trimTo(targetCount: targetCount)
    }

    // MARK: - Private Methods

    private func updateAccessOrder(_ key: CacheKey) {
        // Remove if exists (we'll add to end)
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    private func evictOldest() {
        // Evict 10% of oldest entries for efficiency
        let evictCount = max(1, maxEntries / 10)
        let keysToEvict = accessOrder.prefix(evictCount)

        for key in keysToEvict {
            cache.removeValue(forKey: key)
        }
        accessOrder.removeFirst(min(evictCount, accessOrder.count))
    }
}
