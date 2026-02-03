import Foundation
import libgit2

class PatchEngine {
    enum PatchError: Error {
        case failedToInitializeLibGit2
        case failedToParseDiff(Int32)
        case failedToApply(Int32)
        case invalidPatch
    }

    init() {
        // Initialize libgit2
        git_libgit2_init()
    }

    deinit {
        git_libgit2_shutdown()
    }

    // Parses a diff string using git_diff_from_buffer
    func validatePatch(_ patch: String) throws {
        var diff: OpaquePointer? = nil
        let length = patch.utf8.count

        let result = git_diff_from_buffer(&diff, patch, length)

        defer {
            if let diff = diff {
                git_diff_free(diff)
            }
        }

        if result != 0 {
            throw PatchError.failedToParseDiff(result)
        }
    }

    func apply(patch: String, to originalContent: String) throws -> String {
        // Fallback to manual application using LegacyPatchParser since git_apply_to_buffer is not available
        let parsed = LegacyPatchParser.parse(diff: patch)
        guard let file = parsed.files.first else {
             // If no file in diff, return original.
             return originalContent
        }

        // Split original content
        let oldLines = originalContent.components(separatedBy: .newlines)
        var resultLines: [String] = []
        var oldIdx = 0 // 0-based index in oldLines

        for hunk in file.hunks {
            // Parse start line from header: @@ -oldStart,oldLen +newStart,newLen @@
            let header = hunk.header
            let components = header.split(separator: " ")
            if components.count < 2 { continue }

            let oldSpec = components[1].dropFirst() // "oldStart,..."
            let oldStartStr = oldSpec.split(separator: ",")[0]
            guard let oldStart = Int(oldStartStr) else {
                throw PatchError.invalidPatch
            }

            // oldStart is 1-based. Convert to 0-based.
            let targetOldIndex = (oldStart == 0) ? 0 : oldStart - 1

            // Copy lines before the hunk
            if targetOldIndex > oldIdx {
                if targetOldIndex > oldLines.count {
                     throw PatchError.failedToApply(-1)
                }
                resultLines.append(contentsOf: oldLines[oldIdx..<targetOldIndex])
                oldIdx = targetOldIndex
            }

            // Process lines
            for line in hunk.lines {
                switch line.type {
                case .context:
                    if oldIdx < oldLines.count {
                        resultLines.append(oldLines[oldIdx])
                        oldIdx += 1
                    } else {
                         throw PatchError.failedToApply(-1)
                    }
                case .add:
                    resultLines.append(line.content)
                case .remove:
                    if oldIdx < oldLines.count {
                        oldIdx += 1
                    } else {
                        throw PatchError.failedToApply(-1)
                    }
                }
            }
        }

        // Copy remaining lines
        if oldIdx < oldLines.count {
            resultLines.append(contentsOf: oldLines[oldIdx...])
        }

        return resultLines.joined(separator: "\n")
    }

    // Applies the patch to the working directory at repoPath.
    // If checkOnly is true, it performs a dry-run (GIT_APPLY_CHECK).
    func apply(patch: String, to repoPath: String, checkOnly: Bool = false) throws {
        var diff: OpaquePointer? = nil
        let length = patch.utf8.count

        // 1. Parse diff
        let parseResult = git_diff_from_buffer(&diff, patch, length)
        if parseResult != 0 {
            throw PatchError.failedToParseDiff(parseResult)
        }
        defer {
            if let diff = diff {
                git_diff_free(diff)
            }
        }

        // 2. Open Repository
        var repo: OpaquePointer? = nil
        let repoOpenResult = git_repository_open(&repo, repoPath)
        if repoOpenResult != 0 {
             throw PatchError.failedToApply(repoOpenResult)
        }
        defer {
             if let repo = repo {
                 git_repository_free(repo)
             }
        }

        // 3. Apply options
        var options = git_apply_options()
        let initResult = git_apply_options_init(&options, UInt32(GIT_APPLY_OPTIONS_VERSION))
        if initResult != 0 {
            throw PatchError.failedToApply(initResult)
        }

        // Set flags
        if checkOnly {
            options.flags |= 1 // GIT_APPLY_CHECK
        }

        // 4. Apply
        let applyResult = git_apply(repo, diff, GIT_APPLY_LOCATION_WORKDIR, &options)

        if applyResult != 0 {
            throw PatchError.failedToApply(applyResult)
        }
    }
}
