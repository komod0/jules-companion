import Foundation
import FirebaseAI

// NB: Ensure corresponding Models are defined elsewhere.

/// Custom error types for API operations with user-friendly messages
enum APIError: LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case clientError(statusCode: Int, message: String)
    case serverError(statusCode: Int, message: String)
    case invalidURL
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your API key is invalid or has expired. Please update your API key in Settings."
        case .forbidden:
            return "Access denied. You don't have permission to access this resource."
        case .notFound:
            return "The requested resource was not found."
        case .clientError(let statusCode, let message):
            return "Request failed (Error \(statusCode)): \(message)"
        case .serverError(let statusCode, let message):
            return "Server error (Error \(statusCode)): \(message)"
        case .invalidURL:
            return "Invalid URL. Please try again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// --- Live API Endpoint ---
private enum APIEndpoint {
    static let base = "https://jules.googleapis.com/v1alpha"

    static let sessions = "\(base)/sessions"
    static let sources = "\(base)/sources"
    // Notifications not explicitly in new API, skipping for now

    // Static internal/external URLs
    static let settings = "myapp://settings"
    // No direct web view URL for "all tasks", but sessions have their own URL
}
// --- ---

struct ListSessionsResponse: Decodable {
    let sessions: [Session]?
    let nextPageToken: String?
}

struct ListActivitiesResponse: Decodable {
    let activities: [Activity]?
}

struct ListSourcesResponse: Decodable {
    let sources: [Source]?
    let nextPageToken: String?
}

/// Response structure for Gemini-generated progress summaries
struct GeminiProgressSummary: Decodable {
    let title: String
    let description: String
}

/// Response structure for batched Gemini summaries (includes index for mapping)
struct GeminiBatchSummaryItem: Decodable {
    let index: Int
    let title: String
    let description: String
}

class APIService {

    // URLSession configured to not cache responses.
    // MEMORY FIX: Using .shared URLSession causes API responses to accumulate
    // in URLCache.shared, wasting memory since we always fetch fresh data.
    // By using a dedicated session with no caching, we save ~50-100MB over time.
    private let session: URLSession
    // Shared JSON Decoder configured for date and key handling
    private let decoder: JSONDecoder

    // API Key
    var apiKey: String?

    /// Rate limiter for Gemini API calls to prevent quota exceeded errors.
    /// Firebase Vertex AI limits: 100 requests per minute per user per project.
    private let geminiRateLimiter = RateLimiter(maxRequests: 100, windowDuration: 60, warningThreshold: 80)

    /// MEMORY FIX: Cache of response data hashes per session ID.
    /// Used to skip JSON decoding (~29MB) when activity data hasn't changed.
    /// Key = sessionId, Value = hash of raw response data
    private var activityResponseHashes: [String: Int] = [:]

    /// Result of activity fetch that may skip decoding if unchanged
    enum ActivityFetchResult {
        case activities([Activity])
        case unchanged
    }

    /// Creates APIService with a non-caching URLSession to minimize memory usage.
    /// Pass a custom session for testing.
    init(session: URLSession? = nil) {
        if let customSession = session {
            self.session = customSession
        } else {
            // Create a session configuration that doesn't cache responses
            let config = URLSessionConfiguration.default
            config.urlCache = nil  // Disable caching entirely
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.decoder = JSONDecoder()

        // Configure a specific formatter for "YYYY-MM-DDTHH:MM:SS.SSSZ" or RFC3339
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ" // Explicit format
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0) // 'Z' implies UTC

        decoder.dateDecodingStrategy = .iso8601 // The new API uses ISO8601/RFC3339
    }

    private func authenticatedURL(from urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }

