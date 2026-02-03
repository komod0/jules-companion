import Foundation

/// A singleton network logger that tracks all API requests and responses.
/// Logs are stored in memory and optionally written to a file for debugging.
@MainActor
class NetworkLogger: ObservableObject {
    static let shared = NetworkLogger()

    /// Whether logging is enabled
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "networkLoggingEnabled")
            if isEnabled {
                log("Network logging enabled")
            }
        }
    }

    /// Whether to log response bodies (can be verbose)
    @Published var logResponseBodies: Bool {
        didSet {
            UserDefaults.standard.set(logResponseBodies, forKey: "networkLoggingResponseBodies")
        }
    }

    /// Maximum response body length to log (to prevent huge logs)
    var maxResponseBodyLength: Int = 2000

    /// Recent log entries (kept in memory for quick access)
    @Published private(set) var recentLogs: [LogEntry] = []

    /// Maximum number of logs to keep in memory
    private let maxLogsInMemory = 500

    /// File URL for persistent logging
    private let logFileURL: URL?

    /// Date formatter for log timestamps
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Represents a single log entry
    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let type: LogType
        let method: String
        let url: String
        let statusCode: Int?
        let duration: TimeInterval?
        let requestBody: String?
        let responseBody: String?
        let error: String?

        enum LogType: String {
            case request = "REQ"
            case response = "RES"
            case error = "ERR"
        }

        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }

        var summary: String {
            var parts: [String] = []
            parts.append("[\(formattedTimestamp)]")
            parts.append("[\(type.rawValue)]")
            parts.append(method)

            // Show shortened URL (remove base and API key)
            let shortURL = url
                .replacingOccurrences(of: "https://jules.googleapis.com/v1alpha", with: "")
                .components(separatedBy: "?").first ?? url
            parts.append(shortURL)

            if let statusCode = statusCode {
                let emoji = (200...299).contains(statusCode) ? "✅" : "❌"
                parts.append("\(emoji) \(statusCode)")
            }

            if let duration = duration {
                parts.append(String(format: "(%.0fms)", duration * 1000))
            }

            if let error = error {
                parts.append("Error: \(error)")
            }

            return parts.joined(separator: " ")
        }
    }

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "networkLoggingEnabled")
        self.logResponseBodies = UserDefaults.standard.bool(forKey: "networkLoggingResponseBodies")

        // Set up log file in Application Support/Jules/Logs
        if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logsDir = appSupportURL.appendingPathComponent("Jules/Logs")
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

            let dateString = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
                .replacingOccurrences(of: "/", with: "-")
            self.logFileURL = logsDir.appendingPathComponent("network-\(dateString).log")
        } else {
            self.logFileURL = nil
        }
    }

    // MARK: - Public Logging Methods

    /// Log an outgoing request
    func logRequest(method: String, url: String, body: Data? = nil) {
        guard isEnabled else { return }

        var requestBody: String? = nil
        if let body = body, logResponseBodies {
            requestBody = String(data: body, encoding: .utf8)
        }

        let entry = LogEntry(
            timestamp: Date(),
            type: .request,
            method: method,
            url: sanitizeURL(url),
            statusCode: nil,
            duration: nil,
            requestBody: requestBody,
            responseBody: nil,
            error: nil
        )

        addEntry(entry)
        writeToConsole(entry)
        writeToFile(entry)
    }

    /// Log a response
    func logResponse(method: String, url: String, statusCode: Int, duration: TimeInterval, body: Data? = nil) {
        guard isEnabled else { return }

        var responseBody: String? = nil
        if let body = body, logResponseBodies {
            if let bodyString = String(data: body, encoding: .utf8) {
                responseBody = String(bodyString.prefix(maxResponseBodyLength))
                if bodyString.count > maxResponseBodyLength {
                    responseBody? += "... [truncated]"
                }
            }
        }

        let entry = LogEntry(
            timestamp: Date(),
            type: .response,
            method: method,
            url: sanitizeURL(url),
            statusCode: statusCode,
            duration: duration,
            requestBody: nil,
            responseBody: responseBody,
            error: nil
        )

        addEntry(entry)
        writeToConsole(entry)
        writeToFile(entry)
    }

    /// Log an error
    func logError(method: String, url: String, error: Error, duration: TimeInterval? = nil) {
        guard isEnabled else { return }

        let entry = LogEntry(
            timestamp: Date(),
            type: .error,
            method: method,
            url: sanitizeURL(url),
            statusCode: nil,
            duration: duration,
            requestBody: nil,
            responseBody: nil,
            error: error.localizedDescription
        )

        addEntry(entry)
        writeToConsole(entry)
        writeToFile(entry)
    }

    /// Log a general message
    func log(_ message: String) {
        guard isEnabled else { return }

        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [INFO] \(message)"

        print("🌐 \(logLine)")

        if let fileURL = logFileURL {
            appendToFile(fileURL: fileURL, line: logLine)
        }
    }

    // MARK: - Log Management

    /// Clear all logs from memory
    func clearLogs() {
        recentLogs.removeAll()
    }

    /// Get the log file path for sharing
    func getLogFilePath() -> URL? {
        return logFileURL
    }

    /// Export logs as a string
    func exportLogs() -> String {
        return recentLogs.map { entry in
            var lines = [entry.summary]
            if let requestBody = entry.requestBody {
                lines.append("  Request: \(requestBody)")
            }
            if let responseBody = entry.responseBody {
                lines.append("  Response: \(responseBody)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private func addEntry(_ entry: LogEntry) {
        recentLogs.append(entry)
        if recentLogs.count > maxLogsInMemory {
            recentLogs.removeFirst(recentLogs.count - maxLogsInMemory)
        }
    }

    private func writeToConsole(_ entry: LogEntry) {
        let emoji: String
        switch entry.type {
        case .request: emoji = "⬆️"
        case .response: emoji = "⬇️"
        case .error: emoji = "❌"
        }

        print("\(emoji) \(entry.summary)")

        if let requestBody = entry.requestBody {
            print("   📤 Body: \(requestBody.prefix(500))")
        }
        if let responseBody = entry.responseBody {
            print("   📥 Body: \(responseBody.prefix(500))")
        }
    }

    private func writeToFile(_ entry: LogEntry) {
        guard let fileURL = logFileURL else { return }

        var lines = [entry.summary]
        if let requestBody = entry.requestBody {
            lines.append("  Request Body: \(requestBody)")
        }
        if let responseBody = entry.responseBody {
            lines.append("  Response Body: \(responseBody)")
        }

        let content = lines.joined(separator: "\n")
        appendToFile(fileURL: fileURL, line: content)
    }

    private func appendToFile(fileURL: URL, line: String) {
        let lineWithNewline = line + "\n"
        if let data = lineWithNewline.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Remove API key from URL for logging
    private func sanitizeURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != "key" }
        return components.url?.absoluteString ?? url
    }
}
