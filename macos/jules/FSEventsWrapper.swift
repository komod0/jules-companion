import Foundation
import CoreServices

/// A wrapper around FSEvents for monitoring file system changes in a directory.
/// Used for tracking file paths in local repositories for autocomplete functionality.
@MainActor
final class FSEventsWrapper {

    // MARK: - Types

    /// Callback type for file system events - receives full relative paths
    typealias EventCallback = @MainActor @Sendable (Set<String>) -> Void

    /// Represents a file system event
    struct FileEvent: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        var isFile: Bool {
            // Check if it's a file (has ItemIsFile flag or doesn't have ItemIsDir flag)
            return (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0 ||
                   (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) == 0
        }

        var isCreated: Bool {
            return (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
        }

        var isRemoved: Bool {
            return (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
        }

        var isRenamed: Bool {
            return (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
        }
    }

    // MARK: - Properties

    /// The directory path being monitored (absolute path)
    let directoryPath: String

    /// Unique identifier for this watcher (typically the source/repo ID)
    let identifier: String

    /// Callback for when file paths are added
    private var onFilesAdded: EventCallback?

    /// Callback for when file paths are removed
    private var onFilesRemoved: EventCallback?

    /// The FSEvents stream
    private var eventStream: FSEventStreamRef?

    /// Whether the watcher is currently active
    private(set) var isWatching: Bool = false

    /// Debounce timer to batch rapid file changes
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.3

    /// Pending file path additions to be batched
    private var pendingAdditions: Set<String> = []

    /// Pending file path removals to be batched
    private var pendingRemovals: Set<String> = []

    /// Parsed .gitignore patterns for this repository
    private var gitignorePatterns: [GitignorePattern] = []

    /// Whether gitignore has been loaded
    private var gitignoreLoaded: Bool = false

    // MARK: - Gitignore Pattern

    /// Represents a single .gitignore pattern
    struct GitignorePattern {
        let pattern: String
        let isNegation: Bool
        let isDirectoryOnly: Bool
        let regex: NSRegularExpression?

        init(line: String) {
            var processedLine = line

            // Check for negation (lines starting with !)
            if processedLine.hasPrefix("!") {
                isNegation = true
                processedLine = String(processedLine.dropFirst())
            } else {
                isNegation = false
            }

            // Check for directory-only patterns (ending with /)
            if processedLine.hasSuffix("/") {
                isDirectoryOnly = true
                processedLine = String(processedLine.dropLast())
            } else {
                isDirectoryOnly = false
            }

            pattern = processedLine

            // Convert gitignore glob pattern to regex
            regex = GitignorePattern.createRegex(from: processedLine)
        }

        /// Convert a gitignore glob pattern to a regex
        static func createRegex(from pattern: String) -> NSRegularExpression? {
            var regexPattern = ""

            // If pattern starts with /, it's anchored to root
            let isAnchored = pattern.hasPrefix("/")
            var processedPattern = isAnchored ? String(pattern.dropFirst()) : pattern

            // Handle ** patterns
            processedPattern = processedPattern.replacingOccurrences(of: "**", with: "<<<DOUBLESTAR>>>")

            // Escape regex special characters except * and ?
            var escaped = ""
            for char in processedPattern {
                switch char {
                case ".", "+", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\":
                    escaped += "\\\(char)"
                case "*":
                    escaped += "[^/]*"
                case "?":
                    escaped += "[^/]"
                default:
                    escaped += String(char)
                }
            }

            // Restore ** patterns as .* (match anything including /)
            escaped = escaped.replacingOccurrences(of: "<<<DOUBLESTAR>>>", with: ".*")

            // If not anchored (no leading /), pattern can match in any subdirectory
            if isAnchored {
                regexPattern = "^\(escaped)"
            } else if processedPattern.contains("/") {
                // Pattern with / in it is relative to root
                regexPattern = "^\(escaped)"
            } else {
                // Pattern without / can match in any directory
                regexPattern = "(^|/)\(escaped)"
            }

            // Pattern must match the entire path component or end
            regexPattern += "(/|$)"

            return try? NSRegularExpression(pattern: regexPattern, options: [])
        }

        /// Check if a relative path matches this pattern
        func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
            if isDirectoryOnly && !isDirectory {
                return false
            }

            guard let regex = regex else { return false }

            let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
            return regex.firstMatch(in: relativePath, options: [], range: range) != nil
        }
    }

    // MARK: - Initialization

    /// Initialize with a directory path and identifier
    /// - Parameters:
    ///   - directoryPath: The path to monitor
    ///   - identifier: Unique identifier (e.g., repository ID)
    /// Note: Gitignore loading is deferred to avoid blocking the main thread.
    /// Call loadGitignoreAsync() before startWatching() for proper filtering.
    init(directoryPath: String, identifier: String) {
        self.directoryPath = directoryPath
        self.identifier = identifier
        // Gitignore loading moved to loadGitignoreAsync() to avoid blocking main thread
    }

    /// Load gitignore patterns asynchronously on a background thread.
    /// Must be called before startWatching() for proper file filtering.
    func loadGitignoreAsync() async {
        let path = directoryPath

        let patterns: [GitignorePattern] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitignorePath = (path as NSString).appendingPathComponent(".gitignore")

                guard FileManager.default.fileExists(atPath: gitignorePath),
                      let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }

                let loadedPatterns = content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    .map { GitignorePattern(line: $0) }

                continuation.resume(returning: loadedPatterns)
            }
        }

