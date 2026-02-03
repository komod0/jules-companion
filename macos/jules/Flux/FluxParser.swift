import Foundation
import SwiftTreeSitter
import AppKit
import CodeEditLanguages

// --- Models ---

struct StyledToken: Equatable {
    let range: NSRange
    let scope: String
    let color: NSColor
}

// --- Parser ---

class FluxParser {
    private let parser = Parser()

    // Cache compiled queries by language name to avoid re-loading from disk
    // Key: language name, Value: (language, compiled query)
    private var queryCache: [String: Query] = [:]

    // Cache resolved CodeLanguage objects
    private var languageCache: [String: CodeLanguage] = [:]

    // Set to true to enable overlap detection and filtering
    static var filterOverlappingCaptures = true

    // Set to true to enable debug logging
    static var debugLogging = false

    // Cache for theme colors to avoid repeated NSColor allocations
    // Key: capture name category (e.g., "keyword", "string"), Value: NSColor
    // Note: Colors are cached per appearance mode and invalidated on appearance change
    private static var colorCache: [String: NSColor] = [:]
    private static var colorCacheInitialized = false
    private static var cachedAppearanceMode: Bool? = nil // true = dark, false = light
    private static var appearanceObserver: NSObjectProtocol?
    private static let colorCacheLock = NSLock() // Protects colorCache, colorCacheInitialized, cachedAppearanceMode

    init() {
        // Set up appearance change observer once
        FluxParser.setupAppearanceObserver()
    }