        if let key = apiKey, !key.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "key", value: key))
            components.queryItems = queryItems
        }

        return components.url
    }

    // Generic Fetch Function using URLSession
    private func fetchData<T: Decodable>(from urlString: String) async throws -> T {
        guard let url = authenticatedURL(from: urlString) else {
            print("❌ Bad URL: \(urlString)")
            throw URLError(.badURL)
        }

        // Log request
        await MainActor.run {
            NetworkLogger.shared.logRequest(method: "GET", url: urlString)
        }

        let startTime = Date()

        do {
            // Perform the network request
            let (data, response) = try await session.data(from: url)
            let duration = Date().timeIntervalSince(startTime)

            // Check HTTP Response Status
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Did not receive HTTP response from \(url)")
                let apiError = APIError.networkError(URLError(.badServerResponse))
                await MainActor.run {
                    NetworkLogger.shared.logError(method: "GET", url: urlString, error: apiError, duration: duration)
                }
                throw apiError
            }

            // Log response
            await MainActor.run {
                NetworkLogger.shared.logResponse(method: "GET", url: urlString, statusCode: httpResponse.statusCode, duration: duration, body: data)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // Handle HTTP errors with specific error types
                let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                print("❌ HTTP Error: \(httpResponse.statusCode). Body: \(errorBody)")

                // Create appropriate APIError based on status code
                let apiError: APIError
                switch httpResponse.statusCode {
                case 401:
                    apiError = .unauthorized
                case 403:
                    apiError = .forbidden
                case 404:
                    apiError = .notFound
                case 400...499:
                    apiError = .clientError(statusCode: httpResponse.statusCode, message: errorBody)
                default:
                    apiError = .serverError(statusCode: httpResponse.statusCode, message: errorBody)
                }

                throw apiError
            }

            // Decode the JSON data using the configured decoder
            let decodedData = try decoder.decode(T.self, from: data)
            return decodedData

        } catch let decodingError as DecodingError {
             // Provide detailed decoding error logs
             print("❌ Decoding Error: \(decodingError) for URL: \(url)")
             throw decodingError
        } catch {
            // Handle other network errors
            let duration = Date().timeIntervalSince(startTime)
            print("❌ Network Error: \(error.localizedDescription) for URL: \(url)")

            // Log error
            await MainActor.run {
                NetworkLogger.shared.logError(method: "GET", url: urlString, error: error, duration: duration)
            }

            throw error
        }
    }

    /// Fetches raw data from a URL without decoding.
    /// Used for hash-based cache validation to skip expensive JSON decoding.
    private func fetchRawData(from urlString: String) async throws -> Data {
        guard let url = authenticatedURL(from: urlString) else {
            throw URLError(.badURL)
        }

        await MainActor.run {
            NetworkLogger.shared.logRequest(method: "GET", url: urlString)
        }

        let startTime = Date()

        do {
            let (data, response) = try await session.data(from: url)
            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError(URLError(.badServerResponse))
            }

            await MainActor.run {
                NetworkLogger.shared.logResponse(method: "GET", url: urlString, statusCode: httpResponse.statusCode, duration: duration, body: data)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                switch httpResponse.statusCode {
                case 401:
                    throw APIError.unauthorized
                case 403:
                    throw APIError.forbidden
                case 404:
                    throw APIError.notFound
                case 400...499:
                    throw APIError.clientError(statusCode: httpResponse.statusCode, message: errorBody)
                default:
                    throw APIError.serverError(statusCode: httpResponse.statusCode, message: errorBody)
                }
            }

            return data
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            await MainActor.run {
                NetworkLogger.shared.logError(method: "GET", url: urlString, error: error, duration: duration)
            }
            throw error
        }
    }

    // --- Specific API Call Methods ---

    // Fetches sources (repositories) with pagination support
    // Fetches all available sources by following pagination tokens
    func fetchSources() async throws -> [Source] {
        var allSources: [Source] = []
        var pageToken: String? = nil

        repeat {
            guard var components = URLComponents(string: APIEndpoint.sources) else {
                throw URLError(.badURL)
            }

            // Add pagination parameters if we have a page token
            if let token = pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: token)]
            }

            guard let urlString = components.url?.absoluteString else {
                throw URLError(.badURL)
            }

            let response: ListSourcesResponse = try await fetchData(from: urlString)

            if let sources = response.sources {
                allSources.append(contentsOf: sources)
            }

            pageToken = response.nextPageToken
        } while pageToken != nil

        return allSources
    }

    // Fetches sessions (tasks)
    func fetchSessions(pageSize: Int = 10, pageToken: String? = nil) async throws -> ListSessionsResponse {
        guard var components = URLComponents(string: APIEndpoint.sessions) else {
            throw URLError(.badURL)
        }

        var queryItems = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let token = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: token))
        }
        components.queryItems = queryItems

        guard let urlString = components.url?.absoluteString else {
            throw URLError(.badURL)
        }

        return try await fetchData(from: urlString)
    }

    // Fetch a single session by ID
    // Returns the session if found, throws APIError.notFound if deleted
    func fetchSession(sessionId: String) async throws -> Session {
        let urlString = "\(APIEndpoint.sessions)/\(sessionId)"
        return try await fetchData(from: urlString)
    }

    // Fetch Activities for a Session
    func fetchActivities(sessionId: String) async throws -> [Activity] {
        let urlString = "\(APIEndpoint.sessions)/\(sessionId)/activities"

        let response: ListActivitiesResponse = try await fetchData(from: urlString)
        return response.activities ?? []
    }

    /// MEMORY FIX: Fetch activities with hash-based cache validation.
    /// Skips JSON decoding (~29MB) if the response data hasn't changed since last fetch.
    /// This prevents memory spikes during background polling when activities are unchanged.
    func fetchActivitiesIfChanged(sessionId: String) async throws -> ActivityFetchResult {
        let urlString = "\(APIEndpoint.sessions)/\(sessionId)/activities"

        // Fetch raw data first (small memory footprint)
        let data = try await fetchRawData(from: urlString)

        // Compute hash of response data
        let newHash = data.hashValue

        // Check if data has changed
        if let cachedHash = activityResponseHashes[sessionId], cachedHash == newHash {
            // Data unchanged - skip expensive JSON decoding
            return .unchanged
        }

        // Data changed - decode and update cache
        let response = try decoder.decode(ListActivitiesResponse.self, from: data)
        activityResponseHashes[sessionId] = newHash

        return .activities(response.activities ?? [])
    }

    /// Clears the activity response hash for a session.
    /// Call this when you want to force a re-fetch (e.g., after sending a message).
    func clearActivityCache(for sessionId: String) {
        activityResponseHashes.removeValue(forKey: sessionId)
    }

    // Fetches activities for multiple sessions concurrently with hash-based caching.
    // Returns a dictionary mapping session ID to a Result containing either activities, unchanged, or an error.
    func fetchActivities(sessionIds: [String]) async -> [String: Result<ActivityFetchResult, Error>] {
        var results: [String: Result<ActivityFetchResult, Error>] = [:]

        await withTaskGroup(of: (String, Result<ActivityFetchResult, Error>).self) { group in
            for sessionId in sessionIds {
                group.addTask {
                    do {
                        let result = try await self.fetchActivitiesIfChanged(sessionId: sessionId)
                        return (sessionId, .success(result))
                    } catch {
                        return (sessionId, .failure(error))
                    }
                }
            }

            for await (sessionId, result) in group {
                results[sessionId] = result
            }
        }

        return results
    }

    // Create a new session
    /// Creates a new session and returns the created Session object.
    /// Returns the Session directly from the API response, avoiding race conditions
    /// where polling for the "newest" session might return a different session.
    func createSession(source: Source, branchName: String, prompt: String) async throws -> Session? {
        guard let url = authenticatedURL(from: APIEndpoint.sessions) else {
            throw URLError(.badURL)
        }

        let sessionBody: [String: Any] = [
            "prompt": prompt,
            "sourceContext": [
                "source": source.name, // "sources/{source}"
                "githubRepoContext": [
                    "startingBranch": branchName
                ]
            ],
            "automationMode": "AUTO_CREATE_PR",
            "requirePlanApproval": false
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: sessionBody) else {
            print("❌ Failed to encode session body")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let urlString = APIEndpoint.sessions
        print("⬆️ Creating Session at \(url)")

        // Log request
        await MainActor.run {
            NetworkLogger.shared.logRequest(method: "POST", url: urlString, body: jsonData)
        }

        let startTime = Date()

        do {
            let (data, response) = try await session.data(for: request)
            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                let apiError = APIError.networkError(URLError(.badServerResponse))
                await MainActor.run {
                    NetworkLogger.shared.logError(method: "POST", url: urlString, error: apiError, duration: duration)
                }
                throw apiError
            }

            // Log response
            await MainActor.run {
                NetworkLogger.shared.logResponse(method: "POST", url: urlString, statusCode: httpResponse.statusCode, duration: duration, body: data)
            }

            print("⬇️ Create Session Response Status: \(httpResponse.statusCode)")

            if (200...299).contains(httpResponse.statusCode) {
                // Parse the created session from the response
                let decoder = JSONDecoder()
                do {
                    let createdSession = try decoder.decode(Session.self, from: data)
                    print("✅ Session Created Successfully: \(createdSession.id)")
                    return createdSession
                } catch {
                    // Log parsing error but don't fail - session was created
                    print("⚠️ Session created but failed to parse response: \(error)")
                    return nil
                }
            } else {
                 let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                 print("❌ Create Session Failed: \(httpResponse.statusCode). Body: \(errorBody)")
                 return nil
            }
        } catch {
             let duration = Date().timeIntervalSince(startTime)
             print("❌ Network Error during session creation: \(error)")
             await MainActor.run {
                 NetworkLogger.shared.logError(method: "POST", url: urlString, error: error, duration: duration)
             }
             throw error
        }
    }

    // Send a message to a session
    func sendMessage(sessionId: String, message: String) async throws -> Bool {
        let urlString = "\(APIEndpoint.sessions)/\(sessionId):sendMessage"
        guard let url = authenticatedURL(from: urlString) else {
            throw URLError(.badURL)
        }

        let messageBody: [String: Any] = [
            "prompt": message
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: messageBody) else {
            print("❌ Failed to encode message body")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        print("⬆️ Sending message to Session \(sessionId) at \(url)")

        // Log request
        await MainActor.run {
            NetworkLogger.shared.logRequest(method: "POST", url: urlString, body: jsonData)
        }

        let startTime = Date()

        do {
            let (data, response) = try await session.data(for: request)
            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                let apiError = APIError.networkError(URLError(.badServerResponse))
                await MainActor.run {
                    NetworkLogger.shared.logError(method: "POST", url: urlString, error: apiError, duration: duration)
                }
                throw apiError
            }

            // Log response
            await MainActor.run {
                NetworkLogger.shared.logResponse(method: "POST", url: urlString, statusCode: httpResponse.statusCode, duration: duration, body: data)
            }

            print("⬇️ Send Message Response Status: \(httpResponse.statusCode)")

            if (200...299).contains(httpResponse.statusCode) {
                print("✅ Message Sent Successfully")
                return true
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                print("❌ Send Message Failed: \(httpResponse.statusCode). Body: \(errorBody)")
                return false
            }
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            print("❌ Network Error during message sending: \(error)")
            await MainActor.run {
                NetworkLogger.shared.logError(method: "POST", url: urlString, error: error, duration: duration)
            }
            throw error
        }
    }

    func sendToGemini(prompt: String) async -> String? {
        // Skip if Firebase is not enabled
        guard ENABLE_FIREBASE else {
            return nil
        }

        // Wait for rate limit slot before making request
        await geminiRateLimiter.waitAndRecord()

        let ai = FirebaseAI.firebaseAI(backend: .vertexAI())
        let model = ai.generativeModel(modelName: "gemini-2.5-flash-lite")

        // Retry with exponential backoff for rate limit errors
        let maxRetries = 3
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let response = try await model.generateContent(prompt)
                return response.text
            } catch {
                lastError = error
                let errorString = String(describing: error)

                // Check if this is a rate limit error (429 / RESOURCE_EXHAUSTED)
                let isRateLimitError = errorString.contains("429") ||
                    errorString.contains("RESOURCE_EXHAUSTED") ||
                    errorString.contains("RATE_LIMIT_EXCEEDED")

                if isRateLimitError && attempt < maxRetries - 1 {
                    // Exponential backoff: 2s, 4s, 8s
                    let backoffSeconds = pow(2.0, Double(attempt + 1))
                    print("Gemini rate limited (attempt \(attempt + 1)/\(maxRetries)), retrying in \(Int(backoffSeconds))s...")
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                    continue
                }

                // Not a rate limit error or final attempt - don't retry
                break
            }
        }

        // Log the final error
        if let error = lastError {
            print("Gemini Error: \(error)")
        }
        return nil
    }

    // MARK: - Gemini Prompt Constants

    private static let geminiTitlePrompt = "Maximum 3 words. Capture what has been accomplished the latest update. If a file was update, mention the filename in markdown syntax."

    private static let geminiDescriptionPrompt = "Maximum 300 characters, but use as few as possible. Explain what happened in the last activity. Simple Markdown only: bold text, code blocks, or a list. Explain why you're confident in the solution. Don't say the word confident. Present the details that matters, without filler. No special characters outside code blocks. If files were updated, try to include. You MUST use a list if there are 3 or more changes, files, or actions. Otherwise, use a single paragraph or sentence. If updates are sequential, use a numbered list. If you use a list, DON'T add text after the list items."

    /// Maximum number of activities to include in a single batched Gemini request
    private static let geminiBatchSize = 10

    /// Processes activity descriptions through Gemini to generate friendly summaries.
    /// Returns only the generated results (index -> summary mapping) to avoid copying the full activities array.
    /// - Parameters:
    ///   - activities: The activities to process
    ///   - throttle: If true, processes in small batches with delays to avoid rate limits.
    ///               Use throttle=false for the active session (user is waiting),
    ///               and throttle=true for backlogged/background sessions.
    /// - Returns: Dictionary mapping activity index to generated summary (only includes activities that were processed)
    func processActivityDescriptionsWithGemini(_ activities: [Activity], throttle: Bool = false) async -> [Int: GeminiProgressSummary] {
        // MEMORY FIX: Extract only the progressDescription strings we need, not full Activity structs.
        // Activity structs can contain large artifacts (diffs, media, bash output) - potentially MB each.
        // By capturing only the small String, we avoid retaining all that data during concurrent API calls.
        let activitiesToProcess: [(Int, String)] = activities.enumerated().compactMap { index, activity in
            guard let progressDescription = activity.progressUpdated?.description,
                  !progressDescription.isEmpty,
                  activity.generatedDescription == nil || activity.generatedTitle == nil else {
                return nil
            }
            return (index, progressDescription)
        }

        // If nothing to process, return immediately
        guard !activitiesToProcess.isEmpty else {
            return [:]
        }

        let results: [(Int, GeminiProgressSummary?)]

        if throttle {
            // Throttled processing: small batches with delays to stay under rate limits
            // Process 5 at a time with 1 second delay between batches
            let batchSize = 5
            let delayBetweenBatches: UInt64 = 1_000_000_000 // 1 second in nanoseconds

            var collected: [(Int, GeminiProgressSummary?)] = []
            let batches = stride(from: 0, to: activitiesToProcess.count, by: batchSize).map {
                Array(activitiesToProcess[$0..<min($0 + batchSize, activitiesToProcess.count)])
            }

            for (batchIndex, batch) in batches.enumerated() {
                // Add delay between batches (not before the first one)
                if batchIndex > 0 {
                    try? await Task.sleep(nanoseconds: delayBetweenBatches)
                }

                // Process this batch concurrently
                let batchResults = await withTaskGroup(of: (Int, GeminiProgressSummary?).self, returning: [(Int, GeminiProgressSummary?)].self) { group in
                    for (index, progressDescription) in batch {
                        group.addTask {
                            let summary = await self.generateGeminiSummary(for: progressDescription)
                            return (index, summary)
                        }
                    }

                    var batchCollected: [(Int, GeminiProgressSummary?)] = []
                    for await result in group {
                        batchCollected.append(result)
                    }
                    return batchCollected
                }
                collected.append(contentsOf: batchResults)
            }
            results = collected
        } else {
            // Non-throttled: process all concurrently for active session
            results = await withTaskGroup(of: (Int, GeminiProgressSummary?).self, returning: [(Int, GeminiProgressSummary?)].self) { group in
                for (index, progressDescription) in activitiesToProcess {
                    group.addTask {
                        let summary = await self.generateGeminiSummary(for: progressDescription)
                        return (index, summary)
                    }
                }

                var collected: [(Int, GeminiProgressSummary?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
        }

        // MEMORY FIX: Return only the results dictionary instead of copying the full activities array.
        // This avoids allocating ~12MB+ for the activities copy that triggered copy-on-write.
        // The caller applies these results directly to the session's existing activities.
        var resultsDict: [Int: GeminiProgressSummary] = [:]
        for (index, summary) in results {
            if let summary = summary {
                resultsDict[index] = summary
            }
        }
        return resultsDict
    }

    /// Helper to generate a Gemini summary for a progress description.
    /// Takes only the String we need, not the full Activity struct, to avoid memory bloat.
    private func generateGeminiSummary(for progressDescription: String) async -> GeminiProgressSummary? {
        let prompt = """
        You are a friendly, confident coding agent presenting work to a developer. Be clear and succinct. Be professional, but casual. Speak like you're talking with a co-worker with whom you have a good rapport.

        Generate a JSON response with two fields:
        - "title": \(Self.geminiTitlePrompt)
        - "description": \(Self.geminiDescriptionPrompt)

        Respond ONLY with valid JSON, no other text.

        Task: Summarize the following progress update:
        \(progressDescription)
        """

        let generatedText = await self.sendToGemini(prompt: prompt)
        return self.parseGeminiProgressSummary(generatedText)
    }

    /// Parses the Gemini response as JSON to extract title and description
    private func parseGeminiProgressSummary(_ text: String?) -> GeminiProgressSummary? {
        guard let text = text, !text.isEmpty else { return nil }

        // Try to extract JSON from the response (in case it's wrapped in markdown code blocks)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code block if present
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }
        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            return try JSONDecoder().decode(GeminiProgressSummary.self, from: data)
        } catch {
            print("Failed to parse Gemini response as JSON: \(error)")
            // Fallback: if JSON parsing fails, return nil (caller should handle gracefully)
            return nil
        }
    }

    // MARK: - Batched Gemini Processing

    /// Processes multiple activity descriptions in a single Gemini request.
    /// This is more efficient for completed sessions where we need to generate descriptions
    /// for many activities at once, reducing API calls and avoiding rate limits.
    /// - Parameters:
    ///   - activities: The activities to process
    /// - Returns: Dictionary mapping activity index to generated summary
    func processActivityDescriptionsBatched(_ activities: [Activity]) async -> [Int: GeminiProgressSummary] {
        // Extract activities that need processing
        let activitiesToProcess: [(Int, String)] = activities.enumerated().compactMap { index, activity in
            guard let progressDescription = activity.progressUpdated?.description,
                  !progressDescription.isEmpty,
                  activity.generatedDescription == nil || activity.generatedTitle == nil else {
                return nil
            }
            return (index, progressDescription)
        }

        guard !activitiesToProcess.isEmpty else {
            return [:]
        }

        var allResults: [Int: GeminiProgressSummary] = [:]

        // Process in batches of geminiBatchSize
        let batches = stride(from: 0, to: activitiesToProcess.count, by: Self.geminiBatchSize).map {
            Array(activitiesToProcess[$0..<min($0 + Self.geminiBatchSize, activitiesToProcess.count)])
        }

        for batch in batches {
            // Try batched processing first
            if let batchResults = await generateGeminiBatchSummary(for: batch) {
                for (index, summary) in batchResults {
                    allResults[index] = summary
                }
            } else {
                // Fallback to individual processing if batch fails
                print("Batch processing failed, falling back to individual requests for \(batch.count) activities")
                for (index, progressDescription) in batch {
                    if let summary = await generateGeminiSummary(for: progressDescription) {
                        allResults[index] = summary
                    }
                }
            }
        }

        return allResults
    }

    /// Generates summaries for multiple activities in a single Gemini request.
    /// - Parameter activities: Array of (index, progressDescription) tuples
    /// - Returns: Dictionary mapping original indices to summaries, or nil if batch processing failed
    private func generateGeminiBatchSummary(for activities: [(Int, String)]) async -> [Int: GeminiProgressSummary]? {
        guard !activities.isEmpty else { return [:] }

        // Build the numbered list of progress descriptions
        let numberedDescriptions = activities.enumerated().map { batchIndex, item in
            let (originalIndex, description) = item
            return "[\(batchIndex)] (original index \(originalIndex)):\n\(description)"
        }.joined(separator: "\n\n---\n\n")

        let prompt = """
        You are a friendly, confident coding agent presenting work to a developer. Be clear and succinct. Be professional, but casual. Speak like you're talking with a co-worker with whom you have a good rapport.

        Generate a JSON array with summaries for EACH of the \(activities.count) progress updates below. Each element must have:
        - "index": The original index number shown in parentheses for each update
        - "title": \(Self.geminiTitlePrompt)
        - "description": \(Self.geminiDescriptionPrompt)

        IMPORTANT: You must return exactly \(activities.count) items in the array, one for each progress update.
        Respond ONLY with valid JSON array, no other text.

        Progress updates to summarize:

        \(numberedDescriptions)
        """

        guard let generatedText = await sendToGemini(prompt: prompt) else {
            return nil
        }

        return parseGeminiBatchSummary(generatedText, expectedCount: activities.count)
    }

    /// Parses the batched Gemini response as a JSON array
    private func parseGeminiBatchSummary(_ text: String?, expectedCount: Int) -> [Int: GeminiProgressSummary]? {
        guard let text = text, !text.isEmpty else { return nil }

        // Clean up the response (remove markdown code blocks if present)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }
        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let items = try JSONDecoder().decode([GeminiBatchSummaryItem].self, from: data)

            // Convert to dictionary mapping original index to summary
            var results: [Int: GeminiProgressSummary] = [:]
            for item in items {
                results[item.index] = GeminiProgressSummary(title: item.title, description: item.description)
            }

            // Check if we got a reasonable number of results
            // Allow some tolerance (at least 50% success) to use partial results
            if results.count >= expectedCount / 2 {
                return results
            } else {
                print("Batch parsing returned too few results: \(results.count) of \(expectedCount) expected")
                return nil
            }
        } catch {
            print("Failed to parse batched Gemini response as JSON array: \(error)")
            return nil
        }
    }

    // --- Static URLs ---
    static var settingsURL: URL? { URL(string: APIEndpoint.settings) }

    // MARK: - API Key Verification

    /// Verifies that an API key is valid by attempting to fetch sessions.
    /// Returns true if the key is valid, false otherwise.
    static func verifyApiKey(_ apiKey: String) async -> Bool {
        let tempService = APIService()
        tempService.apiKey = apiKey

        do {
            _ = try await tempService.fetchSessions(pageSize: 1)
            return true
        } catch {
            print("❌ API key verification failed: \(error.localizedDescription)")
            return false
        }
    }
}
