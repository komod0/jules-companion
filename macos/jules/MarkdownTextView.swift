import SwiftUI
import Markdown

/// A view that detects and renders markdown text, falling back to plain text when no markdown is detected.
struct MarkdownTextView: View {
    let text: String
    let textColor: Color
    let fontSize: CGFloat

    @MainActor
    init(_ text: String, textColor: Color = AppColors.textPrimary, fontSize: CGFloat? = nil) {
        self.text = text
        self.textColor = textColor
        self.fontSize = fontSize ?? FontSizeManager.shared.activityFontSize
    }

    var body: some View {
        if MarkdownDetector.containsMarkdown(text) {
            Text(MarkdownRenderer.render(text, baseColor: textColor, fontSize: fontSize))
                .font(.system(size: fontSize))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(textColor)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

/// Detects whether a string contains markdown formatting
enum MarkdownDetector {
    /// Common markdown patterns to detect
    private static let markdownPatterns: [String] = [
        // Headers
        #"^#{1,6}\s"#,
        // Bold
        #"\*\*[^*]+\*\*"#,
        #"__[^_]+__"#,
        // Italic
        #"(?<!\*)\*[^*]+\*(?!\*)"#,
        #"(?<!_)_[^_]+_(?!_)"#,
        // Code blocks
        #"```[\s\S]*?```"#,
        // Inline code
        #"`[^`]+`"#,
        // Links
        #"\[([^\]]+)\]\(([^)]+)\)"#,
        // Unordered lists
        #"^[\s]*[-*+]\s"#,
        // Ordered lists
        #"^[\s]*\d+\.\s"#,
        // Blockquotes
        #"^>\s"#,
        // Strikethrough
        #"~~[^~]+~~"#,
        // Horizontal rules
        #"^---+$"#,
        #"^\*\*\*+$"#,
    ]

    /// Checks if the given text contains markdown formatting
    static func containsMarkdown(_ text: String) -> Bool {
        for pattern in markdownPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }
}

/// Renders markdown text to AttributedString
enum MarkdownRenderer {
    /// Renders markdown text to an AttributedString
    @MainActor
    static func render(_ text: String, baseColor: Color, fontSize: CGFloat? = nil) -> AttributedString {
        let document = Document(parsing: text)
        var visitor = AttributedStringVisitor(baseColor: baseColor, fontSize: fontSize)
        return visitor.visit(document)
    }
}

/// A MarkupVisitor that converts markdown to AttributedString
private struct AttributedStringVisitor: MarkupVisitor {
    typealias Result = AttributedString

    let baseColor: Color
    let fontSize: CGFloat

    @MainActor
    init(baseColor: Color, fontSize: CGFloat? = nil) {
        self.baseColor = baseColor
        self.fontSize = fontSize ?? FontSizeManager.shared.activityFontSize
    }

    mutating func defaultVisit(_ markup: any Markup) -> AttributedString {
        var result = AttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> AttributedString {
        var result = AttributedString()
        for child in document.children {
            result.append(visit(child))
        }
        return result
    }

    mutating func visitText(_ text: Markdown.Text) -> AttributedString {
        var attr = AttributedString(text.plainText)
        attr.foregroundColor = baseColor
        return attr
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> AttributedString {
        var result = AttributedString()
        for child in paragraph.children {
            result.append(visit(child))
        }
        // Add newline after paragraph unless it's the last one
        if paragraph.indexInParent < (paragraph.parent?.childCount ?? 1) - 1 {
            result.append(AttributedString("\n\n"))
        }
        return result
    }

    mutating func visitStrong(_ strong: Strong) -> AttributedString {
        var result = AttributedString()
        for child in strong.children {
            result.append(visit(child))
        }
        result.inlinePresentationIntent = .stronglyEmphasized
        return result
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> AttributedString {
        var result = AttributedString()
        for child in emphasis.children {
            result.append(visit(child))
        }
        result.inlinePresentationIntent = .emphasized
        return result
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> AttributedString {
        var attr = AttributedString(inlineCode.code)
        attr.foregroundColor = AppColors.accentLight
        attr.font = .system(size: fontSize, design: .monospaced)

        // If the code looks like a filename, make it clickable
        let code = inlineCode.code
        if looksLikeFilename(code), let url = URL(string: "jules-file://\(code.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? code)") {
            attr.link = url
            // Cursor will change on hover automatically for links
        }

        return attr
    }

    /// Checks if a string looks like a filename (contains extension, no spaces, reasonable length)
    private func looksLikeFilename(_ text: String) -> Bool {
        // Must contain a dot for extension
        guard text.contains(".") else { return false }
        // No spaces (filenames rarely have spaces in code references)
        guard !text.contains(" ") else { return false }
        // Reasonable length (not a sentence with a period)
        guard text.count <= 100 else { return false }
        // Must have something after the dot
        guard let dotIndex = text.lastIndex(of: "."),
              text.distance(from: dotIndex, to: text.endIndex) > 1 else { return false }
        // Common code file extensions
        let commonExtensions = ["swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp", "m", "mm", "cs", "fs", "vue", "svelte", "html", "css", "scss", "sass", "less", "json", "yaml", "yml", "toml", "xml", "md", "txt", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "graphql", "proto", "ex", "exs", "erl", "hrl", "hs", "ml", "mli", "clj", "cljs", "scala", "gradle", "cmake", "make", "dockerfile", "lock", "config", "conf", "ini", "env", "gitignore", "editorconfig"]
        let ext = String(text[text.index(after: dotIndex)...]).lowercased()
        return commonExtensions.contains(ext) || ext.count <= 5
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> AttributedString {
        var attr = AttributedString(codeBlock.code)
        attr.foregroundColor = AppColors.accentLight
        attr.font = .system(size: fontSize, design: .monospaced)
        attr.backgroundColor = AppColors.backgroundSecondary
        if codeBlock.indexInParent < (codeBlock.parent?.childCount ?? 1) - 1 {
            attr.append(AttributedString("\n"))
        }
        return attr
    }

    mutating func visitHeading(_ heading: Heading) -> AttributedString {
        var result = AttributedString()
        for child in heading.children {
            result.append(visit(child))
        }

        // Apply heading font size based on level (relative to base fontSize)
        switch heading.level {
        case 1:
            result.font = .system(size: fontSize, weight: .bold)
        case 2:
            result.font = .system(size: fontSize, weight: .bold)
        case 3:
            result.font = .system(size: fontSize, weight: .semibold)
        case 4:
            result.font = .system(size: fontSize, weight: .semibold)
        case 5:
            result.font = .system(size: fontSize, weight: .medium)
        default:
            result.font = .system(size: fontSize, weight: .medium)
        }

        result.append(AttributedString("\n"))
        return result
    }

    mutating func visitLink(_ link: Markdown.Link) -> AttributedString {
        var result = AttributedString()
        for child in link.children {
            result.append(visit(child))
        }
        result.foregroundColor = AppColors.accent
        result.underlineStyle = .single
        if let destination = link.destination, let url = URL(string: destination) {
            result.link = url
        }
        return result
    }

    mutating func visitListItem(_ listItem: ListItem) -> AttributedString {
        var result = AttributedString()

        // Calculate nesting level by counting list ancestors
        let nestingLevel = calculateNestingLevel(for: listItem)

        // Add indentation based on nesting level (2 spaces per level)
        if nestingLevel > 0 {
            let indent = String(repeating: "  ", count: nestingLevel)
            var indentAttr = AttributedString(indent)
            indentAttr.foregroundColor = baseColor
            result.append(indentAttr)
        }

        // Determine bullet/number
        if let orderedList = listItem.parent as? OrderedList {
            let number = Int(orderedList.startIndex) + listItem.indexInParent
            var bullet = AttributedString("\(number). ")
            bullet.foregroundColor = baseColor
            result.append(bullet)
        } else {
            var bullet = AttributedString("• ")
            bullet.foregroundColor = baseColor
            result.append(bullet)
        }

        for child in listItem.children {
            result.append(visit(child))
        }

        return result
    }

    /// Calculates the nesting level of a list item by counting list ancestors
    private func calculateNestingLevel(for markup: any Markup) -> Int {
        var level = 0
        var current: (any Markup)? = markup.parent

        while let parent = current {
            if parent is UnorderedList || parent is OrderedList {
                level += 1
            }
            current = parent.parent
        }

        // Subtract 1 because the immediate parent list is level 0
        return max(0, level - 1)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> AttributedString {
        var result = AttributedString()
        for (index, item) in unorderedList.listItems.enumerated() {
            result.append(visit(item))
            if index < unorderedList.childCount - 1 {
                result.append(AttributedString("\n"))
            }
        }
        if unorderedList.indexInParent < (unorderedList.parent?.childCount ?? 1) - 1 {
            result.append(AttributedString("\n"))
        }
        return result
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> AttributedString {
        var result = AttributedString()
        for (index, item) in orderedList.listItems.enumerated() {
            result.append(visit(item))
            if index < orderedList.childCount - 1 {
                result.append(AttributedString("\n"))
            }
        }
        if orderedList.indexInParent < (orderedList.parent?.childCount ?? 1) - 1 {
            result.append(AttributedString("\n"))
        }
        return result
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> AttributedString {
        var result = AttributedString("│ ")
        result.foregroundColor = AppColors.textPrimary

        for child in blockQuote.children {
            result.append(visit(child))
        }

        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> AttributedString {
        var result = AttributedString()
        for child in strikethrough.children {
            result.append(visit(child))
        }
        result.strikethroughStyle = .single
        return result
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> AttributedString {
        return AttributedString(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> AttributedString {
        return AttributedString("\n")
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> AttributedString {
        var attr = AttributedString("───────────────────\n")
        attr.foregroundColor = AppColors.textSecondary
        return attr
    }
}