        self.gitignorePatterns = patterns
        self.gitignoreLoaded = true
    }

    /// Load and parse .gitignore file
    private func loadGitignore() {
        let gitignorePath = (directoryPath as NSString).appendingPathComponent(".gitignore")
        gitignoreLoaded = true

        guard FileManager.default.fileExists(atPath: gitignorePath),
              let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
            return
        }

        gitignorePatterns = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { GitignorePattern(line: $0) }
    }

    /// Reload .gitignore patterns (call when .gitignore file changes)
    func reloadGitignore() {
        gitignorePatterns.removeAll()
        loadGitignore()
    }

    deinit {
        // Clean up FSEvents stream directly - don't use Task as self will be nil by then
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    // MARK: - Public Methods

    /// Start monitoring the directory for file changes
    /// - Parameters:
    ///   - onFilesAdded: Callback when new files are detected
    ///   - onFilesRemoved: Callback when files are removed
    func startWatching(
        onFilesAdded: @escaping EventCallback,
        onFilesRemoved: @escaping EventCallback
    ) {
        guard !isWatching else { return }

        self.onFilesAdded = onFilesAdded
        self.onFilesRemoved = onFilesRemoved

        createEventStream()
        isWatching = true
    }

    /// Stop monitoring the directory
    func stopWatching() {
        guard isWatching else { return }

        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }

        pendingAdditions.removeAll()
        pendingRemovals.removeAll()
        isWatching = false
    }

    /// Perform an initial scan of the directory to populate the file path cache
    /// - Returns: Set of all file paths (relative to repo root) found in the directory
    func performInitialScan() async -> Set<String> {
        let basePath = directoryPath
        let patterns = gitignorePatterns

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var filePaths: Set<String> = []
                let fileManager = FileManager.default
                let baseURL = URL(fileURLWithPath: basePath)

                guard let enumerator = fileManager.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsPackageDescendants]  // Don't skip hidden files - let gitignore handle it
                ) else {
                    continuation.resume(returning: filePaths)
                    return
                }

                while let url = enumerator.nextObject() as? URL {
                    // Calculate relative path from repo root
                    let absolutePath = url.path
                    guard absolutePath.hasPrefix(basePath) else { continue }

                    var relativePath = String(absolutePath.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }

                    // Skip if empty
                    guard !relativePath.isEmpty else { continue }

                    // Check if this is a directory
                    var isDirectory: ObjCBool = false
                    fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory)

                    // Skip .git directory entirely
                    if relativePath == ".git" || relativePath.hasPrefix(".git/") {
                        if isDirectory.boolValue {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    // Check gitignore patterns
                    if FSEventsWrapper.shouldIgnorePath(relativePath, isDirectory: isDirectory.boolValue, patterns: patterns) {
                        if isDirectory.boolValue {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    // Skip if it's a directory (we only track files)
                    if isDirectory.boolValue {
                        continue
                    }

                    // Check static ignore patterns (fallback for common patterns)
                    let filename = url.lastPathComponent
                    if Self.shouldIgnoreFile(filename) {
                        continue
                    }

                    filePaths.insert(relativePath)
                }

                print("[FSEventsWrapper] Initial scan complete for \(basePath): found \(filePaths.count) files")
                continuation.resume(returning: filePaths)
            }
        }
    }

    /// Check if a path should be ignored based on gitignore patterns
    /// - Parameters:
    ///   - relativePath: Path relative to repository root
    ///   - isDirectory: Whether the path is a directory
    ///   - patterns: Gitignore patterns to check against
    /// - Returns: true if the path should be ignored
    private static func shouldIgnorePath(_ relativePath: String, isDirectory: Bool, patterns: [GitignorePattern]) -> Bool {
        var isIgnored = false

        for pattern in patterns {
            if pattern.matches(relativePath, isDirectory: isDirectory) {
                // Negation pattern - this file is NOT ignored
                if pattern.isNegation {
                    isIgnored = false
                } else {
                    isIgnored = true
                }
            }
        }

        return isIgnored
    }

    // MARK: - Private Methods

    private func createEventStream() {
        let pathsToWatch = [directoryPath] as CFArray
        let basePath = directoryPath
        let patterns = gitignorePatterns

        // Create context with self reference
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Create the event stream
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { (
                streamRef: ConstFSEventStreamRef,
                clientCallBackInfo: UnsafeMutableRawPointer?,
                numEvents: Int,
                eventPaths: UnsafeMutableRawPointer,
                eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                eventIds: UnsafePointer<FSEventStreamEventId>
            ) in
                guard let info = clientCallBackInfo else { return }
                let wrapper = Unmanaged<FSEventsWrapper>.fromOpaque(info).takeUnretainedValue()
                let basePath = wrapper.directoryPath
                let patterns = wrapper.gitignorePatterns

                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]

                var addedFiles: Set<String> = []
                var removedFiles: Set<String> = []

                for i in 0..<numEvents {
                    let absolutePath = paths[i]
                    let flags = eventFlags[i]
                    let event = FileEvent(path: absolutePath, flags: flags)

                    // Only process file events (not directories)
                    guard event.isFile else { continue }

                    // Calculate relative path from repo root
                    guard absolutePath.hasPrefix(basePath) else { continue }
                    var relativePath = String(absolutePath.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                    guard !relativePath.isEmpty else { continue }

                    // Skip .git directory
                    if relativePath.hasPrefix(".git/") || relativePath == ".git" {
                        continue
                    }

                    let filename = URL(fileURLWithPath: absolutePath).lastPathComponent

                    // Check gitignore patterns
                    if FSEventsWrapper.shouldIgnorePath(relativePath, isDirectory: false, patterns: patterns) {
                        continue
                    }

                    // Skip static ignore patterns (fallback)
                    guard !FSEventsWrapper.shouldIgnoreFile(filename) else {
                        continue
                    }

                    if event.isCreated || event.isRenamed {
                        // Check if file exists (renamed events fire for both old and new names)
                        if FileManager.default.fileExists(atPath: absolutePath) {
                            addedFiles.insert(relativePath)
                        } else {
                            removedFiles.insert(relativePath)
                        }
                    } else if event.isRemoved {
                        removedFiles.insert(relativePath)
                    }
                }

                // Dispatch to main queue for processing
                // Using DispatchQueue.main.async instead of Task for more predictable
                // synchronization with rapid FSEvents callbacks
                if !addedFiles.isEmpty || !removedFiles.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            wrapper.handleFileChanges(added: addedFiles, removed: removedFiles)
                        }
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // Latency in seconds
            flags
        ) else {
            print("FSEventsWrapper: Failed to create event stream for \(directoryPath)")
            return
        }

        eventStream = stream

        // Schedule on the main run loop
        FSEventStreamScheduleWithRunLoop(
            stream,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        FSEventStreamStart(stream)
    }

    private func handleFileChanges(added: Set<String>, removed: Set<String>) {
        // Batch changes using debouncing
        pendingAdditions.formUnion(added)
        pendingRemovals.formUnion(removed)

        // Cancel existing debounce
        debounceWorkItem?.cancel()

        // Schedule new debounce
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingChanges()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func flushPendingChanges() {
        // Remove items that were both added and removed (net zero)
        let netAdditions = pendingAdditions.subtracting(pendingRemovals)
        let netRemovals = pendingRemovals.subtracting(pendingAdditions)

        if !netAdditions.isEmpty {
            onFilesAdded?(netAdditions)
        }

        if !netRemovals.isEmpty {
            onFilesRemoved?(netRemovals)
        }

        pendingAdditions.removeAll()
        pendingRemovals.removeAll()
    }

    /// Check if a filename should be ignored (build artifacts, dependencies, etc.)
    private static func shouldIgnoreFile(_ filename: String) -> Bool {
        // Common patterns to ignore
        let ignoredPrefixes = [".", "_"]
        let ignoredSuffixes = [".o", ".a", ".dylib", ".dSYM", ".pyc", ".class"]
        let ignoredNames: Set<String> = [
            "package-lock.json", "yarn.lock", "Podfile.lock",
            "Pods", "node_modules", "build", "DerivedData",
            ".DS_Store", "Thumbs.db"
        ]

        // Check prefixes
        for prefix in ignoredPrefixes {
            if filename.hasPrefix(prefix) {
                return true
            }
        }

        // Check suffixes
        for suffix in ignoredSuffixes {
            if filename.hasSuffix(suffix) {
                return true
            }
        }

        // Check exact names
        return ignoredNames.contains(filename)
    }
}
