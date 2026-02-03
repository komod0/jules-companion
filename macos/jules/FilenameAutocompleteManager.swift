import Foundation
import Combine

/// Singleton manager for file path autocomplete functionality.
/// Coordinates FSEvents watchers and filename caches across multiple repositories.
/// Handles initial file system scans and persistent storage of file paths.
@MainActor
final class FilenameAutocompleteManager: ObservableObject {

    // MARK: - Singleton

    static let shared = FilenameAutocompleteManager()

    // MARK: - Configuration

    /// Enable debug logging for autocomplete operations
    static var debugLoggingEnabled = false

    /// When true, autocomplete suggestions only appear on Tab key press, not during typing
    static var tabOnlyTrigger = true

    // MARK: - Cursor Positioning

    /// Pending cursor position to set after text replacement from autocomplete.
    /// SimpleTextEditor checks this and positions the cursor accordingly.
    var pendingCursorPosition: Int?

    /// Word range when autocomplete was triggered. Used by menu selection to
    /// replace the correct word when clicking on a suggestion.
    var pendingWordRange: NSRange?

    // MARK: - Owner Tracking

    /// Identifier for the text input that owns the current autocomplete session.
    /// Used to prevent one text input from accepting suggestions triggered by another.
    /// When a text input triggers autocomplete, it sets this to its ObjectIdentifier.
    /// When accepting a selection, the text input must match this owner or the selection is ignored.
    private(set) var currentOwnerId: ObjectIdentifier?

    /// String identifier for the view that owns the current autocomplete session.
    /// Used by FilenameAutocompleteMenuView to decide whether to show suggestions.
    /// Each view (NewTaskFormView, UnifiedMessageInputView) sets a unique ID when triggering autocomplete.
    @Published private(set) var currentViewOwnerId: String?

    /// Publisher for when initial scan completes for any repository
    let initialScanCompletedPublisher = PassthroughSubject<String, Never>()

    // MARK: - Debouncing

    /// Work item for debounced autocomplete updates
    private var autocompleteWorkItem: DispatchWorkItem?

    /// Debounce interval for autocomplete updates (100ms reduces stuttering during rapid typing)
    private let autocompleteDebounceInterval: TimeInterval = 0.1

    // MARK: - Types

    /// Autocomplete suggestion with match information
    struct AutocompleteSuggestion: Identifiable, Hashable {
        let id = UUID()
        let filePath: String           // Full relative path (e.g., "src/components/Button.swift")
        let filename: String           // Just the filename (e.g., "Button.swift")
        let matchedPrefix: String

        init(filePath: String, matchedPrefix: String) {
            self.filePath = filePath
            self.filename = URL(fileURLWithPath: filePath).lastPathComponent
            self.matchedPrefix = matchedPrefix
        }

        /// The highlighted range in the filename (0-based)
        var highlightRange: Range<String.Index> {
            let endIndex = filename.index(
                filename.startIndex,
                offsetBy: min(matchedPrefix.count, filename.count)
            )
            return filename.startIndex..<endIndex
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(filePath)
        }

        static func == (lhs: AutocompleteSuggestion, rhs: AutocompleteSuggestion) -> Bool {
            return lhs.filePath == rhs.filePath
        }
    }

    // MARK: - Properties

    /// Caches for each repository (keyed by repository ID)
    private var caches: [String: FilenameCache] = [:]

    /// FSEvents watchers for each repository (keyed by repository ID)
    private var watchers: [String: FSEventsWrapper] = [:]

    /// Currently active repository ID for autocomplete
    @Published private(set) var activeRepositoryId: String?

    /// Current autocomplete suggestions
    @Published private(set) var suggestions: [AutocompleteSuggestion] = []

    /// Whether autocomplete is currently active
    @Published var isAutocompleteActive: Bool = false

    /// The current search prefix
    @Published private(set) var currentPrefix: String = ""

    /// Selected suggestion index (for keyboard navigation)
    @Published var selectedIndex: Int = 0

    /// Maximum number of suggestions to show
    let maxSuggestions = 3

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {}

    // MARK: - Logging

    /// Log a debug message if debug logging is enabled
    private func log(_ message: String) {
        if FilenameAutocompleteManager.debugLoggingEnabled {
            print("[Autocomplete] \(message)")
        }
    }

    // MARK: - Repository Management

