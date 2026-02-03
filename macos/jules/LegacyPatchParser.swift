import Foundation

struct LegacyParsedDiff {
    let files: [LegacyDiffFile]
}

struct LegacyDiffFile: Identifiable {
    let id = UUID()
    let name: String
    let language: String?
    let hunks: [LegacyDiffHunk]
    let isNew: Bool

    var linesAdded: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.type == .add }.count }
    }

    var linesRemoved: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.type == .remove }.count }
    }
}

struct LegacyDiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [LegacyDiffLine]
}

struct LegacyDiffLine: Identifiable {
    let id = UUID()
    let type: LineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    enum LineType {
        case context
        case add
        case remove
    }
}

class LegacyPatchParser {
    static func parse(diff: String) -> LegacyParsedDiff {
        var files: [LegacyDiffFile] = []
        let lines = diff.components(separatedBy: .newlines)

        var currentFileName: String?
        var currentLanguage: String?
        var isNewFile = false
        var currentHunks: [LegacyDiffHunk] = []
        var currentLines: [LegacyDiffLine] = []
        var currentHunkHeader: String?

        var oldLineCounter = 0
        var newLineCounter = 0

        // Helper to finalize a hunk
        func finalizeHunk() {
            if !currentLines.isEmpty, let header = currentHunkHeader {
                currentHunks.append(LegacyDiffHunk(header: header, lines: currentLines))
                currentLines = []
                currentHunkHeader = nil
            }
        }

        // Helper to finalize a file
        func finalizeFile() {
            finalizeHunk()
            if let name = currentFileName {
                files.append(LegacyDiffFile(name: name, language: currentLanguage, hunks: currentHunks, isNew: isNewFile))
            }
            currentFileName = nil
            currentLanguage = nil
            isNewFile = false
            currentHunks = []
            currentLines = []
            currentHunkHeader = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git") {
                finalizeFile()
            } else if line.hasPrefix("+++ ") {
                // Example: +++ b/path/to/file.swift
                // Or +++ /dev/null
                let rawName = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if rawName != "/dev/null" {
                    // Remove "b/" prefix if present (standard git)
                    if rawName.hasPrefix("b/") {
                        currentFileName = String(rawName.dropFirst(2))
                    } else {
                        currentFileName = rawName
                    }

                    // Determine language
                    if let name = currentFileName {
                         let url = URL(fileURLWithPath: name)
                         let ext = url.pathExtension.lowercased()
                         currentLanguage = ext.isEmpty ? nil : ext
                    }
                }
            } else if line.hasPrefix("--- ") {
                let rawName = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if rawName == "/dev/null" {
                    isNewFile = true
                } else if currentFileName == nil {
                    // Usually --- a/path/to/file
                    // If +++ was /dev/null (deleted file), we might want to use this name
                    if rawName != "/dev/null" {
                        if rawName.hasPrefix("a/") {
                            currentFileName = String(rawName.dropFirst(2))
                        } else {
                            currentFileName = rawName
                        }
                         // Determine language
                       if let name = currentFileName {
                            let url = URL(fileURLWithPath: name)
                            let ext = url.pathExtension.lowercased()
                            currentLanguage = ext.isEmpty ? nil : ext
                       }
                    }
                }
            } else if line.hasPrefix("@@") {
                finalizeHunk()
                currentHunkHeader = line

                // Parse line numbers: @@ -oldStart,oldLen +newStart,newLen @@
                // Or @@ -oldStart +newStart @@ (if len is 1)
                let components = line.split(separator: " ")
                if components.count >= 3 {
                    let oldStr = components[1].dropFirst() // "-..."
                    let newStr = components[2].dropFirst() // "+..."

                    let oldParts = oldStr.split(separator: ",")
                    if let start = Int(oldParts[0]) {
                        oldLineCounter = start
                    }

                    let newParts = newStr.split(separator: ",")
                    if let start = Int(newParts[0]) {
                        newLineCounter = start
                    }
                }
            } else if currentHunkHeader != nil {
                // We are inside a hunk
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    currentLines.append(LegacyDiffLine(type: .add, content: String(line.dropFirst()), oldLineNumber: nil, newLineNumber: newLineCounter))
                    newLineCounter += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    currentLines.append(LegacyDiffLine(type: .remove, content: String(line.dropFirst()), oldLineNumber: oldLineCounter, newLineNumber: nil))
                    oldLineCounter += 1
                } else if line.hasPrefix(" ") {
                    currentLines.append(LegacyDiffLine(type: .context, content: String(line.dropFirst()), oldLineNumber: oldLineCounter, newLineNumber: newLineCounter))
                    oldLineCounter += 1
                    newLineCounter += 1
                } else if line == "\\ No newline at end of file" {
                    // Ignore for line numbering
                } else {
                     // Metadata or other noise, ignore?
                }
            }
        }

        finalizeFile()

        return LegacyParsedDiff(files: files)
    }
}
