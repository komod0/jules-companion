import Foundation
import SwiftTreeSitter
import CodeEditLanguages

/// Expands conflict markers to syntactic boundaries using Tree-sitter.
///
/// This implements the LCA (Lowest Common Ancestor) expansion strategy:
/// 1. Parse the file content (without conflict markers) with Tree-sitter
/// 2. For each conflict region, find the smallest CST node that fully contains it
/// 3. Expand the conflict markers to wrap that complete node
///
/// This ensures that accepting either side of a conflict produces syntactically valid code.
class ConflictMarkerExpander {
    private let parser = Parser()

    /// Represents a parsed conflict region before expansion
    struct ConflictRegion {
        let startLine: Int      // Line where <<<<<<< appears (0-indexed)
        let midLine: Int        // Line where ======= appears
        let endLine: Int        // Line where >>>>>>> appears
        let oursContent: String // Content between <<<<<<< and =======
        let theirsContent: String // Content between ======= and >>>>>>>
    }

    /// Expands conflict markers in the given content to syntactic boundaries.
    /// Returns the content with expanded conflict markers, or the original if expansion fails.
    ///
    /// Key insight: Only expand if the resolved versions have syntax errors.
    /// If both "ours" and "theirs" parse cleanly, the conflict markers are already at valid boundaries.
    /// This prevents over-expansion for cases like method chain modifications where the smallest
    /// containing CST node would be the entire chain.
    func expandConflicts(in content: String, language: CodeLanguage) -> String {
        // Parse existing conflicts
        let conflicts = parseConflictMarkers(in: content)
        guard !conflicts.isEmpty else { return content }

        // Get the "ours" version (current/local) by stripping conflict markers and keeping ours content
        let oursVersion = resolveToOurs(content: content)

        // Get the "theirs" version by stripping conflict markers and keeping theirs content
        let theirsVersion = resolveToTheirs(content: content)

        // Parse both versions with Tree-sitter
        guard let tsLanguage = language.language else { return content }

        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return content
        }

        guard let oursTree = parser.parse(oursVersion),
              let theirsTree = parser.parse(theirsVersion) else {
            return content
        }

        // Check if both versions parse without errors
        // If so, the conflict markers are already at valid syntactic boundaries - no need to expand
        let oursHasErrors = treeHasErrors(oursTree)
        let theirsHasErrors = treeHasErrors(theirsTree)

        if !oursHasErrors && !theirsHasErrors {
            // Both versions are syntactically valid, no expansion needed
            return content
        }

        // At least one version has syntax errors, try to expand to fix it
        var result = content
        var offset = 0 // Track offset as we modify the string

        let lines = content.components(separatedBy: "\n")

        for conflict in conflicts {
            // Calculate the byte range in the "ours" version for this conflict's content
            let oursLines = oursVersion.components(separatedBy: "\n")
            let conflictStartLine = calculateResolvedLineIndex(
                originalLine: conflict.startLine,
                conflicts: conflicts,
                upToConflict: conflict,
                useOurs: true
            )

            // Find the byte range of the conflict content
            let lineCount = conflict.oursContent.isEmpty ? 0 : conflict.oursContent.components(separatedBy: "\n").count
            guard lineCount > 0, let byteRange = lineRangeToBytesRange(
                lines: oursLines,
                startLine: conflictStartLine,
                lineCount: lineCount
            ) else { continue }

            // Find the smallest node containing this range in the ours tree
            guard let rootNode = oursTree.rootNode,
                  let containingNode = findSmallestContainingNode(
                      in: rootNode,
                      forRange: byteRange
                  ) else { continue }

            // Only expand if the containing node is a "statement-level" or higher construct
            // Skip expansion for expression-level nodes to avoid over-expansion in method chains
            guard shouldExpandToNode(containingNode) else { continue }

            // Get the expanded range from the containing node
            let expandedRange = containingNode.byteRange

            // Convert expanded byte range back to line numbers
            let expandedLines = bytesRangeToLines(
                bytes: expandedRange,
                in: oursVersion
            )

            // Calculate how many lines to expand before and after
            let expandBefore = max(0, conflictStartLine - expandedLines.startLine)
            let expandAfter = max(0, expandedLines.endLine - (conflictStartLine + lineCount - 1))

            if expandBefore > 0 || expandAfter > 0 {
                // Need to expand the conflict region
                result = expandConflictRegion(
                    in: result,
                    conflict: conflict,
                    expandBefore: expandBefore,
                    expandAfter: expandAfter,
                    offset: &offset
                )
            }
        }