    /// Register a repository for file path tracking
    /// - Parameters:
    ///   - repositoryId: The unique identifier for the repository
    ///   - localPath: Optional local file system path for FSEvents monitoring
    func registerRepository(repositoryId: String, localPath: String? = nil) {
        log("registerRepository: \(repositoryId), localPath: \(localPath ?? "nil")")

        // Create cache if it doesn't exist
        if caches[repositoryId] == nil {
            caches[repositoryId] = FilenameCache(repositoryId: repositoryId, localRepoPath: localPath)
            log("Created new cache for: \(repositoryId)")
        } else if let path = localPath {
            // Update existing cache with local path
            caches[repositoryId]?.setLocalRepoPath(path)
            log("Updated local path for existing cache: \(repositoryId)")
        }

        // Setup FSEvents watcher if local path is provided
        if let path = localPath {
            setupWatcher(for: repositoryId, at: path)
        } else {
            log("No local path provided - FSEvents not started for: \(repositoryId)")
        }
    }

    /// Unregister a repository and clean up resources
    func unregisterRepository(repositoryId: String) {
        // Stop and remove watcher
        watchers[repositoryId]?.stopWatching()
        watchers.removeValue(forKey: repositoryId)

        // Clear persisted cache
        caches[repositoryId]?.clearPersistedCache()

        // Remove cache
        caches.removeValue(forKey: repositoryId)

        // Clear active state if this was the active repo
        if activeRepositoryId == repositoryId {
            activeRepositoryId = nil
            clearSuggestions()
        }
    }

    /// Stop all FSEvents watchers to reduce resource usage (e.g., in menubar-only mode)
    /// The caches are preserved so autocomplete still works with cached data.
    /// Call `resumeAllWatchers()` to restart watching when needed.
    func stopAllWatchers() {
        log("Stopping all FSEvents watchers (\(watchers.count) active)")
        for (repositoryId, watcher) in watchers {
            watcher.stopWatching()
            log("Stopped watcher for: \(repositoryId)")
        }
        // Keep watchers dictionary intact so we can resume them later
    }

    /// Resume all FSEvents watchers that were previously stopped
    /// Re-registers watchers for repositories that have local paths configured.
    func resumeAllWatchers() {
        log("Resuming FSEvents watchers")
        for (repositoryId, _) in watchers {
            if let cache = caches[repositoryId], let localPath = cache.localRepoPath {
                setupWatcher(for: repositoryId, at: localPath)
            }
        }
    }

    /// Set the active repository for autocomplete
    func setActiveRepository(_ repositoryId: String?) {
        log("setActiveRepository: \(repositoryId ?? "nil")")
        activeRepositoryId = repositoryId
        clearSuggestions()

        // Log cache state for debugging
        if let repoId = repositoryId, let cache = caches[repoId] {
            log("Cache for \(repoId) has \(cache.count) files")
        }
    }

    /// Update the local path for a repository (e.g., when user selects a folder)
    func updateLocalPath(for repositoryId: String, path: String) {
        // Stop existing watcher if any
        watchers[repositoryId]?.stopWatching()

        // Update cache with new path and clear old filesystem entries
        if let cache = caches[repositoryId] {
            cache.setLocalRepoPath(path)
            cache.clear(source: .localFileSystem)
        }

        // Setup new watcher (this will trigger a new initial scan)
        setupWatcher(for: repositoryId, at: path)
    }

    /// Force a rescan of the repository file system
    func rescanRepository(_ repositoryId: String) {
        guard let cache = caches[repositoryId],
              let watcher = watchers[repositoryId] else { return }

        // Clear existing filesystem entries
        cache.clear(source: .localFileSystem)

        // Perform new scan
        Task {
            let filePaths = await watcher.performInitialScan()
            cache.addFromFileSystem(filePaths)
            cache.markInitialScanComplete()
            initialScanCompletedPublisher.send(repositoryId)
        }
    }

    // MARK: - Cache Management

    /// Get the cache for a specific repository
    func getCache(for repositoryId: String) -> FilenameCache? {
        return caches[repositoryId]
    }

    /// Add filenames from a diff patch to a repository's cache
    /// - Parameters:
    ///   - patch: The unified diff patch string
    ///   - repositoryId: The repository to add filenames to
    func addFilenamesFromPatch(_ patch: String, for repositoryId: String) {
        guard let cache = caches[repositoryId] else {
            // Create cache if it doesn't exist
            let newCache = FilenameCache(repositoryId: repositoryId)
            caches[repositoryId] = newCache
            newCache.extractAndCacheFromPatch(patch)
            return
        }

        cache.extractAndCacheFromPatch(patch)
    }

