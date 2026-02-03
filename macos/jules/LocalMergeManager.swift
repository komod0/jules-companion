import AppKit
import Foundation
import CodeEditLanguages

@MainActor
class LocalMergeManager {
    // --- UserDefaults Keys ---
    private let localRepoPathsKey = "localRepoPathsKey"
    private let localRepoBookmarksKey = "localRepoBookmarksKey"

    init() {
        // Initialize FSEvents watchers for saved local repository paths
        initializeAutocompletePaths()
    }

    /// Initialize autocomplete FSEvents watchers for all saved local repository paths
    private func initializeAutocompletePaths() {
        let autocompleteManager = FilenameAutocompleteManager.shared

        // Get all saved paths
        guard let paths = UserDefaults.standard.dictionary(forKey: localRepoPathsKey) as? [String: String] else {
            return
        }

        for (source, path) in paths {
            // Verify the path still exists
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                autocompleteManager.registerRepository(repositoryId: source, localPath: path)
            }
        }
    }

    func mergeLocal(session: Session, sourceId: String, completion: ((Bool) -> Void)? = nil) {
        guard let diffs = session.latestDiffs, !diffs.isEmpty else {
            FlashMessageManager.shared.show(message: "No diffs found to merge.", type: .error)
            completion?(false)
            return
        }

        if let repoURL = getRepoURL(for: sourceId) {
            applyPatch(for: session, at: repoURL, sourceId: sourceId, completion: completion)
        } else {
            promptForRepoDirectory { [weak self] url in
                guard let self = self, let url = url else {
                    completion?(false)
                    return
                }
                self.saveRepoPath(url, for: sourceId)
                self.applyPatch(for: session, at: url, sourceId: sourceId, completion: completion)
            }
        }
    }

    private func saveRepoPath(_ url: URL, for source: String) {
        // Save bookmark for permission persistence
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = UserDefaults.standard.dictionary(forKey: localRepoBookmarksKey) as? [String: Data] ?? [:]
            bookmarks[source] = data
            UserDefaults.standard.set(bookmarks, forKey: localRepoBookmarksKey)
        } catch {
            print("Failed to create bookmark: \(error)")
        }

        // Save path string for legacy compatibility and easy display
        var paths = UserDefaults.standard.dictionary(forKey: localRepoPathsKey) as? [String: String] ?? [:]
        paths[source] = url.path
        UserDefaults.standard.set(paths, forKey: localRepoPathsKey)

        // Update autocomplete manager with the local path for FSEvents monitoring
        let autocompleteManager = FilenameAutocompleteManager.shared
        autocompleteManager.registerRepository(repositoryId: source, localPath: url.path)
    }

    private func getRepoURL(for source: String) -> URL? {
        // 1. Try to get from bookmark (preferred for permissions)
        if let bookmarks = UserDefaults.standard.dictionary(forKey: localRepoBookmarksKey) as? [String: Data],
           let data = bookmarks[source] {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale {
                    // We could try to re-save if we were inside a startAccessing block or had fresh permission,
                    // but usually we just use the resolved URL.
                }
                return url
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }

        // 2. Fallback to path string
        if let paths = UserDefaults.standard.dictionary(forKey: localRepoPathsKey) as? [String: String],
           let path = paths[source] {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func promptForRepoDirectory(completion: @escaping (URL?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select the root directory of your local repository"

        if openPanel.runModal() == .OK {
            completion(openPanel.url)
        } else {
            completion(nil)
        }
    }

    private func applyPatch(for session: Session, at repoURL: URL, sourceId: String? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let diffs = session.latestDiffs, !diffs.isEmpty else {
            completion?(false)
            return
        }

        // Access security scoped resource
        guard repoURL.startAccessingSecurityScopedResource() else {
            FlashMessageManager.shared.show(message: "Permission denied. Please re-select the repository folder.", type: .error)
            completion?(false)
            return
        }
        defer { repoURL.stopAccessingSecurityScopedResource() }

        let combinedPatch = diffs.map { $0.patch }.joined(separator: "\n")
        let patchEngine = PatchEngine()

        do {
            try patchEngine.apply(patch: combinedPatch, to: repoURL.path, checkOnly: false)
            // Session will be marked as merged by DataManager via completion callback
            // The button will update to show "Merged" with checkmark
            completion?(true)
        } catch {
            // Conflicts detected - open the MergeConflictController instead of showing flash message
            if #available(macOS 14.0, *) {
                openMergeConflictWindow(for: session, at: repoURL, diffs: diffs, sourceId: sourceId, completion: completion)
            } else {
                FlashMessageManager.shared.show(message: "Conflicts detected. macOS 14+ required for conflict resolution.", type: .error)
                completion?(false)
            }
        }
    }

    /// Opens the MergeConflictWindowManager with conflict data generated from the session's diffs
    @available(macOS 14.0, *)
    private func openMergeConflictWindow(
        for session: Session,
        at repoURL: URL,
        diffs: [(patch: String, language: String?, filename: String?)],
        sourceId: String?,
        completion: ((Bool) -> Void)?
    ) {
        // Generate conflict files from the diffs
        let conflictFiles = generateConflictFiles(from: diffs, at: repoURL)

        guard !conflictFiles.isEmpty else {
            FlashMessageManager.shared.show(message: "Could not generate conflict data.", type: .error)
            completion?(false)
            return
        }

        // Create the store with conflict data
        let store = MergeConflictStore()
        store.files = conflictFiles
        store.sessionId = session.id
        store.sourceId = sourceId
        store.repoPath = repoURL

        // Open the merge conflict window
        MergeConflictWindowManager.shared.openWindow(store: store) {
            // Merge completed successfully - the button will update to show "Merged" with checkmark
            completion?(true)
        }
    }

    /// Generates ConflictFile entries from diffs that have conflicts
    /// For files with conflicts, creates content with conflict markers
    private func generateConflictFiles(
        from diffs: [(patch: String, language: String?, filename: String?)],
        at repoURL: URL
    ) -> [ConflictFile] {
        var conflictFiles: [ConflictFile] = []
        let patchEngine = PatchEngine()

        for diff in diffs {
            // Check if this individual diff has a conflict
            do {
                try patchEngine.apply(patch: diff.patch, to: repoURL.path, checkOnly: true)
                // No conflict for this file, skip it
                continue
            } catch {
                // This file has conflicts - generate conflict content
            }

            guard let filename = diff.filename else {
                #if DEBUG
                print("[LocalMergeManager] Skipping conflict: diff has no filename")
                #endif
                continue
            }

            let filePath = repoURL.appendingPathComponent(filename)

            // Read current file content
            guard let currentContent = try? String(contentsOf: filePath, encoding: .utf8) else {
                #if DEBUG
                print("[LocalMergeManager] Skipping conflict for '\(filename)': file does not exist locally or cannot be read (possibly a new file)")
                #endif
                continue
            }

            // Parse the diff to get the incoming changes
            let parsed = LegacyPatchParser.parse(diff: diff.patch)
            guard let diffFile = parsed.files.first else {
                #if DEBUG
                print("[LocalMergeManager] Skipping conflict for '\(filename)': failed to parse diff")
                #endif
                continue
            }

            // Generate conflict content by attempting to merge with conflict markers
            var conflictContent = generateConflictContent(
                currentContent: currentContent,
                diffFile: diffFile
            )

            // Determine the language
            let language: CodeLanguage
            if let langStr = diff.language, !langStr.isEmpty {
                language = CodeLanguage.from(extension: langStr)
            } else {
                language = CodeLanguage.detectLanguageFrom(url: filePath)
            }

            // Expand conflict markers to syntactic boundaries using Tree-sitter LCA expansion
            // This ensures accepting either side produces syntactically valid code
            let expander = ConflictMarkerExpander()
            conflictContent = expander.expandConflicts(in: conflictContent, language: language)

            // Parse conflicts from the generated content
            let conflicts = parseConflicts(in: conflictContent)

            // Only add if there are actual conflicts
            if !conflicts.isEmpty {
                let conflictFile = ConflictFile(
                    id: UUID(),
                    name: (filename as NSString).lastPathComponent,
                    path: filename,
                    language: language,
                    content: conflictContent,
                    conflicts: conflicts,
                    resolvedConflicts: []
                )
                conflictFiles.append(conflictFile)
            } else {
                #if DEBUG
                print("[LocalMergeManager] Skipping conflict for '\(filename)': no conflict markers generated after processing")
                #endif
            }
        }

        return conflictFiles
    }

    /// Generates content with conflict markers by comparing current content with diff changes
    /// Creates minimal conflict markers around only the actual changed lines (removes/adds),
    /// not including context lines which should remain outside the conflict markers.
    private func generateConflictContent(currentContent: String, diffFile: LegacyDiffFile) -> String {
        let currentLines = currentContent.components(separatedBy: "\n")
        var resultLines: [String] = []
        var currentIdx = 0  // 0-based index in currentLines

        for hunk in diffFile.hunks {
            // Parse the hunk header to get the starting line
            let header = hunk.header
            let components = header.split(separator: " ")
            guard components.count >= 2 else { continue }

            let oldSpec = components[1].dropFirst() // Remove the "-" prefix
            let oldStartStr = oldSpec.split(separator: ",")[0]
            guard let oldStart = Int(oldStartStr) else { continue }

            // oldStart is 1-based, convert to 0-based
            let targetIdx = max(0, oldStart - 1)

            // Copy lines before this hunk
            while currentIdx < targetIdx && currentIdx < currentLines.count {
                resultLines.append(currentLines[currentIdx])
                currentIdx += 1
            }

            // Check if this hunk can be applied cleanly
            let canApply = canApplyHunk(hunk: hunk, lines: currentLines, startIdx: currentIdx)

            if canApply {
                // Apply the hunk cleanly
                for line in hunk.lines {
                    switch line.type {
                    case .context:
                        if currentIdx < currentLines.count {
                            resultLines.append(currentLines[currentIdx])
                            currentIdx += 1
                        }
                    case .add:
                        resultLines.append(line.content)
                    case .remove:
                        if currentIdx < currentLines.count {
                            currentIdx += 1
                        }
                    }
                }
            } else {
                // Generate minimal conflict markers - only wrap actual changes, not context
                // Process hunk lines and create conflict markers around change blocks
                generateMinimalConflictMarkers(
                    hunkLines: hunk.lines,
                    currentLines: currentLines,
                    currentIdx: &currentIdx,
                    resultLines: &resultLines
                )
            }
        }

        // Copy remaining lines
        while currentIdx < currentLines.count {
            resultLines.append(currentLines[currentIdx])
            currentIdx += 1
        }

        return resultLines.joined(separator: "\n")
    }

    /// Generates minimal conflict markers by wrapping only the actual changed lines.
    /// Context lines are output normally, and only contiguous blocks of removes/adds are wrapped.
    private func generateMinimalConflictMarkers(
        hunkLines: [LegacyDiffLine],
        currentLines: [String],
        currentIdx: inout Int,
        resultLines: inout [String]
    ) {
        var i = 0

        while i < hunkLines.count {
            let line = hunkLines[i]

            switch line.type {
            case .context:
                // Try to match context with current content
                // If it matches, output normally; if not, we may need to search for it
                if currentIdx < currentLines.count {
                    // Output the current line (whether it matches or not, we advance)
                    resultLines.append(currentLines[currentIdx])
                    currentIdx += 1
                }
                i += 1

            case .remove, .add:
                // Found start of a change block - collect all contiguous removes and adds
                var removes: [LegacyDiffLine] = []
                var adds: [LegacyDiffLine] = []

                // Collect contiguous changes (removes followed by adds, or just removes, or just adds)
                while i < hunkLines.count && hunkLines[i].type != .context {
                    if hunkLines[i].type == .remove {
                        removes.append(hunkLines[i])
                    } else if hunkLines[i].type == .add {
                        adds.append(hunkLines[i])
                    }
                    i += 1
                }

                // Now output the conflict marker with just the changed lines
                resultLines.append("<<<<<<< Current (Local)")

                // Current side: what's in the file (use actual current lines for the remove count)
                for _ in removes {
                    if currentIdx < currentLines.count {
                        resultLines.append(currentLines[currentIdx])
                        currentIdx += 1
                    }
                }

                resultLines.append("=======")

                // Incoming side: what the patch wants to add
                for addLine in adds {
                    resultLines.append(addLine.content)
                }

                resultLines.append(">>>>>>> Incoming (Remote)")
            }
        }
    }

    /// Checks if a hunk can be applied cleanly by verifying context lines match
    private func canApplyHunk(hunk: LegacyDiffHunk, lines: [String], startIdx: Int) -> Bool {
        var idx = startIdx

        for line in hunk.lines {
            switch line.type {
            case .context:
                if idx >= lines.count { return false }
                if lines[idx] != line.content { return false }
                idx += 1
            case .remove:
                if idx >= lines.count { return false }
                if lines[idx] != line.content { return false }
                idx += 1
            case .add:
                // Added lines don't need to match anything
                break
            }
        }

        return true
    }

    /// Parse conflicts from text content (duplicated from MergeConflictStore for use here)
    private func parseConflicts(in text: String) -> [FileConflict] {
        let pattern = "(<<<<<<<[^\\n]*\\n)(.*?)((=======)[^\\n]*\\n)(.*?)((>>>>>>>)[^\\n]*(?:\\n|$))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result: [FileConflict] = []
        var currentLineIndex = 0
        var lastLocation = 0

        for match in matches {
            if match.numberOfRanges >= 7 {
                let fullRange = match.range
                let startMarker = match.range(at: 1)
                let ours = match.range(at: 2)
                let midMarker = match.range(at: 3)
                let theirs = match.range(at: 5)
                let endMarker = match.range(at: 6)

                let oursContent = nsString.substring(with: ours)
                let theirsContent = nsString.substring(with: theirs)

                // Count lines to start
                let toStart = nsString.substring(with: NSRange(location: lastLocation, length: startMarker.location - lastLocation))
                let linesToStart = toStart.filter { $0 == "\n" }.count
                currentLineIndex += linesToStart

                let startLine = currentLineIndex

                // Count lines in Current block
                let currentBlockLen = midMarker.location - startMarker.location
                let currentBlockStr = nsString.substring(with: NSRange(location: startMarker.location, length: currentBlockLen))
                let linesInCurrent = currentBlockStr.filter { $0 == "\n" }.count
                let midLine = startLine + linesInCurrent

                // Count lines in Incoming block
                let incomingBlockLen = endMarker.location + endMarker.length - midMarker.location
                let incomingBlockStr = nsString.substring(with: NSRange(location: midMarker.location, length: incomingBlockLen))
                let linesInIncoming = incomingBlockStr.filter { $0 == "\n" }.count
                let endLine = midLine + linesInIncoming

                // Update pointers
                currentLineIndex = endLine
                lastLocation = match.range.location + match.range.length

                result.append(FileConflict(
                    id: UUID(),
                    range: fullRange,
                    oursRange: ours,
                    theirsRange: theirs,
                    oursContent: oursContent,
                    theirsContent: theirsContent,
                    startLineIndex: startLine,
                    midLineIndex: midLine,
                    endLineIndex: endLine
                ))
            }
        }

        return result
    }

    /// Check if a patch can be applied without conflicts (dry-run)
    /// Returns true if patch can be applied cleanly, false if there are conflicts
    func canApplyPatch(session: Session, sourceId: String) -> Bool {
        guard let diffs = session.latestDiffs, !diffs.isEmpty else {
            return false
        }

        guard let repoURL = getRepoURL(for: sourceId) else {
            // No repo configured yet, we can't check for conflicts
            return true // Optimistically assume no conflicts
        }

        guard repoURL.startAccessingSecurityScopedResource() else {
            return true // Optimistically assume no conflicts if we can't access
        }
        defer { repoURL.stopAccessingSecurityScopedResource() }

        let combinedPatch = diffs.map { $0.patch }.joined(separator: "\n")
        let patchEngine = PatchEngine()

        do {
            try patchEngine.apply(patch: combinedPatch, to: repoURL.path, checkOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Count the number of files with conflicts by checking each file individually
    /// Returns the number of files that would have conflicts when applying the patch
    /// Returns nil if no repo is configured (optimistically assume no conflicts)
    /// Note: This uses the same logic as generateConflictFiles() to ensure consistency
    func countConflicts(session: Session, sourceId: String) -> Int? {
        guard let diffs = session.latestDiffs, !diffs.isEmpty else {
            return 0
        }

        guard let repoURL = getRepoURL(for: sourceId) else {
            // No repo configured yet, we can't check for conflicts
            return nil
        }

        guard repoURL.startAccessingSecurityScopedResource() else {
            return nil // Can't access, return nil to indicate unknown
        }
        defer { repoURL.stopAccessingSecurityScopedResource() }

        let patchEngine = PatchEngine()
        var conflictCount = 0

        // Check each file's patch individually, using same criteria as generateConflictFiles()
        for diff in diffs {
            do {
                try patchEngine.apply(patch: diff.patch, to: repoURL.path, checkOnly: true)
                // This file can be applied cleanly
                continue
            } catch {
                // This file has conflicts - but only count if it would be displayable
            }

            // Must have a filename
            guard let filename = diff.filename else {
                #if DEBUG
                print("[LocalMergeManager] countConflicts: skipping diff with no filename")
                #endif
                continue
            }

            // File must exist locally and be readable
            let filePath = repoURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: filePath.path) else {
                #if DEBUG
                print("[LocalMergeManager] countConflicts: skipping '\(filename)' - file does not exist locally")
                #endif
                continue
            }

            // Diff must be parseable
            let parsed = LegacyPatchParser.parse(diff: diff.patch)
            guard parsed.files.first != nil else {
                #if DEBUG
                print("[LocalMergeManager] countConflicts: skipping '\(filename)' - failed to parse diff")
                #endif
                continue
            }

            conflictCount += 1
        }

        return conflictCount
    }
}
