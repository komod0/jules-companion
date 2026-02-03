//
//  MergeConflictStore.swift
//  jules
//
//  State management for merge conflict resolution across multiple files
//

import SwiftUI
import Combine
import CodeEditLanguages

// MARK: - Conflict File Model

/// Represents a file with merge conflicts
struct ConflictFile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let language: CodeLanguage
    var content: String
    var conflicts: [FileConflict]
    var resolvedConflicts: Set<UUID> // Track which conflicts have been resolved

    var unresolvedConflictCount: Int {
        conflicts.count - resolvedConflicts.count
    }

    var hasUnresolvedConflicts: Bool {
        unresolvedConflictCount > 0
    }

    static func == (lhs: ConflictFile, rhs: ConflictFile) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.resolvedConflicts == rhs.resolvedConflicts
    }
}

// MARK: - File Conflict Model

/// Represents a single conflict within a file
struct FileConflict: Identifiable, Equatable {
    let id: UUID
    let range: NSRange
    let oursRange: NSRange
    let theirsRange: NSRange
    let oursContent: String
    let theirsContent: String
    let startLineIndex: Int
    let midLineIndex: Int
    let endLineIndex: Int
    var resolution: ConflictResolutionChoice?

    var isResolved: Bool {
        resolution != nil
    }
}

// MARK: - Resolution Choice

enum ConflictResolutionChoice: Equatable {
    case current
    case incoming
    case both
}

// MARK: - Merge Conflict Store

/// Central state management for the merge conflict window
@MainActor
class MergeConflictStore: ObservableObject {
    // MARK: - Published State

    /// All files with conflicts
    @Published var files: [ConflictFile] = []

    /// Currently selected file index
    @Published var selectedFileIndex: Int = 0

    /// Currently focused conflict index (global across all files)
    @Published var currentConflictIndex: Int = 0

    /// Whether the merge operation is in progress
    @Published var isMerging: Bool = false

    /// Callback when merge is completed
    var onMergeComplete: (() -> Void)?

    /// Callback when window should close
    var onClose: (() -> Void)?

    /// Session ID if this merge is associated with a session (for tracking and callbacks)
    var sessionId: String?

    /// Source ID for the merge (for tracking and callbacks)
    var sourceId: String?

    /// Repository root path for writing resolved files (set by caller)
    var repoPath: URL?

    // MARK: - Computed Properties

    /// The currently selected file
    var selectedFile: ConflictFile? {
        guard selectedFileIndex >= 0 && selectedFileIndex < files.count else { return nil }
        return files[selectedFileIndex]
    }

    /// Total number of unresolved conflicts across all files
    var totalUnresolvedConflicts: Int {
        files.reduce(0) { $0 + $1.unresolvedConflictCount }
    }

    /// Total number of conflicts across all files
    var totalConflicts: Int {
        files.reduce(0) { $0 + $1.conflicts.count }
    }

    /// Whether all conflicts have been resolved
    var allConflictsResolved: Bool {
        totalUnresolvedConflicts == 0
    }

    /// Flat list of all conflicts with their file indices for pagination
    var allConflicts: [(fileIndex: Int, conflictIndex: Int, conflict: FileConflict)] {
        var result: [(fileIndex: Int, conflictIndex: Int, conflict: FileConflict)] = []
        for (fileIndex, file) in files.enumerated() {
            for (conflictIndex, conflict) in file.conflicts.enumerated() {
                result.append((fileIndex, conflictIndex, conflict))
            }
        }
        return result
    }

    /// Current conflict being viewed (for pagination)
    var currentConflict: (fileIndex: Int, conflictIndex: Int, conflict: FileConflict)? {
        let all = allConflicts
        guard currentConflictIndex >= 0 && currentConflictIndex < all.count else { return nil }
        return all[currentConflictIndex]
    }

    /// Whether there is a previous conflict to navigate to
    var hasPreviousConflict: Bool {
        currentConflictIndex > 0
    }

    /// Whether there is a next conflict to navigate to
    var hasNextConflict: Bool {
        currentConflictIndex < allConflicts.count - 1
    }

    // MARK: - Initialization

    init() {}

    /// Initialize with test data for development
    func loadTestData() {
        files = [
            createTestFile(
                name: "User.swift",
                path: "Sources/Models/User.swift",
                language: .swift,
                content: MergeConflictTestData.sampleConflictText
            ),
            createTestFile(
                name: "UserService.swift",
                path: "Sources/Services/UserService.swift",
                language: .swift,
                content: MergeConflictTestData.sampleConflictText2
            ),
            createTestFile(
                name: "config.json",
                path: "config.json",
                language: .json,
                content: MergeConflictTestData.jsonConflictText
            )
        ]
    }

    private func createTestFile(name: String, path: String, language: CodeLanguage, content: String) -> ConflictFile {
        let conflicts = parseConflicts(in: content)
        return ConflictFile(
            id: UUID(),
            name: name,
            path: path,
            language: language,
            content: content,
            conflicts: conflicts,
            resolvedConflicts: []
        )
    }

    // MARK: - Navigation

    /// Navigate to the previous conflict
    func goToPreviousConflict() {
        guard hasPreviousConflict else { return }
        currentConflictIndex -= 1
        updateSelectedFileFromCurrentConflict()
    }

    /// Navigate to the next conflict
    func goToNextConflict() {
        guard hasNextConflict else { return }
        currentConflictIndex += 1
        updateSelectedFileFromCurrentConflict()
    }

    /// Update selected file based on current conflict
    private func updateSelectedFileFromCurrentConflict() {
        if let current = currentConflict {
            selectedFileIndex = current.fileIndex
        }
    }

