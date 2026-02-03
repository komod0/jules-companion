import Foundation
import Combine
import SwiftGitX
import libgit2

@MainActor
class MergeViewModel: ObservableObject {
    @Published var diffFiles: [LegacyDiffFile] = []
    @Published var selectedFileId: UUID?
    @Published var commitMessage: String = ""
    @Published var isCommitting: Bool = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var fileContent: String = ""
    @Published var conflictedFileIDs: Set<UUID> = []

    // Store modified content for each file (by file path/name)
    private var modifiedContents: [String: String] = [:]

    private let patchEngine = PatchEngine()
    private var session: Session
    private var repoURL: URL?

    var selectedFile: LegacyDiffFile? {
        diffFiles.first(where: { $0.id == selectedFileId })
    }

    init(session: Session, sourceId: String? = nil) {
        self.session = session

        // Use provided sourceId, which should match keys stored by SettingsWindowView
        // This ensures consistency between folder settings and local merge functionality
        if let sourceId = sourceId {
            if let bookmarks = UserDefaults.standard.dictionary(forKey: "localRepoBookmarksKey") as? [String: Data],
               let data = bookmarks[sourceId] {
                var stale = false
                do {
                    let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                    if url.startAccessingSecurityScopedResource() {
                        self.repoURL = url
                    }
                } catch {
                    print("MergeViewModel: Failed to resolve bookmark: \(error)")
                }
            }

            // Fallback to path string
            if self.repoURL == nil {
                 if let paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String],
                    let path = paths[sourceId] {
                     self.repoURL = URL(fileURLWithPath: path)
                     _ = self.repoURL?.startAccessingSecurityScopedResource()
                 }
            }
        }

