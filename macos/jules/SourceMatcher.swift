import Foundation
import NaturalLanguage

/// Result of source matching from voice input
struct SourceMatchResult {
    /// The matched source, if found
    let matchedSource: Source?
    /// The cleaned prompt text with repository reference removed
    let cleanedPrompt: String
    /// The original prompt text
    let originalPrompt: String
    /// The extracted repository mention, if any
    let extractedRepoMention: String?
    /// Confidence score of the match (0.0 - 1.0)
    let confidence: Double
}

/// Matches spoken repository references to available sources using NaturalLanguage embeddings
@MainActor
final class SourceMatcher {

    // MARK: - Singleton

    static let shared = SourceMatcher()

    // MARK: - Private Properties

    /// Keywords that indicate a repository reference (used for keyword-last patterns)
    private let repositoryKeywords = [
        "repository", "repo", "project", "codebase"
    ]

    /// Phrases that typically precede repository names (keyword-first patterns)
    /// e.g., "for the repository myrepo" -> matches "myrepo"
    private let precedingPhrases = [
        "for the repository",
        "for repository",
        "for the repo",
        "for repo",
        "in the repository",
        "in repository",
        "in the repo",
        "in repo",
        "on the repository",
        "on repository",
        "on the repo",
        "on repo",
        "the repository",
        "repository",
        "the repo",
        "repo",
        "for project",
        "for the project",
        "in project",
        "in the project"
    ]

    /// Phrases where the repository name comes BEFORE the keyword (keyword-last patterns)
    /// e.g., "the i2c repository" -> matches "i2c"
    /// e.g., "use the node-i2c repo" -> matches "node-i2c"
    private let followingPhrases = [
        "repository",
        "repo",
        "project"
    ]

    /// Sentence/phrase embedding for semantic similarity (lazy loaded)
    /// This is a large in-memory data structure, so we load it only when needed
    private var _embedding: NLEmbedding?
    private var embeddingLoaded = false

    /// Lazy accessor for the embedding - loads on first access
    private var embedding: NLEmbedding? {
        if !embeddingLoaded {
            _embedding = NLEmbedding.wordEmbedding(for: .english)
            embeddingLoaded = true
        }
        return _embedding
    }

    // MARK: - Initialization

    private init() {
        // Embedding is now lazy loaded on first use to avoid memory overhead at startup
    }

    // MARK: - Memory Management

    /// Release the NLEmbedding from memory when voice input is not in use
    /// Call this when the voice input panel is closed to free up memory
    func releaseEmbedding() {
        _embedding = nil
        embeddingLoaded = false
    }

    /// Check if the embedding is currently loaded
    var isEmbeddingLoaded: Bool {
        return embeddingLoaded && _embedding != nil
    }

    // MARK: - Public Methods

    /// Attempt to match a repository from the transcribed text
    /// - Parameters:
    ///   - text: The transcribed text from voice input
    ///   - availableSources: List of available sources to match against
    /// - Returns: A SourceMatchResult containing the match (if any) and cleaned prompt
    func matchSource(from text: String, availableSources: [Source]) -> SourceMatchResult {
        let lowercaseText = text.lowercased()

        // Try to extract repository mention
        guard let extraction = extractRepositoryMention(from: lowercaseText, originalText: text) else {
            // No repository mention found
            return SourceMatchResult(
                matchedSource: nil,
                cleanedPrompt: text,
                originalPrompt: text,
                extractedRepoMention: nil,
                confidence: 0.0
            )
        }

        // Find best matching source
        let matchResult = findBestMatch(
            repoName: extraction.repoName,
            sources: availableSources
        )

        // Clean the prompt by removing the repository reference
        let cleanedPrompt = cleanPrompt(
            originalText: text,
            matchRange: extraction.fullMatchRange
        )

        return SourceMatchResult(
            matchedSource: matchResult.source,
            cleanedPrompt: cleanedPrompt,
            originalPrompt: text,
            extractedRepoMention: extraction.repoName,
            confidence: matchResult.confidence
        )
    }