    /// Select a specific file
    func selectFile(at index: Int) {
        guard index >= 0 && index < files.count else { return }
        selectedFileIndex = index

        // Update current conflict index to the first conflict in this file
        var conflictOffset = 0
        for i in 0..<index {
            conflictOffset += files[i].conflicts.count
        }
        if files[index].conflicts.count > 0 {
            currentConflictIndex = conflictOffset
        }
    }

    // MARK: - Conflict Resolution

    /// Resolve a conflict with the given choice
    func resolveConflict(fileIndex: Int, conflictId: UUID, choice: ConflictResolutionChoice) {
        guard fileIndex >= 0 && fileIndex < files.count else { return }

        var file = files[fileIndex]
        guard let conflictIndex = file.conflicts.firstIndex(where: { $0.id == conflictId }) else { return }

        let conflict = file.conflicts[conflictIndex]

        // Get the content to use based on choice
        let resolvedContent: String
        switch choice {
        case .current:
            resolvedContent = conflict.oursContent
        case .incoming:
            resolvedContent = conflict.theirsContent
        case .both:
            // Combine both: current content followed by incoming content
            resolvedContent = conflict.oursContent + conflict.theirsContent
        }

        // Replace the conflict markers with the resolved content
        let nsContent = file.content as NSString
        if conflict.range.upperBound <= nsContent.length {
            file.content = nsContent.replacingCharacters(in: conflict.range, with: resolvedContent)
        }

        // Mark as resolved
        file.resolvedConflicts.insert(conflictId)

        // Update the conflict with resolution
        file.conflicts[conflictIndex].resolution = choice

        // Re-parse conflicts in the updated content
        let newConflicts = parseConflicts(in: file.content)
        file.conflicts = newConflicts
        file.resolvedConflicts = [] // Reset since conflicts are re-parsed

        files[fileIndex] = file

        // Stay on current file - don't automatically navigate to next file
        // Just update the currentConflictIndex to stay within this file's conflicts
        updateCurrentConflictIndexForFile(fileIndex)
    }

    /// Update file content (for direct editing)
    func updateFileContent(at fileIndex: Int, content: String) {
        guard fileIndex >= 0 && fileIndex < files.count else { return }

        var file = files[fileIndex]
        file.content = content

        // Re-parse conflicts
        file.conflicts = parseConflicts(in: content)
        file.resolvedConflicts = []

        files[fileIndex] = file
    }

    /// Update currentConflictIndex to stay within the given file
    private func updateCurrentConflictIndexForFile(_ fileIndex: Int) {
        let all = allConflicts
        guard !all.isEmpty else {
            currentConflictIndex = 0
            return
        }

        // Find the first conflict in the target file
        var firstConflictInFile: Int? = nil
        for (index, entry) in all.enumerated() {
            if entry.fileIndex == fileIndex {
                firstConflictInFile = index
                break
            }
        }

        // If file has no conflicts, keep current index clamped
        guard let first = firstConflictInFile else {
            currentConflictIndex = max(0, min(currentConflictIndex, all.count - 1))
            return
        }

        // Set to first conflict in this file
        currentConflictIndex = first
    }

    /// Navigate to the next unresolved conflict (only within current file)
    private func navigateToNextUnresolvedConflict() {
        let all = allConflicts

        // Guard against empty conflicts list
        guard !all.isEmpty else { return }

        // Only look within the current file
        let currentFileIndex = selectedFileIndex

        // First, try to find an unresolved conflict after the current index in the same file
        let startIndex = currentConflictIndex + 1
        if startIndex < all.count {
            for i in startIndex..<all.count {
                let (fileIndex, _, conflict) = all[i]
                // Only consider conflicts in the current file
                guard fileIndex == currentFileIndex else { continue }
                if !files[fileIndex].resolvedConflicts.contains(conflict.id) {
                    currentConflictIndex = i
                    return
                }
            }
        }

        // If none found after, try from the beginning of this file
        for i in 0..<all.count {
            let (fileIndex, _, conflict) = all[i]
            // Only consider conflicts in the current file
            guard fileIndex == currentFileIndex else { continue }
            if !files[fileIndex].resolvedConflicts.contains(conflict.id) {
                currentConflictIndex = i
                return
            }
        }

        // If no unresolved conflicts in this file, stay at current position
        // but clamp to valid range
        if currentConflictIndex >= all.count {
            currentConflictIndex = max(0, all.count - 1)
        }
    }

    // MARK: - Merge Action

    /// Complete the merge (called when all conflicts are resolved)
    /// Writes resolved file contents to disk if repoPath is set
    func completeMerge() {
        guard allConflictsResolved else { return }
        isMerging = true

        // Write resolved files to disk
        Task {
            var success = true

            if let repoPath = repoPath {
                // Access security scoped resource if needed
                let accessGranted = repoPath.startAccessingSecurityScopedResource()
                defer {
                    if accessGranted {
                        repoPath.stopAccessingSecurityScopedResource()
                    }
                }

                for file in files {
                    let filePath = repoPath.appendingPathComponent(file.path)
                    do {
                        try file.content.write(to: filePath, atomically: true, encoding: .utf8)
                    } catch {
                        print("MergeConflictStore: Failed to write file \(file.path): \(error)")
                        success = false
                    }
                }
            }

            // Small delay for visual feedback
            try? await Task.sleep(nanoseconds: 300_000_000)

            await MainActor.run {
                self.isMerging = false
                if success {
                    self.onMergeComplete?()
                }
            }
        }
    }

    // MARK: - Conflict Parsing

    /// Parse conflicts from text content
    private func parseConflicts(in text: String) -> [FileConflict] {
        // Updated pattern to handle conflicts with or without trailing newlines
        // The (?:\\n|$) at the end matches either a newline OR end of string
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
}