    /// Add filenames from multiple patches (e.g., from session diffs)
    func addFilenamesFromPatches(_ patches: [(patch: String, language: String?, filename: String?)], for repositoryId: String) {
        guard !patches.isEmpty else { return }

        // Ensure cache exists
        if caches[repositoryId] == nil {
            caches[repositoryId] = FilenameCache(repositoryId: repositoryId)
        }

        guard let cache = caches[repositoryId] else { return }

        // Extract filenames from each patch
        var allFilenames: Set<String> = []

        for patchInfo in patches {
            // Add the explicit filename/path if provided
            // Store the full path, not just the filename, since findMatches returns full paths
            if let filename = patchInfo.filename, !filename.isEmpty, filename != "/dev/null" {
                allFilenames.insert(filename)
            }

            // Also extract from patch content
            let extractedFilenames = FilenameCache.extractFilenamesFromPatch(patchInfo.patch)
            allFilenames.formUnion(extractedFilenames)
        }

        cache.addFromDiffPatch(allFilenames)
    }

    // MARK: - Autocomplete

    /// Update autocomplete suggestions based on the current prefix
    /// - Parameter prefix: The text prefix to match
    /// Debounced to reduce UI stuttering during rapid typing
    func updateSuggestions(for prefix: String) {
        // Cancel any pending autocomplete work
        autocompleteWorkItem?.cancel()

        // Update current prefix immediately for UI feedback
        currentPrefix = prefix

        guard !prefix.isEmpty else {
            clearSuggestions()
            return
        }

        guard let repositoryId = activeRepositoryId else {
            clearSuggestions()
            return
        }

        guard let cache = caches[repositoryId] else {
            clearSuggestions()
            return
        }

        // Debounce the actual search to reduce stuttering during rapid typing
        let workItem = DispatchWorkItem { [weak self, weak cache] in
            guard let self = self, let cache = cache else { return }

            // Perform matching on a background thread for better performance
            Task.detached(priority: .userInitiated) {
                let matches = await cache.findMatchesAsync(prefix: prefix, limit: self.maxSuggestions)

                // Update UI on main thread
                await MainActor.run {
                    guard self.currentPrefix == prefix else {
                        // Prefix changed while we were searching, discard results
                        return
                    }

                    if matches.isEmpty {
                        self.clearSuggestions()
                        return
                    }

                    self.suggestions = matches.map { filePath in
                        AutocompleteSuggestion(filePath: filePath, matchedPrefix: prefix)
                    }

                    self.selectedIndex = 0
                    self.isAutocompleteActive = true
                }
            }
        }

        autocompleteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autocompleteDebounceInterval, execute: workItem)
    }

    /// Clear current suggestions
    func clearSuggestions() {
        // Cancel any pending autocomplete work to prevent stale updates
        autocompleteWorkItem?.cancel()
        autocompleteWorkItem = nil

        suggestions = []
        selectedIndex = 0
        isAutocompleteActive = false
        currentPrefix = ""
        pendingWordRange = nil
        currentOwnerId = nil
        currentViewOwnerId = nil
    }

    // MARK: - Owner Management

    /// Sets the owner of the current autocomplete session.
    /// Call this when triggering autocomplete from a text input.
    /// If a different owner already has an active session, it will be cleared first.
    /// - Parameter ownerId: ObjectIdentifier of the text input claiming ownership
    func setOwner(_ ownerId: ObjectIdentifier) {
        if currentOwnerId != ownerId && isAutocompleteActive {
            // Different text input is claiming ownership - clear stale session
            clearSuggestions()
        }
        currentOwnerId = ownerId
    }

    /// Sets the view owner ID for the current autocomplete session.
    /// Call this when triggering autocomplete from a view so the correct menu shows.
    /// - Parameter viewOwnerId: String identifier for the view (e.g., "NewTaskFormView", "UnifiedMessageInputView-sessionId")
    func setViewOwner(_ viewOwnerId: String) {
        if currentViewOwnerId != viewOwnerId && isAutocompleteActive {
            // Different view is claiming ownership - clear stale session
            clearSuggestions()
        }
        currentViewOwnerId = viewOwnerId
    }

    /// Checks if the given owner ID matches the current autocomplete session owner.
    /// - Parameter ownerId: ObjectIdentifier to check
    /// - Returns: true if the owner matches or there's no current owner
    func isOwner(_ ownerId: ObjectIdentifier) -> Bool {
        return currentOwnerId == nil || currentOwnerId == ownerId
    }

    /// Checks if the given view owner ID matches the current autocomplete session.
    /// - Parameter viewOwnerId: String identifier to check
    /// - Returns: true if the view owner matches or there's no current owner
    func isViewOwner(_ viewOwnerId: String) -> Bool {
        return currentViewOwnerId == nil || currentViewOwnerId == viewOwnerId
    }

    /// Get the currently selected suggestion
    var selectedSuggestion: AutocompleteSuggestion? {
        guard isAutocompleteActive,
              selectedIndex >= 0,
              selectedIndex < suggestions.count else {
            return nil
        }
        return suggestions[selectedIndex]
    }

    /// Move selection up
    func selectPrevious() {
        guard isAutocompleteActive, !suggestions.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    /// Move selection down
    func selectNext() {
        guard isAutocompleteActive, !suggestions.isEmpty else { return }
        selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
    }

    /// Accept the current selection
    /// - Returns: The accepted full file path, or nil if no selection
    func acceptSelection() -> String? {
        guard let suggestion = selectedSuggestion else { return nil }
        let filePath = suggestion.filePath
        clearSuggestions()
        return filePath
    }

    /// Accept the current selection, verifying ownership first.
    /// - Parameter ownerId: ObjectIdentifier of the text input trying to accept
    /// - Returns: The accepted full file path, or nil if no selection or not the owner
    func acceptSelection(ownerId: ObjectIdentifier) -> String? {
        // Verify this text input owns the current autocomplete session
        guard isOwner(ownerId) else {
            log("acceptSelection rejected: owner mismatch")
            return nil
        }
        return acceptSelection()
    }

    /// Accept a specific suggestion by index
    /// - Parameter index: The index of the suggestion to accept
    /// - Returns: The accepted full file path, or nil if index is invalid
    func acceptSuggestion(at index: Int) -> String? {
        guard index >= 0, index < suggestions.count else { return nil }
        let filePath = suggestions[index].filePath
        clearSuggestions()
        return filePath
    }

    /// Accept the current selection but return just the filename
    /// - Returns: The accepted filename only (not full path), or nil if no selection
    func acceptSelectionFilenameOnly() -> String? {
        guard let suggestion = selectedSuggestion else { return nil }
        let filename = suggestion.filename
        clearSuggestions()
        return filename
    }

    // MARK: - Private Methods

    private func setupWatcher(for repositoryId: String, at path: String) {
        log("setupWatcher: repo=\(repositoryId), path=\(path)")

        // Verify path exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            log("Invalid path for repository \(repositoryId): \(path)")
            return
        }

        log("Starting FSEvents watcher for \(repositoryId)")
        let watcher = FSEventsWrapper(directoryPath: path, identifier: repositoryId)
        watchers[repositoryId] = watcher

        // Ensure cache exists with local path
        if caches[repositoryId] == nil {
            caches[repositoryId] = FilenameCache(repositoryId: repositoryId, localRepoPath: path)
        } else {
            caches[repositoryId]?.setLocalRepoPath(path)
        }

        guard let cache = caches[repositoryId] else { return }

        // Move heavy initialization work to background to avoid blocking UI
        Task { [weak self, weak cache, weak watcher] in
            guard let self = self, let cache = cache, let watcher = watcher else { return }

            // Load gitignore asynchronously (file I/O + regex compilation)
            await watcher.loadGitignoreAsync()

            // Start watching for file changes (now that gitignore patterns are loaded)
            watcher.startWatching(
                onFilesAdded: { [weak cache] filePaths in
                    cache?.addFromFileSystem(filePaths)
                },
                onFilesRemoved: { [weak cache] filePaths in
                    cache?.removeFromFileSystem(filePaths)
                }
            )

            // Only perform initial scan if we haven't already done one (from persisted data)
            // This ensures we populate the cache on first launch but don't re-scan every time
            if !cache.hasPerformedInitialScan || cache.count == 0 {
                self.log("Performing initial scan for \(repositoryId)")
                let initialFilePaths = await watcher.performInitialScan()
                self.log("Initial scan for \(repositoryId) found \(initialFilePaths.count) files")
                cache.addFromFileSystem(initialFilePaths)
                cache.markInitialScanComplete()
                self.log("Cache for \(repositoryId) now has \(cache.count) files")
                self.initialScanCompletedPublisher.send(repositoryId)
            } else {
                self.log("Skipping initial scan - cache already has \(cache.count) files for \(repositoryId)")
            }
        }
    }
}

// MARK: - Convenience Extensions

extension FilenameAutocompleteManager {
    /// Check if there's exactly one match (for immediate autocomplete)
    var hasSingleMatch: Bool {
        return suggestions.count == 1
    }

    /// Check if there are multiple matches (need to show menu)
    var hasMultipleMatches: Bool {
        return suggestions.count > 1
    }

    /// Get the single match file path if there's exactly one
    var singleMatch: String? {
        guard hasSingleMatch else { return nil }
        return suggestions.first?.filePath
    }

    /// Get the single match filename only if there's exactly one
    var singleMatchFilename: String? {
        guard hasSingleMatch else { return nil }
        return suggestions.first?.filename
    }

    /// Check if a repository has cached file paths
    func hasFilePaths(for repositoryId: String) -> Bool {
        return (caches[repositoryId]?.count ?? 0) > 0
    }

    /// Get the file path count for a repository
    func filePathCount(for repositoryId: String) -> Int {
        return caches[repositoryId]?.count ?? 0
    }
}
