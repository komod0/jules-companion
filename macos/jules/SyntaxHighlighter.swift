import Foundation
import CodeEditLanguages
import SwiftTreeSitter
import AppKit

actor SyntaxHighlighter {
    private let parser = Parser()

    func highlightLines(code: String, language: String) -> [Int: [StyleSpan]] {
        let codeLang = CodeLanguage.from(extension: language)

        // Ensure language is available
        guard let language = codeLang.language,
              let _ = try? parser.setLanguage(language) else { return [:] }

        guard let tree = parser.parse(code) else { return [:] }

        // Load Query
        guard let query = CodeLanguage.query(for: codeLang) else { return [:] }

        let cursor = query.execute(in: tree)

        var map: [Int: [StyleSpan]] = [:]

        // In order to map captures back to lines, we need to know the line ranges of the original code.
        let lines = code.components(separatedBy: "\n")
        var lineOffsets: [Int] = [0]
        var currentOffset = 0
        for line in lines {
            currentOffset += line.utf8.count + 1 // +1 for newline
            lineOffsets.append(currentOffset)
        }

        // Helper to find row for offset
        func row(for offset: Int) -> Int {
            var low = 0
            var high = lineOffsets.count - 1
            while low < high {
                let mid = (low + high + 1) / 2 // round up
                if lineOffsets[mid] <= offset {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return min(low, lines.count - 1)
        }

        for match in cursor {
            for capture in match.captures {
                let captureRange = capture.node.byteRange
                let name = capture.name ?? ""
                guard let color = themeColor(for: name) else { continue }

                // We need to split this capture range across lines
                let startLoc = Int(captureRange.lowerBound)
                let endLoc = Int(captureRange.upperBound)

                // Find start line
                let startRow = row(for: startLoc)
                let endRow = row(for: endLoc)

                for row in startRow...endRow {
                    guard row < lines.count else { continue }
                    let lineStartOffset = lineOffsets[row]
                    let lineEndOffset = lineOffsets[row+1] - 1 // Exclude newline

                    // Intersection of captureRange and lineRange
                    let intersectionStart = max(startLoc, lineStartOffset)
                    let intersectionEnd = min(endLoc, lineEndOffset)

                    if intersectionStart < intersectionEnd {
                        let relStart = intersectionStart - lineStartOffset
                        let relLength = intersectionEnd - intersectionStart

                        if map[row] == nil { map[row] = [] }
                        map[row]?.append(StyleSpan(range: NSRange(location: relStart, length: relLength), color: color))
                    }
                }
            }
        }

        return map
    }

    private func themeColor(for name: String) -> NSColor? {
        // Basic mapping based on standard capture names
        if name.contains("keyword") { return .systemPurple }
        if name.contains("string") { return .systemRed }
        if name.contains("comment") { return .systemGray }
        if name.contains("function") { return .systemBlue }
        if name.contains("type") { return .systemTeal }
        if name.contains("variable") { return .textColor }
        if name.contains("number") { return .systemOrange }
        if name.contains("boolean") { return .systemPurple }
        return nil
    }
}

// Helper for CodeLanguage
extension CodeLanguage {
    /// Converts a language identifier or file extension to a CodeLanguage.
    /// This handles both TreeSitterLanguage ID raw values (e.g., "swift", "python")
    /// and file extensions (e.g., "py", "js").
    static func from(extension ext: String) -> CodeLanguage {
        let lowercased = ext.lowercased()

        // First, try to match by language ID (from TreeSitterLanguage rawValue)
        // This handles cases where we get the language ID directly from CodeLanguage.detectLanguageFrom
        if let lang = CodeLanguage.allLanguages.first(where: { $0.id.rawValue == lowercased }) {
            return lang
        }

        // Fallback: match by common file extensions for backwards compatibility
        switch lowercased {
        // Agda
        case "agda": return .agda
        // Bash
        case "sh", "bash", "zsh", "ksh": return .bash
        // C
        case "c": return .c
        // C++
        case "cpp", "cc", "cxx", "c++", "hpp", "hxx", "h++": return .cpp
        // C (header files - could be C or C++, default to C)
        case "h": return .c
        // C#
        case "cs", "csharp": return .cSharp
        // CSS
        case "css": return .css
        // Dart
        case "dart": return .dart
        // Dockerfile
        case "dockerfile": return .dockerfile
        // Elixir
        case "ex", "exs": return .elixir
        // Go
        case "go": return .go
        // Go Mod
        case "mod": return .goMod
        // Haskell
        case "hs", "lhs": return .haskell
        // HTML
        case "html", "htm", "shtml", "xhtml": return .html
        // Java
        case "java", "jav": return .java
        // JavaScript
        case "js", "javascript", "cjs", "mjs": return .javascript
        // JSON
        case "json": return .json
        // JSX
        case "jsx": return .jsx
        // Julia
        case "jl": return .julia
        // Kotlin
        case "kt", "kts": return .kotlin
        // Lua
        case "lua": return .lua
        // Markdown
        case "md", "markdown", "mkd", "mkdn", "mdwn", "mdown": return .markdown
        // Objective-C
        case "m", "objc": return .objc
        // OCaml
        case "ml", "ocaml": return .ocaml
        // OCaml Interface
        case "mli": return .ocamlInterface
        // Perl
        case "pl", "pm", "perl": return .perl
        // PHP
        case "php": return .php
        // Python
        case "py", "python", "pyw": return .python
        // Ruby
        case "rb", "ruby", "rake", "gemspec": return .ruby
        // Rust
        case "rs", "rust": return .rust
        // Scala
        case "scala", "sc": return .scala
        // SQL
        case "sql": return .sql
        // Swift
        case "swift": return .swift
        // TOML
        case "toml": return .toml
        // TSX
        case "tsx": return .tsx
        // TypeScript
        case "ts", "typescript", "cts", "mts": return .typescript
        // Verilog
        case "v", "vh", "verilog": return .verilog
        // YAML
        case "yml", "yaml": return .yaml
        // Zig
        case "zig": return .zig
        default: return .default
        }
    }

    static func query(for language: CodeLanguage) -> Query? {
        // Try to load query from CodeEditLanguages bundle first
        guard let tsLanguage = language.language else { return nil }

        if let queryURL = language.queryURL,
           let queryData = try? Data(contentsOf: queryURL),
           let query = try? Query(language: tsLanguage, data: queryData) {
            return query
        }

        // Fallback hardcoded queries for basic functionality
        let swiftQuery = """
        (comment) @comment
        (line_string_literal) @string
        (integer_literal) @number
        (boolean_literal) @boolean
        """

        let pythonQuery = """
        (comment) @comment
        (string) @string
        (integer) @number
        """

        let cQuery = """
        (comment) @comment
        (string_literal) @string
        (number_literal) @number
        """

        let jsQuery = """
        (comment) @comment
        (string) @string
        (template_string) @string
        (number) @number
        """

        var queryStr = ""
        if language == .swift { queryStr = swiftQuery }
        else if language == .python { queryStr = pythonQuery }
        else if language == .c || language == .cpp { queryStr = cQuery }
        else if language == .javascript || language == .typescript { queryStr = jsQuery }

        if !queryStr.isEmpty, let data = queryStr.data(using: .utf8) {
            return try? Query(language: tsLanguage, data: data)
        }

        return nil
    }
}

struct StyleSpan: Sendable {
    let range: NSRange
    let color: NSColor
}

extension NSColor: @unchecked Sendable {}