    /// Get normalized source names for display
    func normalizeSourceName(_ source: Source) -> String {
        // Extract the repository name from the full source name
        // e.g., "projects/123/locations/us/sources/my-repo" -> "my-repo"
        if let lastComponent = source.name.split(separator: "/").last {
            return String(lastComponent)
        }
        return source.name
    }

    // MARK: - Private Methods

    /// Extract repository mention from text
    /// Handles both patterns:
    /// - "for the repository myrepo" (keyword-first)
    /// - "the myrepo repository" (keyword-last)
    private func extractRepositoryMention(from lowercaseText: String, originalText: String) -> (repoName: String, fullMatchRange: Range<String.Index>)? {
        // Try keyword-first patterns first (e.g., "for the repository myrepo")
        if let result = extractKeywordFirstPattern(from: lowercaseText, originalText: originalText) {
            return result
        }

        // Try keyword-last patterns (e.g., "the myrepo repository")
        if let result = extractKeywordLastPattern(from: lowercaseText, originalText: originalText) {
            return result
        }

        return nil
    }

    /// Extract repository name that comes AFTER the keyword
    /// e.g., "for the repository myrepo" -> "myrepo"
    private func extractKeywordFirstPattern(from lowercaseText: String, originalText: String) -> (repoName: String, fullMatchRange: Range<String.Index>)? {
        // Sort phrases by length (longest first) to match most specific first
        let sortedPhrases = precedingPhrases.sorted { $0.count > $1.count }

        for phrase in sortedPhrases {
            if let phraseRange = lowercaseText.range(of: phrase) {
                // Find the word(s) after the phrase
                let afterPhrase = lowercaseText[phraseRange.upperBound...]

                // Skip whitespace
                let trimmed = afterPhrase.drop { $0.isWhitespace }

                guard !trimmed.isEmpty else { continue }

                // Extract the repository name (next word or words until punctuation/end)
                var repoName = ""
                var endIndex = trimmed.startIndex

                for char in trimmed {
                    if char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." {
                        repoName.append(char)
                        endIndex = trimmed.index(after: endIndex)
                    } else if char.isWhitespace && !repoName.isEmpty {
                        // Check if next non-whitespace could be part of the name
                        break
                    } else if repoName.isEmpty {
                        continue
                    } else {
                        break
                    }
                }

                guard !repoName.isEmpty else { continue }

                // Calculate the full match range in original text
                let matchStart = phraseRange.lowerBound
                let matchEnd = lowercaseText.index(phraseRange.upperBound, offsetBy: lowercaseText.distance(from: phraseRange.upperBound, to: endIndex))

                // Convert to original text range
                let originalStart = originalText.index(originalText.startIndex, offsetBy: lowercaseText.distance(from: lowercaseText.startIndex, to: matchStart))
                let originalEnd = originalText.index(originalText.startIndex, offsetBy: lowercaseText.distance(from: lowercaseText.startIndex, to: matchEnd))

                return (repoName: repoName, fullMatchRange: originalStart..<originalEnd)
            }
        }