    /// Set up observer for appearance changes to invalidate color cache
    private static func setupAppearanceObserver() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            invalidateColorCache()
        }
    }

    // Dependency Injection: Language must be provided
    func setLanguage(_ language: Language) throws {
        try parser.setLanguage(language)
    }

    func parse(text: String, languageName: String) -> [StyledToken] {
        // Try tree-sitter first
        if let tokens = parseWithTreeSitter(text: text, languageName: languageName), !tokens.isEmpty {
            return tokens
        }

        // Fallback to regex-based highlighting
        return parseWithRegex(text: text, languageName: languageName)
    }

    /// Parse the full text content and return tokens mapped to line indices.
    /// This method parses the entire content at once for better accuracy (handles multi-line constructs).
    /// Returns: Dictionary mapping line index (0-based) to array of StyledTokens with ranges relative to that line.
    func parseFullContent(text: String, languageName: String) -> [Int: [StyledToken]] {
        let profiler = LoadingProfiler.shared
        let textSizeKB = Double(text.utf8.count) / 1024
        let shouldProfile = LoadingProfiler.memoryProfilingEnabled && textSizeKB > 5 // Only profile larger texts

        if shouldProfile {
            profiler.startMemoryTrace("FluxParser.parseFullContent(\(String(format: "%.1f", textSizeKB))KB, \(languageName))")
        }

        // Try tree-sitter first
        if let result = parseFullContentWithTreeSitter(text: text, languageName: languageName), !result.isEmpty {
            if shouldProfile {
                profiler.endMemoryTrace("FluxParser.parseFullContent(\(String(format: "%.1f", textSizeKB))KB, \(languageName))")
            }
            return result
        }

        // Fallback to per-line regex parsing
        var result: [Int: [StyledToken]] = [:]
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let tokens = parseWithRegex(text: line, languageName: languageName)
            if !tokens.isEmpty {
                result[index] = tokens
            }
        }

        if shouldProfile {
            profiler.endMemoryTrace("FluxParser.parseFullContent(\(String(format: "%.1f", textSizeKB))KB, \(languageName))")
        }
        return result
    }

    private func parseFullContentWithTreeSitter(text: String, languageName: String) -> [Int: [StyledToken]]? {
        // Calculate text size for memory logging threshold
        let textSizeKB = Double(text.utf8.count) / 1024

        // Resolve language (with caching)
        let lang: CodeLanguage
        let cacheKey = languageName.lowercased()

        if let cached = languageCache[cacheKey] {
            lang = cached
        } else {
            if let directMatch = CodeLanguage.allLanguages.first(where: { $0.id.rawValue == languageName }) {
                lang = directMatch
            } else {
                lang = CodeLanguage.from(extension: languageName)
            }
            languageCache[cacheKey] = lang
        }

        guard lang != .default, let treeSitterLanguage = lang.language else {
            return nil
        }

        // Get or create cached query
        let query: Query
        if let cached = queryCache[cacheKey] {
            query = cached
        } else {
            do {
                try parser.setLanguage(treeSitterLanguage)
            } catch {
                return nil
            }

            guard let loadedQuery = loadQuery(for: lang, treeSitterLanguage: treeSitterLanguage, languageName: languageName) else {
                return nil
            }
            queryCache[cacheKey] = loadedQuery
            query = loadedQuery
        }

        // Set parser language if needed
        do {
            try parser.setLanguage(treeSitterLanguage)
        } catch {
            return nil
        }

        let detailedMemoryLogging = LoadingProfiler.memoryProfilingEnabled && textSizeKB > 5
        if detailedMemoryLogging {
            LoadingProfiler.shared.logMemory("  [FluxParser] Before tree-sitter parse")
        }

        guard let tree = parser.parse(text) else {
            return nil
        }

        if detailedMemoryLogging {
            LoadingProfiler.shared.logMemory("  [FluxParser] After tree-sitter parse (AST created)")
        }

        let cursor = query.execute(in: tree)

        // Pre-compute line information for the full text.
        // SwiftTreeSitter returns UTF-16 byte offsets. After /2 division, we have UTF-16 code unit indices.
        // IMPORTANT: We must use UTF-16 code units consistently, NOT grapheme clusters (Swift's String.count).
        // We build lineUtf16Starts to map UTF-16 code unit positions to line numbers.

        let utf16View = text.utf16
        let totalUtf16Count = utf16View.count

        // lineUtf16Starts[i] = UTF-16 code unit index where line i starts
        var lineCharStarts: [Int] = [0]
        var utf16Index = 0

        // Iterate over UTF-16 code units to build line start array
        for codeUnit in utf16View {
            utf16Index += 1
            // Newline is U+000A, which is a single UTF-16 code unit
            if codeUnit == 0x0A {
                lineCharStarts.append(utf16Index)
            }
        }

        // Helper to find which line a UTF-16 code unit index is on
        func lineForChar(_ charIdx: Int) -> Int {
            var lo = 0
            var hi = lineCharStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineCharStarts[mid] <= charIdx {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return lo
        }

        var result: [Int: [StyledToken]] = [:]

        // Ensure color cache is initialized before processing
        FluxParser.initializeColorCache()

        // NOTE: autoreleasepool removed - it was ineffective because:
        // - Swift structs/arrays are ARC-managed, not autoreleased
        // - Only Objective-C objects benefit from autoreleasepool
        // - Memory profiling showed 0 MB released by autoreleasepool

        // OPTIMIZATION: Use lightweight struct without NSColor to reduce memory
        // Color is looked up by category at the end, avoiding ~1-2KB per capture
        struct LightCapture {
            let startByte: Int
            let endByte: Int
            let captureName: String
            let colorCategory: String
            let priority: Int
        }

        // Estimate initial capacity based on text size (roughly 1 capture per 10 chars)
        let estimatedCaptures = max(100, totalUtf16Count / 10)
        var allCaptures: [LightCapture] = []
        allCaptures.reserveCapacity(estimatedCaptures)

        for match in cursor {
            for capture in match.captures {
                let byteRange = capture.node.byteRange
                let captureName = capture.name ?? ""

                // SwiftTreeSitter returns UTF-16 byte offsets (2 bytes per BMP character)
                // Divide by 2 to get UTF-16 code unit indices
                let startByte = Int(byteRange.lowerBound) / 2
                let endByte = Int(byteRange.upperBound) / 2

                if FluxParser.debugLogging {
                    let originalStart = Int(byteRange.lowerBound)
                    let originalEnd = Int(byteRange.upperBound)
                    var extractedText = "(out of bounds)"
                    if startByte >= 0 && endByte <= totalUtf16Count {
                        let startIdx = utf16View.index(utf16View.startIndex, offsetBy: startByte)
                        let endIdx = utf16View.index(utf16View.startIndex, offsetBy: endByte)
                        extractedText = String(utf16View[startIdx..<endIdx]) ?? "(invalid UTF-16)"
                    }
                    print("[FluxParser] Capture '\(captureName)': UTF-16 offsets \(originalStart)-\(originalEnd) -> utf16 units \(startByte)-\(endByte) text='\(extractedText)'")
                }

                // Get color category (skip if no matching category)
                guard let colorCat = colorCategory(for: captureName) else { continue }

                // Calculate priority based on capture name (higher priority = should win overlaps)
                let priority: Int
                switch colorCat {
                case "comment": priority = 100
                case "string": priority = 90
                case "keyword": priority = 80
                case "function": priority = 70
                case "type": priority = 60
                case "number": priority = 50
                case "variable": priority = 40
                default: priority = 10
                }

                allCaptures.append(LightCapture(
                    startByte: startByte,
                    endByte: endByte,
                    captureName: captureName,
                    colorCategory: colorCat,
                    priority: priority
                ))
            }
        }

        if detailedMemoryLogging {
            LoadingProfiler.shared.logMemory("  [FluxParser] After collecting \(allCaptures.count) captures")
        }

        // OPTIMIZATION: Filter overlapping captures with sorted intervals for O(log n) lookup
        var filteredCaptures: [LightCapture]
        if FluxParser.filterOverlappingCaptures && !allCaptures.isEmpty {
            // Sort by priority descending, then by length descending (prefer longer matches)
            allCaptures.sort { a, b in
                if a.priority != b.priority {
                    return a.priority > b.priority
                }
                return (a.endByte - a.startByte) > (b.endByte - b.startByte)
            }

            // Track claimed ranges sorted by start position for binary search
            var claimedRanges: [(start: Int, end: Int)] = []
            claimedRanges.reserveCapacity(allCaptures.count / 2)

            filteredCaptures = []
            filteredCaptures.reserveCapacity(allCaptures.count / 2)

            for capture in allCaptures {
                // Binary search to find potential overlapping ranges
                let captureStart = capture.startByte
                let captureEnd = capture.endByte
                let captureLength = captureEnd - captureStart
                guard captureLength > 0 else { continue }

                // Check for significant overlap using binary search on sorted ranges
                var isOverlapping = false

                // Find first range that could overlap (start <= captureEnd)
                var lo = 0, hi = claimedRanges.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if claimedRanges[mid].start <= captureEnd {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }

                // Check ranges that could potentially overlap
                for i in stride(from: min(lo, claimedRanges.count) - 1, through: 0, by: -1) {
                    let claimed = claimedRanges[i]
                    if claimed.end <= captureStart {
                        break // No more overlaps possible (ranges are sorted by start)
                    }
                    let overlapStart = max(captureStart, claimed.start)
                    let overlapEnd = min(captureEnd, claimed.end)
                    if overlapStart < overlapEnd {
                        let overlapLength = overlapEnd - overlapStart
                        // Consider it overlapping if >50% of this capture is already covered
                        if overlapLength > captureLength / 2 {
                            isOverlapping = true
                            break
                        }
                    }
                }

                if !isOverlapping {
                    // Insert in sorted order by start position
                    let insertIdx = claimedRanges.firstIndex { $0.start > captureStart } ?? claimedRanges.count
                    claimedRanges.insert((captureStart, captureEnd), at: insertIdx)
                    filteredCaptures.append(capture)
                } else if FluxParser.debugLogging {
                    print("[FluxParser] Filtered overlapping capture '\(capture.captureName)' at bytes \(capture.startByte)-\(capture.endByte)")
                }
            }
            // Release claimedRanges immediately - no longer needed
            // This recovers ~(captureCount/2 * 16 bytes) before building result dict
            // Note: setting to [] releases the backing storage
        } else {
            filteredCaptures = allCaptures
        }

        // Clear allCaptures to free memory before processing results
        // Note: in else branch this triggers COW copy, in if branch it just releases
        allCaptures = []

        if detailedMemoryLogging {
            LoadingProfiler.shared.logMemory("  [FluxParser] After filtering to \(filteredCaptures.count) captures")
        }

        // Process the filtered captures - look up colors now (deferred allocation)
        for capture in filteredCaptures {
            let startChar = capture.startByte
            let endChar = capture.endByte
            let captureName = capture.captureName

            // Look up color from cache (single allocation per category, not per capture)
            guard let color = FluxParser.colorCache[capture.colorCategory] else { continue }

            // Determine which lines this token spans using UTF-16 code unit lookup
            let startLine = lineForChar(startChar)
            let endLine = lineForChar(max(startChar, endChar - 1))

            // Split token across lines if needed
            for lineIndex in startLine...endLine {
                let lineCharStart = lineCharStarts[lineIndex]
                let lineCharEnd: Int
                if lineIndex + 1 < lineCharStarts.count {
                    var endCharPos = lineCharStarts[lineIndex + 1] - 1

                    if endCharPos > lineCharStart {
                        let charBeforeNewlineIdx = utf16View.index(utf16View.startIndex, offsetBy: endCharPos - 1)
                        if utf16View[charBeforeNewlineIdx] == 0x0D {
                            endCharPos -= 1
                        }
                    }
                    lineCharEnd = endCharPos
                } else {
                    lineCharEnd = totalUtf16Count
                }

                let tokenStartInLine = max(0, startChar - lineCharStart)
                let tokenEndInLine = min(lineCharEnd - lineCharStart, endChar - lineCharStart)

                if tokenEndInLine > tokenStartInLine {
                    let lineRange = NSRange(location: tokenStartInLine, length: tokenEndInLine - tokenStartInLine)
                    let token = StyledToken(range: lineRange, scope: captureName, color: color)
                    result[lineIndex, default: []].append(token)
                }
            }
        }

        if detailedMemoryLogging {
            let totalTokens = result.values.reduce(0) { $0 + $1.count }
            LoadingProfiler.shared.logMemory("  [FluxParser] After building result dict (\(result.count) lines, \(totalTokens) tokens)")
        }

        // Explicitly release tree-sitter objects to help ARC
        // (tree and cursor go out of scope here, triggering dealloc)

        return result
    }

    private func parseWithTreeSitter(text: String, languageName: String) -> [StyledToken]? {
        // Resolve language (with caching)
        let lang: CodeLanguage
        let cacheKey = languageName.lowercased()

        if let cached = languageCache[cacheKey] {
            lang = cached
        } else {
            if let directMatch = CodeLanguage.allLanguages.first(where: { $0.id.rawValue == languageName }) {
                lang = directMatch
            } else {
                lang = CodeLanguage.from(extension: languageName)
            }
            languageCache[cacheKey] = lang
        }

        guard lang != .default, let treeSitterLanguage = lang.language else {
            return nil
        }

        // Set parser language
        do {
            try parser.setLanguage(treeSitterLanguage)
        } catch {
            return nil
        }

        // Get or create cached query
        let query: Query
        if let cached = queryCache[cacheKey] {
            query = cached
        } else {
            guard let loadedQuery = loadQuery(for: lang, treeSitterLanguage: treeSitterLanguage, languageName: languageName) else {
                return nil
            }

            queryCache[cacheKey] = loadedQuery
            query = loadedQuery
        }

        guard let tree = parser.parse(text) else {
            return nil
        }

        let cursor = query.execute(in: tree)

        var tokens = [StyledToken]()

        // SwiftTreeSitter returns UTF-16 byte offsets. After /2 division, we have UTF-16 code unit indices.
        // IMPORTANT: Use UTF-16 code unit count, NOT grapheme cluster count (Swift's String.count)
        let utf16View = text.utf16
        let totalUtf16Count = utf16View.count

        // Ensure color cache is initialized before processing
        FluxParser.initializeColorCache()

        // NOTE: autoreleasepool removed - ineffective for Swift structs/arrays (ARC-managed)

        // OPTIMIZATION: Use lightweight struct without NSColor
        struct LightCapture {
            let startByte: Int
            let endByte: Int
            let captureName: String
            let colorCategory: String
            let priority: Int
        }

        let estimatedCaptures = max(50, totalUtf16Count / 10)
        var allCaptures: [LightCapture] = []
        allCaptures.reserveCapacity(estimatedCaptures)

        for match in cursor {
            for capture in match.captures {
                let byteRange = capture.node.byteRange
                let captureName = capture.name ?? ""

                let startByte = Int(byteRange.lowerBound) / 2
                let endByte = Int(byteRange.upperBound) / 2

                if FluxParser.debugLogging {
                    let originalStart = Int(byteRange.lowerBound)
                    let originalEnd = Int(byteRange.upperBound)
                    var extractedText = "(out of bounds)"
                    if startByte >= 0 && endByte <= totalUtf16Count {
                        let startIdx = utf16View.index(utf16View.startIndex, offsetBy: startByte)
                        let endIdx = utf16View.index(utf16View.startIndex, offsetBy: endByte)
                        extractedText = String(utf16View[startIdx..<endIdx]) ?? "(invalid UTF-16)"
                    }
                    print("[FluxParser] Capture '\(captureName)': UTF-16 offsets \(originalStart)-\(originalEnd) -> utf16 units \(startByte)-\(endByte) text='\(extractedText)'")
                }

                guard let colorCat = colorCategory(for: captureName) else { continue }

                let priority: Int
                switch colorCat {
                case "comment": priority = 100
                case "string": priority = 90
                case "keyword": priority = 80
                case "function": priority = 70
                case "type": priority = 60
                case "number": priority = 50
                case "variable": priority = 40
                default: priority = 10
                }

                allCaptures.append(LightCapture(
                    startByte: startByte,
                    endByte: endByte,
                    captureName: captureName,
                    colorCategory: colorCat,
                    priority: priority
                ))
            }
        }

        // Filter overlapping captures with sorted intervals
        var filteredCaptures: [LightCapture]
        if FluxParser.filterOverlappingCaptures && !allCaptures.isEmpty {
            allCaptures.sort { a, b in
                if a.priority != b.priority {
                    return a.priority > b.priority
                }
                return (a.endByte - a.startByte) > (b.endByte - b.startByte)
            }

            var claimedRanges: [(start: Int, end: Int)] = []
            claimedRanges.reserveCapacity(allCaptures.count / 2)
            filteredCaptures = []
            filteredCaptures.reserveCapacity(allCaptures.count / 2)

            for capture in allCaptures {
                let captureStart = capture.startByte
                let captureEnd = capture.endByte
                let captureLength = captureEnd - captureStart
                guard captureLength > 0 else { continue }

                var isOverlapping = false
                for claimed in claimedRanges {
                    if claimed.end <= captureStart { continue }
                    if claimed.start >= captureEnd { break }
                    let overlapStart = max(captureStart, claimed.start)
                    let overlapEnd = min(captureEnd, claimed.end)
                    if overlapStart < overlapEnd && (overlapEnd - overlapStart) > captureLength / 2 {
                        isOverlapping = true
                        break
                    }
                }

                if !isOverlapping {
                    let insertIdx = claimedRanges.firstIndex { $0.start > captureStart } ?? claimedRanges.count
                    claimedRanges.insert((captureStart, captureEnd), at: insertIdx)
                    filteredCaptures.append(capture)
                }
            }
        } else {
            filteredCaptures = allCaptures
        }

        allCaptures = [] // Free memory

        for capture in filteredCaptures {
            let startChar = capture.startByte
            let endChar = capture.endByte
            guard let color = FluxParser.colorCache[capture.colorCategory] else { continue }
            let nsRange = NSRange(location: startChar, length: max(0, endChar - startChar))
            tokens.append(StyledToken(range: nsRange, scope: capture.captureName, color: color))
        }

        return tokens
    }

    private func parseWithRegex(text: String, languageName: String) -> [StyledToken] {
        var tokens = [StyledToken]()

        // Keywords by language - comprehensive support for all CodeEditLanguages
        let keywords: [String]
        switch languageName.lowercased() {
        case "swift":
            keywords = ["class", "struct", "enum", "protocol", "extension", "func", "init", "deinit",
                       "var", "let", "static", "private", "public", "internal", "fileprivate", "open",
                       "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
                       "in", "return", "break", "continue", "import", "typealias", "self", "Self",
                       "super", "nil", "true", "false", "try", "catch", "throw", "throws", "async",
                       "await", "override", "final", "mutating", "nonmutating", "lazy", "weak", "unowned",
                       "@State", "@Binding", "@Published", "@ObservedObject", "@StateObject", "@Environment"]
        case "python", "py":
            keywords = ["def", "class", "lambda", "if", "elif", "else", "for", "while", "break",
                       "continue", "return", "yield", "import", "from", "as", "try", "except",
                       "finally", "raise", "with", "async", "await", "pass", "assert", "and", "or",
                       "not", "in", "is", "None", "True", "False", "self", "global", "nonlocal"]
        case "c":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "goto", "struct", "union", "enum", "typedef", "const",
                       "static", "extern", "inline", "void", "int", "char", "float", "double",
                       "long", "short", "signed", "unsigned", "sizeof", "NULL"]
        case "cpp", "c++", "hpp":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "goto", "struct", "union", "enum", "typedef", "const",
                       "static", "extern", "inline", "void", "int", "char", "float", "double",
                       "long", "short", "signed", "unsigned", "sizeof", "class", "public", "private",
                       "protected", "virtual", "override", "template", "typename", "namespace", "using",
                       "new", "delete", "nullptr", "true", "false", "this", "auto", "constexpr",
                       "noexcept", "explicit", "mutable", "volatile", "friend", "operator"]
        case "csharp", "cs":
            keywords = ["if", "else", "switch", "case", "default", "for", "foreach", "while", "do",
                       "break", "continue", "return", "class", "struct", "interface", "enum", "namespace",
                       "using", "public", "private", "protected", "internal", "static", "readonly", "const",
                       "new", "this", "base", "virtual", "override", "abstract", "sealed", "async", "await",
                       "try", "catch", "finally", "throw", "true", "false", "null", "void", "var", "get", "set"]
        case "javascript", "js", "cjs", "mjs":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "function", "var", "let", "const", "class", "extends",
                       "import", "export", "from", "async", "await", "try", "catch", "finally", "throw",
                       "new", "this", "super", "typeof", "instanceof", "true", "false", "null", "undefined"]
        case "typescript", "ts", "cts", "mts":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "function", "var", "let", "const", "class", "extends",
                       "implements", "interface", "type", "enum", "namespace", "module", "declare",
                       "import", "export", "from", "async", "await", "try", "catch", "finally", "throw",
                       "new", "this", "super", "typeof", "instanceof", "true", "false", "null", "undefined",
                       "public", "private", "protected", "readonly", "static", "abstract", "as", "is"]
        case "jsx":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "function", "var", "let", "const", "class", "extends",
                       "import", "export", "from", "async", "await", "try", "catch", "finally", "throw",
                       "new", "this", "super", "typeof", "instanceof", "true", "false", "null", "undefined"]
        case "tsx":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "function", "var", "let", "const", "class", "extends",
                       "implements", "interface", "type", "enum", "import", "export", "from",
                       "async", "await", "try", "catch", "finally", "throw", "new", "this", "super",
                       "typeof", "instanceof", "true", "false", "null", "undefined", "as"]
        case "java", "jav":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "class", "interface", "extends", "implements", "package",
                       "import", "public", "private", "protected", "static", "final", "abstract",
                       "synchronized", "volatile", "transient", "native", "new", "this", "super",
                       "instanceof", "try", "catch", "finally", "throw", "throws", "true", "false", "null",
                       "void", "int", "long", "float", "double", "boolean", "char", "byte", "short"]
        case "kotlin", "kt", "kts":
            keywords = ["if", "else", "when", "for", "while", "do", "break", "continue", "return",
                       "fun", "val", "var", "class", "object", "interface", "enum", "sealed", "data",
                       "package", "import", "public", "private", "protected", "internal", "open",
                       "final", "abstract", "override", "companion", "init", "constructor", "this",
                       "super", "is", "as", "in", "out", "try", "catch", "finally", "throw",
                       "true", "false", "null", "suspend", "inline", "crossinline", "noinline", "reified"]
        case "go":
            keywords = ["if", "else", "switch", "case", "default", "for", "range", "break", "continue",
                       "return", "func", "var", "const", "type", "struct", "interface", "map", "chan",
                       "package", "import", "go", "defer", "select", "fallthrough", "goto",
                       "true", "false", "nil", "iota", "make", "new", "len", "cap", "append", "copy", "delete"]
        case "rust", "rs":
            keywords = ["if", "else", "match", "loop", "while", "for", "in", "break", "continue",
                       "return", "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
                       "impl", "type", "mod", "use", "pub", "crate", "super", "self", "Self",
                       "where", "async", "await", "move", "dyn", "ref", "unsafe", "extern",
                       "true", "false", "Some", "None", "Ok", "Err"]
        case "ruby", "rb":
            keywords = ["if", "elsif", "else", "unless", "case", "when", "while", "until", "for",
                       "break", "next", "redo", "retry", "return", "def", "class", "module", "end",
                       "do", "begin", "rescue", "ensure", "raise", "yield", "self", "super",
                       "true", "false", "nil", "and", "or", "not", "in", "then", "require", "require_relative",
                       "attr_reader", "attr_writer", "attr_accessor", "private", "protected", "public"]
        case "php":
            keywords = ["if", "elseif", "else", "switch", "case", "default", "for", "foreach", "while",
                       "do", "break", "continue", "return", "function", "class", "interface", "trait",
                       "extends", "implements", "namespace", "use", "public", "private", "protected",
                       "static", "final", "abstract", "const", "new", "clone", "instanceof",
                       "try", "catch", "finally", "throw", "true", "false", "null", "echo", "print",
                       "require", "require_once", "include", "include_once", "global", "array"]
        case "scala", "sc":
            keywords = ["if", "else", "match", "case", "for", "while", "do", "return", "def", "val",
                       "var", "class", "object", "trait", "extends", "with", "package", "import",
                       "private", "protected", "public", "final", "sealed", "abstract", "override",
                       "implicit", "lazy", "new", "this", "super", "type", "try", "catch", "finally",
                       "throw", "true", "false", "null", "yield", "forSome"]
        case "haskell", "hs":
            keywords = ["if", "then", "else", "case", "of", "let", "in", "where", "do", "module",
                       "import", "qualified", "as", "hiding", "data", "type", "newtype", "class",
                       "instance", "deriving", "default", "infix", "infixl", "infixr", "True", "False"]
        case "elixir", "ex", "exs":
            keywords = ["if", "else", "unless", "case", "cond", "when", "for", "with", "do", "end",
                       "def", "defp", "defmodule", "defmacro", "defstruct", "defprotocol", "defimpl",
                       "import", "require", "use", "alias", "fn", "raise", "rescue", "try", "catch",
                       "after", "true", "false", "nil", "and", "or", "not", "in", "receive", "send"]
        case "lua":
            keywords = ["if", "then", "else", "elseif", "end", "for", "while", "do", "repeat", "until",
                       "break", "return", "function", "local", "and", "or", "not", "in",
                       "true", "false", "nil", "require", "module", "self"]
        case "perl", "pl", "pm":
            keywords = ["if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do",
                       "last", "next", "redo", "return", "sub", "my", "our", "local", "use", "require",
                       "package", "BEGIN", "END", "and", "or", "not", "eq", "ne", "lt", "gt", "le", "ge"]
        case "bash", "sh", "zsh":
            keywords = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until",
                       "do", "done", "in", "function", "return", "exit", "break", "continue",
                       "local", "export", "readonly", "declare", "typeset", "unset", "shift",
                       "true", "false", "source", "alias", "echo", "printf", "read", "test"]
        case "sql":
            keywords = ["SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
                       "IS", "NULL", "AS", "ORDER", "BY", "ASC", "DESC", "LIMIT", "OFFSET",
                       "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
                       "ALTER", "DROP", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
                       "ON", "GROUP", "HAVING", "UNION", "ALL", "DISTINCT", "COUNT", "SUM", "AVG",
                       "MAX", "MIN", "CASE", "WHEN", "THEN", "ELSE", "END", "TRUE", "FALSE",
                       "select", "from", "where", "and", "or", "not", "in", "like", "between",
                       "is", "null", "as", "order", "by", "asc", "desc", "limit", "offset",
                       "insert", "into", "values", "update", "set", "delete", "create", "table",
                       "alter", "drop", "index", "view", "join", "left", "right", "inner", "outer",
                       "on", "group", "having", "union", "all", "distinct", "case", "when", "then", "else", "end"]
        case "dart":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "class", "extends", "implements", "with", "mixin",
                       "abstract", "factory", "const", "final", "var", "dynamic", "void", "async",
                       "await", "yield", "sync", "try", "catch", "finally", "throw", "rethrow",
                       "import", "export", "library", "part", "show", "hide", "as", "deferred",
                       "true", "false", "null", "this", "super", "new", "static", "external",
                       "get", "set", "operator", "typedef", "enum", "covariant", "late", "required"]
        case "julia", "jl":
            keywords = ["if", "elseif", "else", "end", "for", "while", "break", "continue", "return",
                       "function", "macro", "module", "struct", "mutable", "abstract", "primitive",
                       "type", "const", "local", "global", "let", "begin", "quote", "do",
                       "try", "catch", "finally", "throw", "import", "using", "export",
                       "true", "false", "nothing", "missing", "in", "isa", "where"]
        case "ocaml", "ml":
            keywords = ["if", "then", "else", "match", "with", "function", "fun", "let", "in",
                       "rec", "and", "or", "not", "mod", "type", "of", "module", "struct", "sig",
                       "end", "open", "include", "val", "external", "exception", "raise", "try",
                       "when", "as", "true", "false", "begin", "do", "done", "for", "while", "to", "downto"]
        case "dockerfile":
            keywords = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                       "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                       "HEALTHCHECK", "SHELL", "AS"]
        case "yaml", "yml":
            keywords = ["true", "false", "null", "yes", "no", "on", "off"]
        case "toml":
            keywords = ["true", "false"]
        case "json":
            keywords = ["true", "false", "null"]
        case "zig":
            keywords = ["if", "else", "switch", "while", "for", "break", "continue", "return",
                       "fn", "const", "var", "pub", "extern", "export", "inline", "noinline",
                       "struct", "enum", "union", "error", "unreachable", "undefined", "null",
                       "try", "catch", "orelse", "and", "or", "comptime", "test", "defer", "errdefer",
                       "async", "await", "suspend", "resume", "nosuspend", "anyframe", "true", "false"]
        case "verilog", "v":
            keywords = ["module", "endmodule", "input", "output", "inout", "wire", "reg", "integer",
                       "parameter", "localparam", "assign", "always", "initial", "begin", "end",
                       "if", "else", "case", "endcase", "for", "while", "forever", "repeat",
                       "posedge", "negedge", "and", "or", "not", "nand", "nor", "xor", "xnor",
                       "function", "endfunction", "task", "endtask", "generate", "endgenerate"]
        case "agda":
            keywords = ["module", "import", "open", "data", "record", "field", "constructor",
                       "where", "with", "let", "in", "if", "then", "else", "case", "of",
                       "do", "return", "instance", "postulate", "primitive", "abstract", "private",
                       "public", "mutual", "infix", "infixl", "infixr", "syntax", "pattern",
                       "rewrite", "forall", "Set", "Prop", "Level"]
        case "objc", "m":
            keywords = ["if", "else", "switch", "case", "default", "for", "while", "do", "break",
                       "continue", "return", "goto", "struct", "union", "enum", "typedef", "const",
                       "static", "extern", "inline", "void", "int", "char", "float", "double",
                       "long", "short", "signed", "unsigned", "sizeof", "self", "super", "nil",
                       "NULL", "YES", "NO", "true", "false", "@interface", "@implementation",
                       "@end", "@property", "@synthesize", "@dynamic", "@class", "@protocol",
                       "@optional", "@required", "@public", "@private", "@protected", "@try",
                       "@catch", "@finally", "@throw", "@selector", "@encode", "@autoreleasepool"]
        default:
            keywords = ["if", "else", "for", "while", "return", "function", "var", "let", "const",
                       "class", "import", "export", "true", "false", "null", "undefined"]
        }

        // Match keywords
        if let keywordColor = themeColor(for: "keyword") {
            for keyword in keywords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(text.startIndex..., in: text)
                    for match in regex.matches(in: text, options: [], range: range) {
                        tokens.append(StyledToken(
                            range: match.range,
                            scope: "keyword",
                            color: keywordColor
                        ))
                    }
                }
            }
        }

        // Match strings (single and double quoted)
        if let stringColor = themeColor(for: "string"),
           let stringRegex = try? NSRegularExpression(pattern: "\"[^\"\\\\]*(\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(\\\\.[^'\\\\]*)*'", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            for match in stringRegex.matches(in: text, options: [], range: range) {
                tokens.append(StyledToken(
                    range: match.range,
                    scope: "string",
                    color: stringColor
                ))
            }
        }

        // Match comments (// style and # style)
        if let commentColor = themeColor(for: "comment") {
            let commentPatterns = ["//.*$", "#.*$"]
            for pattern in commentPatterns {
                if let commentRegex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) {
                    let range = NSRange(text.startIndex..., in: text)
                    for match in commentRegex.matches(in: text, options: [], range: range) {
                        tokens.append(StyledToken(
                            range: match.range,
                            scope: "comment",
                            color: commentColor
                        ))
                    }
                }
            }
        }

        // Match numbers
        if let numberColor = themeColor(for: "number"),
           let numberRegex = try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            for match in numberRegex.matches(in: text, options: [], range: range) {
                tokens.append(StyledToken(
                    range: match.range,
                    scope: "number",
                    color: numberColor
                ))
            }
        }
        // Match function calls (identifier followed by opening parenthesis)
        if let functionColor = themeColor(for: "function"),
           let functionRegex = try? NSRegularExpression(pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            for match in functionRegex.matches(in: text, options: [], range: range) {
                // Only highlight the function name (capture group 1), not the parenthesis
                let funcNameRange = match.range(at: 1)
                if funcNameRange.location != NSNotFound {
                    tokens.append(StyledToken(
                        range: funcNameRange,
                        scope: "function",
                        color: functionColor
                    ))
                }
            }
        }
        return tokens
    }

    private func loadQuery(for lang: CodeLanguage, treeSitterLanguage: Language, languageName: String) -> Query? {
        // Try to load query from CodeEditLanguages bundle first
        if let queryURL = lang.queryURL,
           let queryData = try? Data(contentsOf: queryURL) {
            if let query = try? Query(language: treeSitterLanguage, data: queryData) {
                return query
            }
        }

        // Fall back to hardcoded queries if bundle loading fails
        return getQuery(for: treeSitterLanguage, name: languageName)
    }

    private func getQuery(for language: Language, name: String) -> Query? {
        // Enhanced queries with more comprehensive patterns
        let swiftQuery = """
        (comment) @comment
        (multiline_comment) @comment
        
        (class_declaration name: (type_identifier) @type)
        (struct_declaration name: (type_identifier) @type)
        (protocol_declaration name: (type_identifier) @type)
        (enum_declaration name: (type_identifier) @type)
        (type_identifier) @type
        
        (function_declaration name: (simple_identifier) @function)
        (call_expression (simple_identifier) @function)
        
        (property_declaration (pattern (simple_identifier) @variable))
        (parameter name: (simple_identifier) @variable)
        
        (string_literal) @string
        (integer_literal) @number
        (float_literal) @number
        (boolean_literal) @boolean
        
        [
          "class" "struct" "enum" "protocol" "extension"
          "func" "init" "deinit"
          "var" "let" "static" "private" "public" "internal" "fileprivate"
          "if" "else" "guard" "switch" "case" "default"
          "for" "while" "repeat" "in"
          "return" "break" "continue"
          "import" "typealias"
          "self" "Self" "super"
        ] @keyword
        """

        let pythonQuery = """
        (comment) @comment

        (class_definition name: (identifier) @type)
        (function_definition name: (identifier) @function)
        (call (identifier) @function)

        (string) @string
        (integer) @number
        (float) @number
        (true) @boolean
        (false) @boolean
        (none) @boolean

        [
          "def" "class" "lambda"
          "if" "elif" "else"
          "for" "while" "break" "continue"
          "return" "yield"
          "import" "from" "as"
          "try" "except" "finally" "raise"
          "with" "async" "await"
          "pass" "assert"
          "and" "or" "not" "in" "is"
        ] @keyword
        """

        let cQuery = """
        (comment) @comment
        
        (function_definition 
          declarator: (function_declarator 
            declarator: (identifier) @function))
        (call_expression 
          function: (identifier) @function)
        
        (type_identifier) @type
        (primitive_type) @type
        
        (identifier) @variable
        
        (string_literal) @string
        (char_literal) @string
        (number_literal) @number
        (true) @boolean
        (false) @boolean
        
        [
          "if" "else" "switch" "case" "default"
          "for" "while" "do" "break" "continue"
          "return" "goto"
          "struct" "union" "enum" "typedef"
          "const" "static" "extern" "inline"
          "void" "int" "char" "float" "double" "long" "short"
          "signed" "unsigned"
          "sizeof"
        ] @keyword
        """

        // JavaScript/TypeScript query
        let jsQuery = """
        (comment) @comment

        (class_declaration name: (identifier) @type)
        (function_declaration name: (identifier) @function)
        (method_definition name: (property_identifier) @function)
        (call_expression function: (identifier) @function)
        (arrow_function) @function

        (string) @string
        (template_string) @string
        (number) @number
        (true) @boolean
        (false) @boolean
        (null) @boolean

        [
          "if" "else" "switch" "case" "default"
          "for" "while" "do" "break" "continue"
          "return" "function" "async" "await"
          "try" "catch" "finally" "throw"
          "const" "let" "var" "class" "extends"
          "import" "export" "from" "new" "this"
        ] @keyword
        """

        // Go query
        let goQuery = """
        (comment) @comment

        (type_identifier) @type
        (function_declaration name: (identifier) @function)
        (method_declaration name: (field_identifier) @function)
        (call_expression function: (identifier) @function)

        (raw_string_literal) @string
        (interpreted_string_literal) @string
        (int_literal) @number
        (float_literal) @number
        (true) @boolean
        (false) @boolean
        (nil) @boolean

        [
          "if" "else" "switch" "case" "default"
          "for" "range" "break" "continue"
          "return" "func" "go" "defer" "select"
          "var" "const" "type" "struct" "interface"
          "package" "import" "map" "chan"
        ] @keyword
        """

        // Rust query
        let rustQuery = """
        (line_comment) @comment
        (block_comment) @comment

        (type_identifier) @type
        (function_item name: (identifier) @function)
        (call_expression function: (identifier) @function)

        (string_literal) @string
        (char_literal) @string
        (integer_literal) @number
        (float_literal) @number
        (boolean_literal) @boolean

        [
          "if" "else" "match" "loop" "while" "for" "in"
          "break" "continue" "return"
          "fn" "let" "mut" "const" "static"
          "struct" "enum" "trait" "impl" "type"
          "mod" "use" "pub" "crate" "super" "self"
          "async" "await" "move" "ref" "unsafe"
        ] @keyword
        """

        // Java query
        let javaQuery = """
        (line_comment) @comment
        (block_comment) @comment

        (type_identifier) @type
        (class_declaration name: (identifier) @type)
        (interface_declaration name: (identifier) @type)
        (method_declaration name: (identifier) @function)
        (method_invocation name: (identifier) @function)

        (string_literal) @string
        (character_literal) @string
        (decimal_integer_literal) @number
        (decimal_floating_point_literal) @number
        (true) @boolean
        (false) @boolean
        (null_literal) @boolean

        [
          "if" "else" "switch" "case" "default"
          "for" "while" "do" "break" "continue"
          "return" "try" "catch" "finally" "throw" "throws"
          "class" "interface" "extends" "implements"
          "public" "private" "protected" "static" "final"
          "abstract" "synchronized" "volatile" "native"
          "new" "this" "super" "instanceof"
          "package" "import" "void"
        ] @keyword
        """

        // Ruby query
        let rubyQuery = """
        (comment) @comment

        (class name: (constant) @type)
        (module name: (constant) @type)
        (method name: (identifier) @function)
        (call method: (identifier) @function)

        (string) @string
        (symbol) @string
        (integer) @number
        (float) @number
        (true) @boolean
        (false) @boolean
        (nil) @boolean

        [
          "if" "elsif" "else" "unless"
          "case" "when" "while" "until" "for"
          "break" "next" "redo" "retry" "return"
          "def" "class" "module" "end"
          "do" "begin" "rescue" "ensure" "raise"
          "yield" "self" "super"
          "and" "or" "not" "in" "then"
        ] @keyword
        """

        // Bash/Shell query
        let bashQuery = """
        (comment) @comment

        (function_definition name: (word) @function)
        (command_name) @function

        (variable_name) @variable

        (string) @string
        (raw_string) @string
        (number) @number

        [
          "if" "then" "else" "elif" "fi"
          "case" "esac" "for" "while" "until"
          "do" "done" "in" "function"
          "return" "exit" "break" "continue"
          "local" "export" "readonly" "declare"
        ] @keyword
        """

        var queryStr = ""
        // Simple mapping based on the language name passed in.
        switch name.lowercased() {
        case "swift": queryStr = swiftQuery
        case "python", "py": queryStr = pythonQuery
        case "c", "cpp", "c++", "h", "hpp", "objc", "m": queryStr = cQuery
        case "javascript", "js", "cjs", "mjs", "jsx", "typescript", "ts", "cts", "mts", "tsx":
            queryStr = jsQuery
        case "go", "gomod": queryStr = goQuery
        case "rust", "rs": queryStr = rustQuery
        case "java", "jav", "kotlin", "kt", "kts", "scala", "sc": queryStr = javaQuery
        case "ruby", "rb": queryStr = rubyQuery
        case "bash", "sh", "zsh": queryStr = bashQuery
        default:
            // For unsupported languages, try a generic query that works with common node types
            queryStr = """
            (comment) @comment
            (line_comment) @comment
            (block_comment) @comment
            (string) @string
            (string_literal) @string
            (number) @number
            (integer) @number
            (float) @number
            (true) @boolean
            (false) @boolean
            """
        }

        if !queryStr.isEmpty, let data = queryStr.data(using: .utf8) {
            do {
                return try Query(language: language, data: data)
            } catch {
                // Query compilation failed - return nil to skip highlighting
                return nil
            }
        }
        return nil
    }

    /// Returns the color category key for a capture name (for caching)
    private func colorCategory(for name: String) -> String? {
        if name.contains("keyword") { return "keyword" }
        if name.contains("string") { return "string" }
        if name.contains("comment") { return "comment" }
        if name.contains("function") { return "function" }
        if name.contains("type") { return "type" }
        if name.contains("variable") { return "variable" }
        if name.contains("number") || name.contains("boolean") { return "number" }
        if name.contains("operator") { return "operator" }
        if name.contains("tag") { return "tag" }
        if name.contains("regexp") { return "regexp" }
        if name.contains("markup") || name.contains("special") { return "special" }
        return nil
    }

    /// Initialize the color cache with all theme colors (called once per appearance mode)
    private static func initializeColorCache() {
        // Quick check without lock - if already initialized, skip
        // This is safe because we only transition from false->true, never back
        // (invalidateColorCache sets it false but that's rare and handled below)
        colorCacheLock.lock()
        defer { colorCacheLock.unlock() }

        // Check if appearance changed since last initialization
        // IMPORTANT: NSApp.effectiveAppearance must be accessed on the main thread
        let currentIsDark: Bool
        if Thread.isMainThread {
            currentIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        } else {
            // Use cached value if available
            if let cached = cachedAppearanceMode, colorCacheInitialized {
                // Cache is already initialized with correct appearance, no need to check again
                return
            }
            // Need to get appearance from main thread - unlock first to avoid deadlock
            colorCacheLock.unlock()
            var isDark = false
            DispatchQueue.main.sync {
                isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            }
            colorCacheLock.lock()
            // Re-check after reacquiring lock - another thread may have initialized
            if colorCacheInitialized, let cached = cachedAppearanceMode, cached == isDark {
                return
            }
            currentIsDark = isDark
        }

        if colorCacheInitialized && cachedAppearanceMode == currentIsDark {
            return
        }

        // Reinitialize with fresh colors for current appearance
        colorCache["keyword"] = AppColors.syntaxKeyword
        colorCache["string"] = AppColors.syntaxString
        colorCache["comment"] = AppColors.syntaxComment
        colorCache["function"] = AppColors.syntaxFunction
        colorCache["type"] = AppColors.syntaxType
        colorCache["variable"] = AppColors.syntaxVariable
        colorCache["number"] = AppColors.syntaxNumber
        colorCache["operator"] = AppColors.syntaxOperator
        colorCache["tag"] = AppColors.syntaxTag
        colorCache["regexp"] = AppColors.syntaxRegexp
        colorCache["special"] = AppColors.syntaxSpecial
        colorCacheInitialized = true
        cachedAppearanceMode = currentIsDark
    }

    /// Invalidate the color cache (call when appearance changes)
    static func invalidateColorCache() {
        colorCacheLock.lock()
        defer { colorCacheLock.unlock() }
        colorCache.removeAll()
        colorCacheInitialized = false
    }

    private func themeColor(for name: String) -> NSColor? {
        // Initialize cache if needed
        FluxParser.initializeColorCache()

        // Get the category for this capture name
        guard let category = colorCategory(for: name) else { return nil }

        // Return cached color (avoids creating new NSColor instances)
        FluxParser.colorCacheLock.lock()
        defer { FluxParser.colorCacheLock.unlock() }
        return FluxParser.colorCache[category]
    }
}