        loadDiffs()
    }

    deinit {
        repoURL?.stopAccessingSecurityScopedResource()
    }

    func loadDiffs() {
        guard let diffs = session.latestDiffs, !diffs.isEmpty else { return }
        let combinedPatch = diffs.map { $0.patch }.joined(separator: "\n")
        let parsed = LegacyPatchParser.parse(diff: combinedPatch)
        self.diffFiles = parsed.files

        // Attempt to apply the patch to the repo immediately so users see the changes?
        // Or wait for user action?
        // User workflow: "Local Merge" -> Opens view.
        // Ideally, we show the *proposed* changes.
        // If we apply to disk, we modify user's repo.
        // But to "resolve", we often need to edit the file.
        // Let's try to apply.
        applyPatchToWorkingCopy()

        if let first = diffFiles.first {
            selectedFileId = first.id
            // Load content for the first file
            loadFileContent(file: first)
        }
    }

    func selectFile(_ file: LegacyDiffFile) {
        // Save current content before switching
        if let previousFile = selectedFile {
            modifiedContents[previousFile.name] = fileContent
        }

        selectedFileId = file.id
        loadFileContent(file: file)
    }

    private func loadFileContent(file: LegacyDiffFile) {
        if let cached = modifiedContents[file.name] {
            fileContent = cached
            return
        }

        guard let repoURL = repoURL else { return }
        let fullURL = repoURL.appendingPathComponent(file.name)

        var content = ""
        if FileManager.default.fileExists(atPath: fullURL.path) {
            do {
                content = try String(contentsOf: fullURL, encoding: .utf8)
            } catch {
                errorMessage = "Error reading file \(file.name): \(error.localizedDescription)"
            }
        }

        if conflictedFileIDs.contains(file.id) {
            let theirsContent = extractContentFromNewFile(file)
            content = "<<<<<<< HEAD (Current Change)\n" + content + "\n=======\n" + theirsContent + "\n>>>>>>> Incoming Change\n"
        } else if file.isNew {
            content = extractContentFromNewFile(file)
        }

        fileContent = content
        modifiedContents[file.name] = content
    }

    func markAsResolved(file: LegacyDiffFile) {
        let resolvedContent = fileContent.replacingOccurrences(of: "<<<<<<< HEAD (Current Change)\n", with: "")
                                          .replacingOccurrences(of: "\n=======\n", with: "")
                                          .replacingOccurrences(of: "\n>>>>>>> Incoming Change\n", with: "")
        modifiedContents[file.name] = resolvedContent
        conflictedFileIDs.remove(file.id)
    }

    private func applyPatchToWorkingCopy() {
        guard let repoURL = repoURL, let diffs = session.latestDiffs, !diffs.isEmpty else { return }

        for file in diffFiles {
            let patch = extractPatch(for: file)
            guard !patch.isEmpty else { continue }

            let originalContent: String
            let fileURL = repoURL.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                originalContent = (try? String(contentsOf: fileURL)) ?? ""
            } else {
                originalContent = ""
            }

            do {
                let patchedContent = try patchEngine.apply(patch: patch, to: originalContent)
                modifiedContents[file.name] = patchedContent
            } catch {
                conflictedFileIDs.insert(file.id)
            }
        }

        if conflictedFileIDs.isEmpty {
            successMessage = "All changes applied successfully."
        } else {
            errorMessage = "\(conflictedFileIDs.count) file(s) have conflicts."
        }
    }

    private func extractPatch(for file: LegacyDiffFile) -> String {
        guard let diffs = session.latestDiffs else { return "" }
        let combined = diffs.map { $0.patch }.joined()

        let pattern = "diff --git a/\\Q\(file.name)\\E b/\\Q\(file.name)\\E(.*?)(?=diff --git a/|$)"
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            let nsRange = NSRange(combined.startIndex..<combined.endIndex, in: combined)
            if let match = regex.firstMatch(in: combined, options: [], range: nsRange) {
                if let range = Range(match.range(at: 0), in: combined) {
                    return String(combined[range])
                }
            }
        } catch {
            print("Regex error: \(error)")
        }
        return ""
    }

    private func extractContentFromNewFile(_ file: LegacyDiffFile) -> String {
        var content = ""
        for hunk in file.hunks {
            for line in hunk.lines {
                if line.type == .add {
                    content += line.content + "\n"
                }
            }
        }
        return content
    }

    private func configureGitIdentityIfNeeded(repoPath: String) {
        // Open repo using libgit2 C-API
        var rawRepo: OpaquePointer? = nil
        guard git_repository_open(&rawRepo, repoPath) == 0 else { return }
        defer { git_repository_free(rawRepo) }

        var config: OpaquePointer? = nil
        guard git_repository_config(&config, rawRepo) == 0 else { return }
        defer { git_config_free(config) }

        // Check if user.name exists
        var val: UnsafePointer<CChar>? = nil
        let nameRes = git_config_get_string(&val, config, "user.name")
        let needsName = (nameRes != 0) // 0 is success

        // Check if user.email exists
        let emailRes = git_config_get_string(&val, config, "user.email")
        let needsEmail = (emailRes != 0)

        if needsName {
            git_config_set_string(config, "user.name", "Jules")
        }
        if needsEmail {
            git_config_set_string(config, "user.email", "jules@local")
        }
    }

    func commit() async {
        guard let repoURL = repoURL else {
            errorMessage = "No repository path configured."
            return
        }
        guard conflictedFileIDs.isEmpty else {
            errorMessage = "Please resolve all conflicts before committing."
            return
        }

        // Save current editor content
        if let file = selectedFile {
            modifiedContents[file.name] = fileContent
        }

        isCommitting = true
        errorMessage = nil

        do {
            // 1. Write ALL modified files to disk
            for (filename, content) in modifiedContents {
                let fullURL = repoURL.appendingPathComponent(filename)
                try content.write(to: fullURL, atomically: true, encoding: .utf8)
            }

            // 2. Use SwiftGitX to commit
            // Use correct initializer
            let repo = try Repository(at: repoURL)

            // Fix for SwiftGitX Error 1: Ensure user/email is configured
            // SwiftGitX relies on libgit2's default signature which fails if config is missing.
            // We use libgit2 directly to set a fallback config if needed.
            configureGitIdentityIfNeeded(repoPath: repoURL.path)

            // Stage files (all files in the diff)
            for file in diffFiles {
                try repo.add(path: file.name)
            }

            // Commit
            // Note: SwiftGitX's commit(message:) automatically uses HEAD as parent and config's user/email
            _ = try repo.commit(message: commitMessage)

            successMessage = "Committed successfully!"
            isCommitting = false
            // Clear dirty state?

        } catch {
            errorMessage = "Commit failed: \(error.localizedDescription)"
            isCommitting = false
        }
    }
}