        return nil
    }

    /// Extract repository name that comes BEFORE the keyword
    /// e.g., "the myrepo repository" -> "myrepo"
    /// e.g., "can you do this on the i2c repository" -> "i2c"
    private func extractKeywordLastPattern(from lowercaseText: String, originalText: String) -> (repoName: String, fullMatchRange: Range<String.Index>)? {
        for keyword in followingPhrases {
            // Find keyword with word boundary (space or end of string after it)
            // This avoids matching "repository" inside "repositories"
            var searchStart = lowercaseText.startIndex

            while let keywordRange = lowercaseText.range(of: keyword, range: searchStart..<lowercaseText.endIndex) {
                // Move search forward for next iteration
                searchStart = keywordRange.upperBound

                // Verify this is a word boundary (end of string or followed by space/punctuation)
                if keywordRange.upperBound < lowercaseText.endIndex {
                    let nextChar = lowercaseText[keywordRange.upperBound]
                    if nextChar.isLetter || nextChar.isNumber {
                        continue // Not a word boundary, keep searching
                    }
                }

                // Look backward for the repository name
                let beforeKeyword = String(lowercaseText[..<keywordRange.lowerBound])

                // Find the last word before the keyword (skip "the", "a", etc.)
                let words = beforeKeyword.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

                guard !words.isEmpty else { continue }

                // Work backwards to find a valid repo name (skip articles/prepositions)
                let skipWords = Set(["the", "a", "an", "this", "that", "use", "using"])
                var repoName: String?
                var repoWordIndex: Int?

                for i in stride(from: words.count - 1, through: 0, by: -1) {
                    let word = words[i]
                    if skipWords.contains(word) {
                        continue
                    }
                    // Valid repo name character check
                    let validChars = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
                    if validChars && word.count >= 2 {
                        repoName = word
                        repoWordIndex = i
                        break
                    }
                }

                guard let foundRepoName = repoName, let wordIdx = repoWordIndex else { continue }

                // Calculate the full match range
                // Find where the repo word starts in the original text
                var currentIndex = lowercaseText.startIndex
                for i in 0..<wordIdx {
                    if let range = lowercaseText.range(of: words[i], range: currentIndex..<lowercaseText.endIndex) {
                        currentIndex = range.upperBound
                    }
                }

                // Find the actual repo name position
                guard let repoRange = lowercaseText.range(of: foundRepoName, range: currentIndex..<keywordRange.lowerBound) else { continue }

                // The full match includes from repo name to end of keyword
                let matchStart = repoRange.lowerBound
                let matchEnd = keywordRange.upperBound

                // Convert to original text range
                let originalStart = originalText.index(originalText.startIndex, offsetBy: lowercaseText.distance(from: lowercaseText.startIndex, to: matchStart))
                let originalEnd = originalText.index(originalText.startIndex, offsetBy: lowercaseText.distance(from: lowercaseText.startIndex, to: matchEnd))

                return (repoName: foundRepoName, fullMatchRange: originalStart..<originalEnd)
            }
        }

        return nil
    }

    /// Find the best matching source using semantic similarity
    private func findBestMatch(repoName: String, sources: [Source]) -> (source: Source?, confidence: Double) {
        guard !sources.isEmpty else {
            return (nil, 0.0)
        }

        var bestMatch: Source?
        var bestScore: Double = 0.0

        let normalizedInput = repoName.lowercased()

        for source in sources {
            let sourceName = normalizeSourceName(source).lowercased()

            // Calculate similarity score using multiple methods
            let score = calculateSimilarity(input: normalizedInput, sourceName: sourceName)

            if score > bestScore {
                bestScore = score
                bestMatch = source
            }
        }

        // Only return a match if confidence is above threshold
        let confidenceThreshold = 0.3
        if bestScore >= confidenceThreshold {
            return (bestMatch, bestScore)
        }

        return (nil, 0.0)
    }

    /// Calculate similarity between input and source name
    private func calculateSimilarity(input: String, sourceName: String) -> Double {
        // 1. Exact match
        if input == sourceName {
            return 1.0
        }

        // Tokenize both for various comparisons
        let inputTokens = Set(input.components(separatedBy: CharacterSet(charactersIn: "-_. ")).filter { !$0.isEmpty })
        let sourceTokens = Set(sourceName.components(separatedBy: CharacterSet(charactersIn: "-_. ")).filter { !$0.isEmpty })

        // 2. Exact token match - input exactly matches one of the source tokens
        // Handles "i2c" matching "node-i2c" (where source tokens are ["node", "i2c"])
        if sourceTokens.contains(input) {
            // Score based on how significant the matched token is
            let tokenSignificance = Double(input.count) / Double(sourceName.replacingOccurrences(of: "-", with: "").count)
            return 0.85 + (tokenSignificance * 0.15) // 0.85 - 1.0 range
        }

        // 3. Input matches multiple tokens or vice versa
        // Handles "node i2c" matching "node-i2c"
        let intersection = inputTokens.intersection(sourceTokens)
        if !intersection.isEmpty {
            let matchRatio = Double(intersection.count) / Double(max(inputTokens.count, sourceTokens.count))
            if matchRatio >= 0.5 {
                return 0.75 + (matchRatio * 0.2) // 0.75 - 0.95 range for multi-token match
            }
        }

        // 4. Contains match - input is substring of source or vice versa
        if sourceName.contains(input) || input.contains(sourceName) {
            let containsScore = Double(min(input.count, sourceName.count)) / Double(max(input.count, sourceName.count))
            return 0.7 + (containsScore * 0.15) // 0.7 - 0.85 range
        }

        // 5. Partial token match - input is contained within a source token
        // Handles "i2c" matching within "node-i2c-driver"
        for token in sourceTokens {
            if token.contains(input) && input.count >= 2 {
                let partialScore = Double(input.count) / Double(token.count)
                return 0.6 + (partialScore * 0.2) // 0.6 - 0.8 range
            }
        }

        // 6. Prefix/suffix match
        if sourceName.hasPrefix(input) || sourceName.hasSuffix(input) ||
           input.hasPrefix(sourceName) || input.hasSuffix(sourceName) {
            return 0.6
        }

        // 7. Vector embedding similarity using cosine similarity
        // Handles semantic similarity like "node i2c" ~ "node-i2c"
        if let semanticScore = embeddingCosineSimilarity(input, sourceName), semanticScore > 0.5 {
            return 0.4 + (semanticScore - 0.5) * 0.4 // 0.4 - 0.6 range
        }

        // 8. Levenshtein-based similarity for typos/transcription errors
        let levenshteinScore = levenshteinSimilarity(input, sourceName)
        if levenshteinScore > 0.6 {
            return levenshteinScore * 0.5 // Max 0.5 for fuzzy match
        }

        return 0.0
    }

    /// Calculate cosine similarity between two strings using NLEmbedding vectors
    private func embeddingCosineSimilarity(_ a: String, _ b: String) -> Double? {
        guard let embedding = embedding,
              let vecA = embedding.vector(for: a),
              let vecB = embedding.vector(for: b) else {
            return nil
        }
        return cosineSimilarity(vecA, vecB)
    }

    /// Calculate cosine similarity between two vectors
    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let magnitudeA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let magnitudeB = sqrt(b.map { $0 * $0 }.reduce(0, +))

        guard magnitudeA > 0 && magnitudeB > 0 else { return 0.0 }

        return dotProduct / (magnitudeA * magnitudeB)
    }

    /// Calculate Levenshtein distance similarity
    private func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let distance = levenshteinDistance(s1, s2)
        let maxLength = max(s1.count, s2.count)
        guard maxLength > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLength))
    }

    /// Calculate Levenshtein distance between two strings
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        guard m > 0 else { return n }
        guard n > 0 else { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }

        return matrix[m][n]
    }

    /// Clean the prompt by removing the repository reference
    private func cleanPrompt(originalText: String, matchRange: Range<String.Index>) -> String {
        var cleaned = originalText

        // Remove the matched range
        cleaned.removeSubrange(matchRange)

        // Clean up extra whitespace and punctuation
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove leading punctuation/conjunctions left over
        let leadingToRemove = [",", ".", "and", "then", "also", "please"]
        for prefix in leadingToRemove {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Capitalize first letter if needed
        if let first = cleaned.first, first.isLowercase {
            cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }

        return cleaned
    }
}