        return result
    }

    /// Checks if a parsed tree contains any error nodes
    private func treeHasErrors(_ tree: MutableTree) -> Bool {
        guard let root = tree.rootNode else { return true }
        return nodeHasErrors(root)
    }

    /// Recursively checks if a node or its children contain errors
    private func nodeHasErrors(_ node: Node) -> Bool {
        // Check if this node is an error or missing node
        if node.nodeType == "ERROR" || node.isMissing {
            return true
        }

        // Check children
        for i in 0..<node.childCount {
            if let child = node.child(at: i), nodeHasErrors(child) {
                return true
            }
        }

        return false
    }

    /// Determines if we should expand to a given node type.
    /// Returns true for statement-level constructs, false for expression-level to avoid over-expansion.
    private func shouldExpandToNode(_ node: Node) -> Bool {
        let nodeType = node.nodeType ?? ""

        // Statement-level nodes that are safe to expand to
        let statementLevelTypes: Set<String> = [
            // Declarations
            "function_declaration", "class_declaration", "struct_declaration",
            "enum_declaration", "protocol_declaration", "extension_declaration",
            "variable_declaration", "constant_declaration", "typealias_declaration",
            "import_declaration",
            // Statements
            "if_statement", "guard_statement", "switch_statement", "for_statement",
            "while_statement", "repeat_while_statement", "do_statement",
            "return_statement", "throw_statement", "defer_statement",
            // Control flow
            "control_transfer_statement",
            // Property/subscript
            "property_declaration", "subscript_declaration",
            "computed_property", "willset_clause", "didset_clause",
            // Closures and blocks (at appropriate level)
            "closure_expression", "statements",
            // Source file level
            "source_file"
        ]

        // If it's a known statement-level type, allow expansion
        if statementLevelTypes.contains(nodeType) {
            return true
        }

        // For unknown types, be conservative and don't expand
        // This prevents over-expansion for call_expression, navigation_expression, etc.
        return false
    }

    /// Parses conflict markers from content and returns their positions
    private func parseConflictMarkers(in content: String) -> [ConflictRegion] {
        var conflicts: [ConflictRegion] = []
        let lines = content.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("<<<<<<<") {
                let startLine = i

                // Find the separator
                var midLine = -1
                var j = i + 1
                while j < lines.count {
                    if lines[j].hasPrefix("=======") {
                        midLine = j
                        break
                    }
                    j += 1
                }

                guard midLine != -1 else {
                    i += 1
                    continue
                }

                // Find the end marker
                var endLine = -1
                j = midLine + 1
                while j < lines.count {
                    if lines[j].hasPrefix(">>>>>>>") {
                        endLine = j
                        break
                    }
                    j += 1
                }

                guard endLine != -1 else {
                    i += 1
                    continue
                }

                // Extract content
                let oursContent = lines[(startLine + 1)..<midLine].joined(separator: "\n")
                let theirsContent = lines[(midLine + 1)..<endLine].joined(separator: "\n")

                conflicts.append(ConflictRegion(
                    startLine: startLine,
                    midLine: midLine,
                    endLine: endLine,
                    oursContent: oursContent,
                    theirsContent: theirsContent
                ))

                i = endLine + 1
            } else {
                i += 1
            }
        }

        return conflicts
    }

    /// Resolves content to "ours" version by keeping content between <<<<<<< and =======
    private func resolveToOurs(content: String) -> String {
        var result: [String] = []
        let lines = content.components(separatedBy: "\n")

        var inConflict = false
        var inTheirs = false

        for line in lines {
            if line.hasPrefix("<<<<<<<") {
                inConflict = true
                inTheirs = false
            } else if line.hasPrefix("=======") && inConflict {
                inTheirs = true
            } else if line.hasPrefix(">>>>>>>") && inConflict {
                inConflict = false
                inTheirs = false
            } else if inConflict && !inTheirs {
                result.append(line)
            } else if !inConflict {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Resolves content to "theirs" version by keeping content between ======= and >>>>>>>
    private func resolveToTheirs(content: String) -> String {
        var result: [String] = []
        let lines = content.components(separatedBy: "\n")

        var inConflict = false
        var inTheirs = false

        for line in lines {
            if line.hasPrefix("<<<<<<<") {
                inConflict = true
                inTheirs = false
            } else if line.hasPrefix("=======") && inConflict {
                inTheirs = true
            } else if line.hasPrefix(">>>>>>>") && inConflict {
                inConflict = false
                inTheirs = false
            } else if inConflict && inTheirs {
                result.append(line)
            } else if !inConflict {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Finds the smallest node in the tree that fully contains the given byte range
    private func findSmallestContainingNode(in node: Node, forRange range: Range<UInt32>) -> Node? {
        let nodeRange = node.byteRange

        // Check if this node contains the target range
        guard nodeRange.lowerBound <= range.lowerBound && nodeRange.upperBound >= range.upperBound else {
            return nil
        }

        // Try to find a smaller containing child
        for i in 0..<node.childCount {
            guard let child = node.child(at: i) else { continue }

            if let smallerNode = findSmallestContainingNode(in: child, forRange: range) {
                return smallerNode
            }
        }

        // No smaller child contains the range, this node is the smallest
        return node
    }

    /// Calculates the line index in the resolved version for a given original line
    private func calculateResolvedLineIndex(
        originalLine: Int,
        conflicts: [ConflictRegion],
        upToConflict: ConflictRegion,
        useOurs: Bool
    ) -> Int {
        var resolvedLine = 0
        var originalIndex = 0

        for conflict in conflicts {
            if conflict.startLine >= upToConflict.startLine {
                break
            }

            // Add lines before this conflict
            resolvedLine += conflict.startLine - originalIndex

            // Add the resolved content lines
            let resolvedContent = useOurs ? conflict.oursContent : conflict.theirsContent
            resolvedLine += resolvedContent.isEmpty ? 0 : resolvedContent.components(separatedBy: "\n").count

            // Skip past the conflict markers in the original
            originalIndex = conflict.endLine + 1
        }

        // Add remaining lines up to the target conflict
        resolvedLine += upToConflict.startLine - originalIndex

        return resolvedLine
    }

    /// Converts a line range to a byte range
    private func lineRangeToBytesRange(lines: [String], startLine: Int, lineCount: Int) -> Range<UInt32>? {
        guard startLine >= 0 && startLine < lines.count else { return nil }

        var startByte: UInt32 = 0
        for i in 0..<startLine {
            startByte += UInt32(lines[i].utf8.count) + 1 // +1 for newline
        }

        var endByte = startByte
        let endLine = min(startLine + lineCount, lines.count)
        for i in startLine..<endLine {
            endByte += UInt32(lines[i].utf8.count) + 1
        }

        // Don't include the trailing newline of the last line
        if endByte > 0 {
            endByte -= 1
        }

        return startByte..<endByte
    }

    /// Converts a byte range to line numbers
    private func bytesRangeToLines(bytes: Range<UInt32>, in content: String) -> (startLine: Int, endLine: Int) {
        let lines = content.components(separatedBy: "\n")
        var currentByte: UInt32 = 0
        var startLine = 0
        var endLine = 0

        for (index, line) in lines.enumerated() {
            let lineEndByte = currentByte + UInt32(line.utf8.count)

            if currentByte <= bytes.lowerBound && bytes.lowerBound <= lineEndByte {
                startLine = index
            }

            if currentByte <= bytes.upperBound && bytes.upperBound <= lineEndByte + 1 {
                endLine = index
                break
            }

            currentByte = lineEndByte + 1 // +1 for newline
        }

        return (startLine, endLine)
    }

    /// Expands a conflict region by including additional lines before and after
    private func expandConflictRegion(
        in content: String,
        conflict: ConflictRegion,
        expandBefore: Int,
        expandAfter: Int,
        offset: inout Int
    ) -> String {
        var lines = content.components(separatedBy: "\n")

        // Adjust indices for previous modifications
        let adjustedStart = conflict.startLine + offset
        let adjustedMid = conflict.midLine + offset
        let adjustedEnd = conflict.endLine + offset

        // Calculate new boundaries
        let newStart = max(0, adjustedStart - expandBefore)
        let newEnd = min(lines.count - 1, adjustedEnd + expandAfter)

        // Get lines to prepend to both sides
        let prependLines = expandBefore > 0 ? Array(lines[newStart..<adjustedStart]) : []

        // Get lines to append to both sides
        let appendLines = expandAfter > 0 ? Array(lines[(adjustedEnd + 1)...newEnd]) : []

        // Build new conflict section
        var newConflictLines: [String] = []

        // Start marker
        newConflictLines.append(lines[adjustedStart])

        // Ours content with expansion
        newConflictLines.append(contentsOf: prependLines)
        for i in (adjustedStart + 1)..<adjustedMid {
            newConflictLines.append(lines[i])
        }
        newConflictLines.append(contentsOf: appendLines)

        // Separator
        newConflictLines.append(lines[adjustedMid])

        // Theirs content with expansion
        newConflictLines.append(contentsOf: prependLines)
        for i in (adjustedMid + 1)..<adjustedEnd {
            newConflictLines.append(lines[i])
        }
        newConflictLines.append(contentsOf: appendLines)

        // End marker
        newConflictLines.append(lines[adjustedEnd])

        // Replace the old conflict region with the expanded one
        let removeRange = newStart...newEnd
        lines.replaceSubrange(removeRange, with: newConflictLines)

        // Update offset for subsequent conflicts
        let oldLineCount = newEnd - newStart + 1
        let newLineCount = newConflictLines.count
        offset += newLineCount - oldLineCount

        return lines.joined(separator: "\n")
    }
}
