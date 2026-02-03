import SwiftUI
import AppKit
import OSLog

// MARK: - Cursor Setting Helper

/// A view that sets the cursor to pointing hand when hovered
private struct PointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PointerCursorNSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class PointerCursorNSView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

// MARK: - SimpleTextEditorContainer

/// A wrapper view that composes the text editor with an optional inline submit button
/// PERFORMANCE: This view is isolated from DataManager - only receives the values it needs
struct SimpleTextEditorContainer<BottomLeadingContent: View>: View, Equatable {
    @Binding var text: String
    var baseFont: NSFont? = nil
    var baseTextColor: NSColor? = nil
    var backgroundColor: NSColor? = nil

    // Background configuration using SwiftUI Material
    var backgroundMaterial: Material = .ultraThinMaterial
    var tintOverlayColor: Color = AppColors.background
    var tintOverlayOpacity: Double = 0.4
    var borderColor: Color? = nil

    // Submit button configuration
    var onSubmit: (() -> Void)? = nil
    var isSubmitting: Bool = false
    var submitDisabled: Bool = false

    // Attachment handlers
    var onAttachment: ((String) -> Void)? = nil
    var onImageAttachment: ((NSImage) -> Void)? = nil

    // Auto-expand configuration
    var autoExpand: Bool = false
    var minHeight: CGFloat = 80
    var maxHeight: CGFloat = 200

    // Content padding inside the text editor
    var contentPadding: CGFloat = 6

    // Autocomplete configuration
    var onAutocompleteRequest: ((String) -> Void)? = nil
    var onTextChange: ((String) -> Void)? = nil

    // Navigation callbacks - called when arrow keys are pressed and autocomplete is not active
    var onDownArrow: (() -> Void)? = nil
    var onUpArrow: (() -> Void)? = nil

    // Enter override - if returns true, enter was handled by navigation; else fall through to submit
    var onEnterOverride: (() -> Bool)? = nil

    // Input focus callback - called when user starts typing or clicks in the text area
    var onInputFocus: (() -> Void)? = nil

    // Bottom-left content (e.g., source picker) - positioned in same row as submit button
    var bottomLeadingContent: BottomLeadingContent

    @State private var isHoveringSubmitButton: Bool = false
    @State private var contentHeight: CGFloat = 0
    @State private var displayedHeight: CGFloat = 0
    @State private var lastHeightChangeTime: Date = .distantPast
    @State private var isDragHighlighted: Bool = false

    // MARK: - Equatable

    static func == (lhs: SimpleTextEditorContainer, rhs: SimpleTextEditorContainer) -> Bool {
        // Only re-render if these key values change
        // Note: Material doesn't conform to Equatable, so we skip it in comparison
        lhs.text == rhs.text &&
        lhs.isSubmitting == rhs.isSubmitting &&
        lhs.submitDisabled == rhs.submitDisabled &&
        lhs.minHeight == rhs.minHeight &&
        lhs.maxHeight == rhs.maxHeight &&
        lhs.contentPadding == rhs.contentPadding &&
        lhs.tintOverlayColor == rhs.tintOverlayColor &&
        lhs.tintOverlayOpacity == rhs.tintOverlayOpacity &&
        lhs.borderColor == rhs.borderColor
    }

    // MARK: - Initializer with ViewBuilder

    init(
        text: Binding<String>,
        baseFont: NSFont? = nil,
        baseTextColor: NSColor? = nil,
        backgroundColor: NSColor? = nil,
        backgroundMaterial: Material = .ultraThinMaterial,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.4,
        borderColor: Color? = nil,
        onSubmit: (() -> Void)? = nil,
        isSubmitting: Bool = false,
        submitDisabled: Bool = false,
        onAttachment: ((String) -> Void)? = nil,
        onImageAttachment: ((NSImage) -> Void)? = nil,
        autoExpand: Bool = false,
        minHeight: CGFloat = 80,
        maxHeight: CGFloat = 200,
        contentPadding: CGFloat = 6,
        onAutocompleteRequest: ((String) -> Void)? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onDownArrow: (() -> Void)? = nil,
        onUpArrow: (() -> Void)? = nil,
        onEnterOverride: (() -> Bool)? = nil,
        onInputFocus: (() -> Void)? = nil,
        @ViewBuilder bottomLeadingContent: () -> BottomLeadingContent
    ) {
        self._text = text
        self.baseFont = baseFont
        self.baseTextColor = baseTextColor
        self.backgroundColor = backgroundColor
        self.backgroundMaterial = backgroundMaterial
        self.tintOverlayColor = tintOverlayColor
        self.tintOverlayOpacity = tintOverlayOpacity
        self.borderColor = borderColor
        self.onSubmit = onSubmit
        self.isSubmitting = isSubmitting
        self.submitDisabled = submitDisabled
        self.onAttachment = onAttachment
        self.onImageAttachment = onImageAttachment
        self.autoExpand = autoExpand
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.contentPadding = contentPadding
        self.onAutocompleteRequest = onAutocompleteRequest
        self.onTextChange = onTextChange
        self.onDownArrow = onDownArrow
        self.onUpArrow = onUpArrow
        self.onEnterOverride = onEnterOverride
        self.onInputFocus = onInputFocus
        self.bottomLeadingContent = bottomLeadingContent()
    }

    private func calculateEffectiveHeight(from height: CGFloat) -> CGFloat {
        if autoExpand {
            // Total vertical space needed:
            // - Top content padding (contentPadding)
            // - Bottom content padding (contentPadding)
            // - Bottom content area for buttons (bottomContentRowHeight)
            let totalVerticalInsets = (2 * contentPadding) + bottomContentRowHeight
            let paddedHeight = height + totalVerticalInsets
            return min(max(paddedHeight, minHeight), maxHeight)
        }
        return minHeight
    }

    /// Height of the bottom content row (buttons) - used to reserve space in the text editor
    private var bottomContentRowHeight: CGFloat {
        // Submit button is 24x24, inline picker buttons are ~24 tall
        // This value + contentPadding = scroll view bottom inset
        // Button visual height is 24 + 11 (contentPadding) = 35px
        // We add a small buffer (6px) for breathing room between text and buttons
        // Total bottom inset will be: contentPadding (11) + this value = 41px
        // This leaves 80 - 22 - 30 = 28px for text content (enough for 1 line)
        (onSubmit != nil) ? 30 : 24
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SimpleTextEditor(
                text: $text,
                baseFont: baseFont,
                baseTextColor: baseTextColor,
                backgroundColor: backgroundColor,
                contentPadding: contentPadding,
                bottomContentHeight: bottomContentRowHeight,
                onAttachment: onAttachment,
                onImageAttachment: onImageAttachment,
                onHeightChange: autoExpand ? { newHeight in
                    contentHeight = newHeight
                } : nil,
                onAutocompleteRequest: onAutocompleteRequest,
                onTextChange: onTextChange,
                onSubmit: onSubmit,
                onDownArrow: onDownArrow,
                onUpArrow: onUpArrow,
                onEnterOverride: onEnterOverride,
                onInputFocus: onInputFocus,
                onDragStateChanged: { isDragging in
                    isDragHighlighted = isDragging
                }
            )

            // Bottom row with leading content (source picker) and trailing submit button
            HStack(alignment: .bottom) {
                bottomLeadingContent
                    .padding(.leading, contentPadding)

                Spacer()

                if onSubmit != nil {
                    submitButton
                        .padding(.trailing, contentPadding + 2)
                }
            }
            .padding(.bottom, contentPadding)
        }
        .frame(height: displayedHeight > 0 ? displayedHeight : minHeight)
        .background(backgroundMaterial)
        .overlay {
            // Tint overlay for color customization
            tintOverlayColor
                .opacity(tintOverlayOpacity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
        .overlay {
            if let borderColor = borderColor {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Drag and drop highlight overlay - covers full container
            if isDragHighlighted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.accent.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppColors.accent, lineWidth: 2)
                    )
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            // Only reset to minHeight if there's no text content
            // This preserves the height when the view reappears with existing text
            if text.isEmpty {
                displayedHeight = minHeight
            } else if displayedHeight == 0 {
                // View is being recreated with existing text - use minHeight initially
                // and let the content height calculation update it properly
                displayedHeight = minHeight
            }
            // If displayedHeight is already non-zero and text exists, keep current height
            // (the contentHeight callback will adjust if needed)
        }
        .onChange(of: contentHeight) { newHeight in
            let newEffectiveHeight = calculateEffectiveHeight(from: newHeight)
            if abs(newEffectiveHeight - displayedHeight) > 2 {
                let now = Date()
                let timeSinceLastChange = now.timeIntervalSince(lastHeightChangeTime)
                lastHeightChangeTime = now

                if timeSinceLastChange < 0.2 {
                    displayedHeight = newEffectiveHeight
                } else {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        displayedHeight = newEffectiveHeight
                    }
                }
            }
        }
        .onChange(of: text) { newText in
            if newText.isEmpty && displayedHeight != minHeight {
                withAnimation(.easeInOut(duration: 0.12)) {
                    displayedHeight = minHeight
                }
                contentHeight = 0
            }
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        Button {
            onSubmit?()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(submitButtonBackgroundColor)
                    .frame(width: 24, height: 24)

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(CircularProgressViewStyle(tint: AppColors.buttonText))
                        .frame(width: 12, height: 12)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(submitButtonForegroundColor)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(submitDisabled || isSubmitting)
        .onHover { hovering in
            isHoveringSubmitButton = hovering
            if hovering && !submitDisabled && !isSubmitting {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .allowsHitTesting(true)
        .zIndex(100)
        .help(isSubmitting ? "Submitting..." : "Submit")
    }

    private var submitButtonBackgroundColor: Color {
        if submitDisabled || isSubmitting {
            return AppColors.accent.opacity(0.5)
        }
        return isHoveringSubmitButton ? AppColors.accentSecondary : AppColors.accent
    }

    private var submitButtonForegroundColor: Color {
        if submitDisabled || isSubmitting {
            return AppColors.buttonText.opacity(0.6)
        }
        return AppColors.buttonText
    }
}

// MARK: - VibrantScrollView

/// NSScrollView subclass that enables vibrancy for NSVisualEffectView transparency support
class VibrantScrollView: NSScrollView {
    override var allowsVibrancy: Bool { true }
}

// MARK: - SimpleTextView (TextKit 2)

/// Custom NSTextView subclass using TextKit 2 for optimal performance
/// Handles paste, drag/drop, and keyboard events
class SimpleTextView: NSTextView {
    let lineThreshold = 4
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jules", category: "SimpleTextView")

    // MARK: - Vibrancy Support

    /// Enable vibrancy for NSVisualEffectView transparency support
    override var allowsVibrancy: Bool { true }

    private var isDragHighlighted = false
    private var tabKeyMonitor: Any?

    private static let supportedImageTypes: [NSPasteboard.PasteboardType] = [
        .tiff, .png,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        .fileURL
    ]

    /// Create a TextKit 2 text view
    convenience init() {
        // Create TextKit 2 components
        let textContentStorage = NSTextContentStorage()
        let textLayoutManager = NSTextLayoutManager()
        textContentStorage.addTextLayoutManager(textLayoutManager)

        let textContainer = NSTextContainer()
        textLayoutManager.textContainer = textContainer

        self.init(frame: .zero, textContainer: textContainer)
        registerForImageDraggedTypes()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForImageDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForImageDraggedTypes()
    }

    private func registerForImageDraggedTypes() {
        registerForDraggedTypes(Self.supportedImageTypes + [.string])
    }

    // MARK: - First Responder & Tab Key Monitor

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            setupTabKeyMonitor()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        removeTabKeyMonitor()
        return super.resignFirstResponder()
    }

    /// Install a local event monitor to intercept Tab before the window handles it
    private func setupTabKeyMonitor() {
        guard tabKeyMonitor == nil else { return }

        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only handle Tab (keyCode 48) with no modifiers when we're first responder
            guard event.keyCode == 48,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  self.window?.firstResponder === self else {
                return event
            }

            // Handle Tab for autocomplete
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                if coordinator.handleTabKeyForAutocomplete(textView: self) {
                    return nil // Consume the event
                }
            }

            // If not handled, let the event pass through for normal tab insertion
            return event
        }
    }

    private func removeTabKeyMonitor() {
        if let monitor = tabKeyMonitor {
            NSEvent.removeMonitor(monitor)
            tabKeyMonitor = nil
        }
    }

    deinit {
        removeTabKeyMonitor()
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if containsImage(in: sender.draggingPasteboard) {
            isDragHighlighted = true
            notifyDragStateChanged(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if containsImage(in: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if isDragHighlighted {
            isDragHighlighted = false
            notifyDragStateChanged(false)
        }
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        if let image = extractImage(from: pasteboard) {
            isDragHighlighted = false
            notifyDragStateChanged(false)

            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                coordinator.handleDroppedImage(image: image)
                return true
            }
        }

        isDragHighlighted = false
        notifyDragStateChanged(false)
        return super.performDragOperation(sender)
    }

    private func notifyDragStateChanged(_ isDragging: Bool) {
        if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
            coordinator.handleDragStateChanged(isDragging: isDragging)
        }
    }

    // MARK: - Keyboard Handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Override doCommand to intercept Tab key at an earlier point in the responder chain.
    /// This is called by interpretKeyEvents: before insertTab: and gives us more reliable
    /// interception in SwiftUI-hosted NSViews.
    override func doCommand(by selector: Selector) {
        if selector == #selector(insertTab(_:)) {
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                if coordinator.handleTabKeyForAutocomplete(textView: self) {
                    return
                }
            }
        }
        super.doCommand(by: selector)
    }

    /// Override insertTab to handle Tab key for autocomplete.
    /// This is called by NSTextView's input system when Tab is pressed,
    /// which may bypass keyDown in SwiftUI-hosted NSViews.
    override func insertTab(_ sender: Any?) {
        if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
            if coordinator.handleTabKeyForAutocomplete(textView: self) {
                return
            }
        }
        // If not handled by autocomplete, insert a tab character
        super.insertTab(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Enter/Return key for submit (keyCode 36 is Return, 76 is Enter on numpad)
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                // Check for enter override first (e.g., list selection)
                if coordinator.handleEnterOverride() {
                    return
                }
                // Fall through to normal submit
                if coordinator.handleEnterKeyForSubmit() {
                    return
                }
            }
        }

        // Tab for autocomplete (fallback - insertTab: is the primary handler)
        if event.keyCode == 48 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                if coordinator.handleTabKeyForAutocomplete(textView: self) {
                    return
                }
            }
        }

        // Arrow keys for autocomplete navigation or list navigation
        if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
            let autocompleteManager = FilenameAutocompleteManager.shared
            let handled = MainActor.assumeIsolated {
                // If autocomplete is active, use arrow keys for autocomplete navigation
                if autocompleteManager.isAutocompleteActive {
                    switch event.keyCode {
                    case 126: autocompleteManager.selectPrevious(); return true
                    case 125: autocompleteManager.selectNext(); return true
                    case 53: autocompleteManager.clearSuggestions(); return true
                    default: return false
                    }
                }

                // Up arrow for list navigation
                if event.keyCode == 126 {
                    return coordinator.handleUpArrowForNavigation()
                }

                // Down arrow for list navigation
                if event.keyCode == 125 {
                    return coordinator.handleDownArrowForNavigation()
                }

                return false
            }

            if handled { return }
        }

        super.keyDown(with: event)
    }

    // MARK: - Image Handling

    private func containsImage(in pasteboard: NSPasteboard) -> Bool {
        // Check for specific image types
        if pasteboard.data(forType: .tiff) != nil ||
           pasteboard.data(forType: .png) != nil ||
           pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) != nil ||
           pasteboard.data(forType: NSPasteboard.PasteboardType("public.heic")) != nil {
            return true
        }

        // Check for image file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if isImageFile(url: url) { return true }
            }
        }

        // Check if pasteboard can provide any image type (covers browsers, screenshot tools, etc.)
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }

        return false
    }

    private func extractImage(from pasteboard: NSPasteboard) -> NSImage? {
        // IMPORTANT: Check file URLs FIRST before raw image data
        // When copying a file from Finder, the pasteboard contains both:
        // 1. A file URL pointing to the actual image file
        // 2. TIFF data representing the FILE ICON (not the image content!)
        // If we check raw image data first, we get the icon instead of the actual image.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if isImageFile(url: url), let image = NSImage(contentsOf: url) {
                    return realizeImage(image)
                }
            }
        }

        // Try specific image types for copied image data (not files)
        // This handles screenshots, images copied from browsers, etc.
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) { return image }
        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) { return image }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")), let image = NSImage(data: data) { return image }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.heic")), let image = NSImage(data: data) { return image }

        // Fallback: Use NSImage's built-in pasteboard support which handles many image types
        // This catches images from browsers, screenshot tools, and other applications
        if let image = NSImage(pasteboard: pasteboard), image.isValid {
            // Force-load the image by creating a concrete bitmap representation
            // NSImage(pasteboard:) can return lazy images that don't render properly
            return realizeImage(image)
        }

        return nil
    }

    /// Converts a potentially lazy-loaded NSImage into a concrete bitmap image
    /// This ensures images from the pasteboard are fully loaded before use
    private func realizeImage(_ image: NSImage) -> NSImage? {
        guard image.isValid else { return nil }

        // Get the best representation size
        var imageRect = CGRect(origin: .zero, size: image.size)

        // If size is zero, try to get it from representations
        if imageRect.size.width == 0 || imageRect.size.height == 0 {
            if let rep = image.representations.first {
                imageRect.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }

        // Still no valid size? Can't realize this image
        guard imageRect.size.width > 0 && imageRect.size.height > 0 else { return nil }

        // Draw the image into a new CGImage to force loading
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return nil
        }

        // Create a new NSImage from the realized CGImage
        return NSImage(cgImage: cgImage, size: imageRect.size)
    }

    private func isImageFile(url: URL) -> Bool {
        let exts = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "heif", "webp", "bmp"]
        return exts.contains(url.pathExtension.lowercased())
    }

    // MARK: - Code Detection

    private static let codePatterns: [NSRegularExpression] = {
        let patterns = [
            #"(func|function|def|fn)\s+\w+\s*\("#,
            #"(class|struct|enum|interface|protocol|impl)\s+\w+"#,
            #"(const|let|var|val|int|float|double|string|bool|char)\s+\w+\s*="#,
            #"^(import|from|require|include|using|package)\s+"#,
            #"(if|else|for|while|switch|match|case|try|catch)\s*[\(\{:]"#,
            #"return\s+[^;]*[;]?"#,
            #"(=>|->)\s*[\{\(]?"#,
            #"(//|/\*|#\s|\*\s|<!--)"#,
            #"[=!<>]=|&&|\|\||[+\-*/]=|::"#,
            #"[\[\{]\s*[\"\']?\w+[\"\']?\s*[:,]"#,
            #";\s*$"#,
            #"^(\t|    )\s*\w"#,
            #"\.\w+\([^)]*\)\s*\.\w+\("#,
            #":\s*(string|number|boolean|int|float|void|any|Self|self)\b"#,
            #"^[@#]\w+(\(|$)"#,
            #"^\$\s+\w+"#,
            #"<\/?\w+[^>]*>"#,
            #"\"\w+\"\s*:\s*[\"\d\[\{]"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }()

    private func looksLikeCode(_ text: String) -> Bool {
        var matchCount = 0
        for regex in Self.codePatterns {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                matchCount += 1
                if matchCount >= 2 { return true }
            }
        }
        return false
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        if let image = extractImage(from: pasteboard) {
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                coordinator.handleDroppedImage(image: image)
                return
            }
            NSSound.beep()
            return
        }

        guard let pastedString = pasteboard.string(forType: .string), !pastedString.isEmpty else {
            NSSound.beep()
            return
        }

        let lineCount = pastedString.components(separatedBy: .newlines).count
        let isCode = looksLikeCode(pastedString)

        if lineCount > lineThreshold && isCode {
            if let coordinator = self.delegate as? SimpleTextEditor.Coordinator {
                coordinator.handlePastedAttachment(content: pastedString)
            } else {
                insertTextDirectly(pastedString)
            }
        } else {
            insertTextDirectly(pastedString)
        }
    }

    private func insertTextDirectly(_ text: String) {
        let selectedRange = self.selectedRange()

        if self.shouldChangeText(in: selectedRange, replacementString: text) {
            // For TextKit 2, use the text content storage
            if let textContentStorage = self.textContentStorage {
                let nsRange = selectedRange
                textContentStorage.performEditingTransaction {
                    textContentStorage.textStorage?.replaceCharacters(in: nsRange, with: text)
                }
            } else if let textStorage = self.textStorage {
                textStorage.replaceCharacters(in: selectedRange, with: text)
            }
            self.didChangeText()

            let newCursorPosition = selectedRange.location + text.utf16.count
            self.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - SimpleTextEditor (NSViewRepresentable)

/// A high-performance text editor using TextKit 2
/// DECOUPLED: Does not depend on DataManager - uses callback handlers instead
struct SimpleTextEditor: NSViewRepresentable {
    @Binding var text: String

    let baseFont: NSFont
    let baseTextColor: NSColor
    let backgroundColor: NSColor
    let contentPadding: CGFloat

    /// Extra bottom padding to reserve space for overlaid content (e.g., buttons)
    let bottomContentHeight: CGFloat

    var onAttachment: ((String) -> Void)?
    var onImageAttachment: ((NSImage) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onAutocompleteRequest: ((String) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onEnterOverride: (() -> Bool)?
    var onInputFocus: (() -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    init(
        text: Binding<String>,
        baseFont: NSFont? = nil,
        baseTextColor: NSColor? = nil,
        backgroundColor: NSColor? = nil,
        contentPadding: CGFloat = 6,
        bottomContentHeight: CGFloat = 0,
        onAttachment: ((String) -> Void)? = nil,
        onImageAttachment: ((NSImage) -> Void)? = nil,
        onHeightChange: ((CGFloat) -> Void)? = nil,
        onAutocompleteRequest: ((String) -> Void)? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onSubmit: (() -> Void)? = nil,
        onDownArrow: (() -> Void)? = nil,
        onUpArrow: (() -> Void)? = nil,
        onEnterOverride: (() -> Bool)? = nil,
        onInputFocus: (() -> Void)? = nil,
        onDragStateChanged: ((Bool) -> Void)? = nil
    ) {
        self._text = text
        self.baseFont = baseFont ?? .systemFont(ofSize: 14, weight: .regular)
        self.baseTextColor = baseTextColor ?? .labelColor
        self.backgroundColor = backgroundColor ?? .textBackgroundColor
        self.contentPadding = contentPadding
        self.bottomContentHeight = bottomContentHeight
        self.onAttachment = onAttachment
        self.onImageAttachment = onImageAttachment
        self.onHeightChange = onHeightChange
        self.onAutocompleteRequest = onAutocompleteRequest
        self.onTextChange = onTextChange
        self.onSubmit = onSubmit
        self.onDownArrow = onDownArrow
        self.onUpArrow = onUpArrow
        self.onEnterOverride = onEnterOverride
        self.onInputFocus = onInputFocus
        self.onDragStateChanged = onDragStateChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            parent: self,
            baseFont: baseFont,
            baseTextColor: baseTextColor,
            onAttachment: onAttachment,
            onImageAttachment: onImageAttachment,
            onHeightChange: onHeightChange,
            onAutocompleteRequest: onAutocompleteRequest,
            onTextChange: onTextChange,
            onSubmit: onSubmit,
            onDownArrow: onDownArrow,
            onUpArrow: onUpArrow,
            onEnterOverride: onEnterOverride,
            onInputFocus: onInputFocus,
            onDragStateChanged: onDragStateChanged
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = VibrantScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        // Use extra bottom padding to reserve space for overlaid content (buttons)
        let bottomInset = contentPadding + bottomContentHeight
        scrollView.contentInsets = NSEdgeInsets(top: contentPadding, left: contentPadding, bottom: bottomInset, right: contentPadding)

        // Create TextKit 2 text view
        let textView = SimpleTextView()

        // Basic configuration
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false

        // Appearance
        textView.font = baseFont
        textView.textColor = baseTextColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        // Use a more visible insertion point color with higher contrast
        textView.insertionPointColor = AppColors.accent.toNSColor()

        // Layout
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            // Set height to infinity for vertical growth, but let width track the text view
            textContainer.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        textView.string = text

        // Set delegate
        textView.delegate = context.coordinator

        // Store reference to text view for focus management
        context.coordinator.textViewReference = textView

        // Report initial height
        DispatchQueue.main.async {
            if let onHeightChange = context.coordinator.onHeightChange {
                let contentHeight = context.coordinator.calculateContentHeight(for: textView)
                onHeightChange(contentHeight)
            }
        }

        // Set up notification observer for menu open to auto-focus
        context.coordinator.setupMenuOpenObserver()

        // Focus immediately on creation - the menu is already open when this view is created
        // (the .menuDidOpen notification fires before this view exists, so we can't rely on it)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.focusTextView()
        }

        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushPendingUpdates()
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = nil
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // CRITICAL FIX: Update coordinator callbacks when the view is recreated.
        // Without this, when the user paginates to a different session, the coordinator
        // keeps the old callbacks that reference the original session, causing messages
        // to be posted to the wrong session.
        context.coordinator.parent = self
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onAttachment = onAttachment
        context.coordinator.onImageAttachment = onImageAttachment
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onAutocompleteRequest = onAutocompleteRequest
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onDownArrow = onDownArrow
        context.coordinator.onUpArrow = onUpArrow
        context.coordinator.onEnterOverride = onEnterOverride
        context.coordinator.onInputFocus = onInputFocus
        context.coordinator.onDragStateChanged = onDragStateChanged

        // Check if autocomplete is inserting text (via menu click or Tab)
        // When pendingCursorPosition is set, autocomplete has updated the text binding
        // and we must apply it, even if there's pending typed text
        let autocompleteManager = FilenameAutocompleteManager.shared
        let isAutocompleteInserting = autocompleteManager.pendingCursorPosition != nil

        // Skip during typing bursts UNLESS autocomplete is inserting
        // Autocomplete insertions must take precedence over pending typed text
        if !isAutocompleteInserting {
            if context.coordinator.isInTypingBurst && context.coordinator.pendingText != nil {
                return
            }
        }

        // Update text from binding if needed
        // Allow update if: text differs AND (no pending text OR autocomplete is inserting)
        if textView.string != text && !context.coordinator.isProcessingEdit && (context.coordinator.pendingText == nil || isAutocompleteInserting) {
            // If autocomplete is inserting, cancel any pending text sync that would overwrite it
            if isAutocompleteInserting && context.coordinator.pendingText != nil {
                context.coordinator.textUpdateWorkItem?.cancel()
                context.coordinator.pendingText = nil
            }
            context.coordinator.textUpdateWorkItem?.cancel()
            context.coordinator.lastSyncedText = text

            let selectedRange = textView.selectedRange()

            // Use TextKit 2 API if available
            if let textContentStorage = textView.textContentStorage {
                textContentStorage.performEditingTransaction {
                    textContentStorage.textStorage?.replaceCharacters(
                        in: NSRange(location: 0, length: textView.string.utf16.count),
                        with: text
                    )
                }
            } else if let textStorage = textView.textStorage {
                textStorage.replaceCharacters(in: NSRange(location: 0, length: textView.string.utf16.count), with: text)
            }

            // Check if autocomplete set a pending cursor position
            let autocompleteManager = FilenameAutocompleteManager.shared
            let newLocation: Int
            if let pendingPosition = autocompleteManager.pendingCursorPosition {
                // Use the pending cursor position from autocomplete
                newLocation = min(pendingPosition, text.utf16.count)
                autocompleteManager.pendingCursorPosition = nil
            } else {
                // Default: try to preserve cursor position
                let newLength = text.utf16.count
                newLocation = min(selectedRange.location, newLength)
            }
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
        }

        // Update appearance (scroll view background stays clear for vibrancy support)
        if textView.font != baseFont { textView.font = baseFont }
        if textView.textColor != baseTextColor { textView.textColor = baseTextColor }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SimpleTextEditor
        var onAttachment: ((String) -> Void)?
        var onImageAttachment: ((NSImage) -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var onAutocompleteRequest: ((String) -> Void)?
        var onTextChange: ((String) -> Void)?
        var onSubmit: (() -> Void)?
        var onDownArrow: (() -> Void)?
        var onUpArrow: (() -> Void)?
        var onEnterOverride: (() -> Bool)?
        var onInputFocus: (() -> Void)?
        var onDragStateChanged: ((Bool) -> Void)?

        let defaultAttributes: [NSAttributedString.Key: Any]
        var isProcessingEdit = false
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jules", category: "SimpleTextEditor")

        // Text update debouncing
        var textUpdateWorkItem: DispatchWorkItem?
        var pendingText: String?
        var lastSyncedText: String = ""
        private let textBindingDebounceDelay: TimeInterval = 0.016

        // Typing burst detection
        var isInTypingBurst: Bool = false
        private var lastTypingBurstTime: CFAbsoluteTime = 0
        private let typingBurstCooldown: CFAbsoluteTime = 0.15

        // Height calculation
        private var heightCalculationWorkItem: DispatchWorkItem?
        private var lastReportedHeight: CGFloat = 0

        // Autocomplete
        private var currentWordRange: NSRange?

        // Tab key processing guard to prevent multiple handlers from processing the same event
        private var isProcessingTabKey = false

        // Focus management
        weak var textViewReference: NSTextView?
        private var menuOpenObserver: NSObjectProtocol?

        init(
            parent: SimpleTextEditor,
            baseFont: NSFont,
            baseTextColor: NSColor,
            onAttachment: ((String) -> Void)?,
            onImageAttachment: ((NSImage) -> Void)?,
            onHeightChange: ((CGFloat) -> Void)?,
            onAutocompleteRequest: ((String) -> Void)?,
            onTextChange: ((String) -> Void)?,
            onSubmit: (() -> Void)?,
            onDownArrow: (() -> Void)?,
            onUpArrow: (() -> Void)?,
            onEnterOverride: (() -> Bool)?,
            onInputFocus: (() -> Void)?,
            onDragStateChanged: ((Bool) -> Void)?
        ) {
            self.parent = parent
            self.onAttachment = onAttachment
            self.onImageAttachment = onImageAttachment
            self.onHeightChange = onHeightChange
            self.onAutocompleteRequest = onAutocompleteRequest
            self.onTextChange = onTextChange
            self.onSubmit = onSubmit
            self.onDownArrow = onDownArrow
            self.onUpArrow = onUpArrow
            self.onEnterOverride = onEnterOverride
            self.onInputFocus = onInputFocus
            self.onDragStateChanged = onDragStateChanged
            self.defaultAttributes = [.font: baseFont, .foregroundColor: baseTextColor]
            self.lastSyncedText = parent.text
            super.init()
        }

        deinit {
            textUpdateWorkItem?.cancel()
            heightCalculationWorkItem?.cancel()
            textUpdateWorkItem = nil
            heightCalculationWorkItem = nil
            pendingText = nil
            if let observer = menuOpenObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Set up observer to auto-focus text view when menu opens
        func setupMenuOpenObserver() {
            // Remove any existing observer first
            if let existing = menuOpenObserver {
                NotificationCenter.default.removeObserver(existing)
            }

            menuOpenObserver = NotificationCenter.default.addObserver(
                forName: .menuDidOpen,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Small delay to allow the view hierarchy to stabilize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.focusTextView()
                }
            }
        }

        /// Focus the text view (make it first responder)
        func focusTextView() {
            guard let textView = textViewReference else { return }
            guard let window = textView.window else { return }
            _ = window.makeFirstResponder(textView)
        }

        func flushPendingUpdates() {
            textUpdateWorkItem?.cancel()
            textUpdateWorkItem = nil
            if pendingText != nil {
                syncTextToParent()
            }
        }

        private func syncTextToParent() {
            guard let pendingText = pendingText else { return }
            if pendingText != lastSyncedText {
                lastSyncedText = pendingText
                parent.text = pendingText
            }
            self.pendingText = nil
        }

        // MARK: - NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Notify that user clicked in the text input (changed selection)
            if let onInputFocus = onInputFocus {
                Task { @MainActor in
                    onInputFocus()
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isProcessingEdit else { return }
            let newText = textView.string

            // Track typing burst
            let currentTime = CFAbsoluteTimeGetCurrent()
            let timeSinceLastTyping = currentTime - lastTypingBurstTime
            lastTypingBurstTime = currentTime
            isInTypingBurst = timeSinceLastTyping < typingBurstCooldown

            // Debounce text binding updates
            pendingText = newText
            textUpdateWorkItem?.cancel()

            let textWorkItem = DispatchWorkItem { [weak self] in
                self?.syncTextToParent()
            }
            textUpdateWorkItem = textWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + textBindingDebounceDelay, execute: textWorkItem)

            // Skip autocomplete during typing bursts or when Tab-only mode is enabled
            // However, if autocomplete menu is already open, continue refining results
            let isAutocompleteActive = MainActor.assumeIsolated {
                FilenameAutocompleteManager.shared.isAutocompleteActive
            }
            let shouldUpdateAutocomplete = !isInTypingBurst && (!FilenameAutocompleteManager.tabOnlyTrigger || isAutocompleteActive)

            // Get the current word prefix for autocomplete
            let prefix = getCurrentWordPrefix(in: textView)
            let hasValidPrefix = prefix != nil && prefix!.count >= 2

            if hasValidPrefix && shouldUpdateAutocomplete {
                // Get owner ID for this text input
                let ownerId = ObjectIdentifier(textView)

                // Keep pendingWordRange up to date when user continues typing with menu open
                // This ensures menu selection replaces the current word, not the stale range from Tab press
                if isAutocompleteActive, let range = currentWordRange {
                    MainActor.assumeIsolated {
                        let manager = FilenameAutocompleteManager.shared
                        // Verify this text input owns the autocomplete session before updating range
                        // If we're typing in a different text input, claim ownership (clears stale session)
                        if !manager.isOwner(ownerId) {
                            manager.setOwner(ownerId)
                        }
                        manager.pendingWordRange = range
                    }
                }

                // If onTextChange is provided, call it; otherwise update autocomplete directly
                // This ensures refinement works even when onTextChange is nil (Tab-only mode)
                if let onTextChange = self.onTextChange {
                    Task { @MainActor in
                        onTextChange(prefix!)
                    }
                } else if isAutocompleteActive {
                    // Menu is open but onTextChange is nil - update suggestions directly
                    Task { @MainActor in
                        FilenameAutocompleteManager.shared.updateSuggestions(for: prefix!)
                    }
                }
            } else if !hasValidPrefix && isAutocompleteActive {
                // No valid prefix (less than 2 chars) and menu is open - close it immediately
                // Do this regardless of typing burst to provide responsive feedback
                // Only clear if this text input owns the session
                let ownerId = ObjectIdentifier(textView)
                Task { @MainActor in
                    let manager = FilenameAutocompleteManager.shared
                    if manager.isOwner(ownerId) {
                        manager.clearSuggestions()
                    }
                }
            }

            // Debounced height calculation
            // Always recalculate height - text wrapping can change visual height
            // without changing the newline count
            if let onHeightChange = self.onHeightChange {
                heightCalculationWorkItem?.cancel()

                let workItem = DispatchWorkItem { [weak self, weak textView] in
                    guard let self = self, let textView = textView else { return }
                    let contentHeight = self.calculateContentHeight(for: textView)
                    if abs(contentHeight - self.lastReportedHeight) > 1.0 {
                        self.lastReportedHeight = contentHeight
                        onHeightChange(contentHeight)
                    }
                }
                heightCalculationWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
            }
        }

        func calculateContentHeight(for textView: NSTextView) -> CGFloat {
            // TextKit 2: Use textLayoutManager
            if let textLayoutManager = textView.textLayoutManager,
               let textContentStorage = textView.textContentStorage {
                // Ensure the text container has the correct width for layout calculation
                if let textContainer = textLayoutManager.textContainer {
                    let containerWidth = textView.bounds.width - textView.textContainerInset.width * 2
                    if containerWidth > 0 && textContainer.size.width != containerWidth {
                        textContainer.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
                    }
                }

                // Force layout for the entire document
                textLayoutManager.ensureLayout(for: textContentStorage.documentRange)

                // Calculate height by finding the maximum Y of all layout fragments
                var height: CGFloat = 0
                textLayoutManager.enumerateTextLayoutFragments(
                    from: textContentStorage.documentRange.location,
                    options: [.ensuresLayout, .ensuresExtraLineFragment]
                ) { fragment in
                    height = max(height, fragment.layoutFragmentFrame.maxY)
                    return true
                }

                // If we got a valid height, return it
                if height > 0 {
                    return height
                }

                // Fallback: use the text view's layout manager usage rect for TextKit 2
                if let textContainer = textLayoutManager.textContainer {
                    return textLayoutManager.usageBoundsForTextContainer.height
                }
            }

            // Fallback to TextKit 1
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return 0
            }

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            if glyphRange.length == 0 && textView.string.isEmpty {
                return 0
            }

            let usedRect = layoutManager.usedRect(for: textContainer)
            return usedRect.height
        }

        // MARK: - Attachment Handlers

        func handlePastedAttachment(content: String) {
            Task { @MainActor [weak self] in
                self?.onAttachment?(content)
            }
        }

        func handleDroppedImage(image: NSImage) {
            Task { @MainActor [weak self] in
                self?.onImageAttachment?(image)
            }
        }

        func handleDragStateChanged(isDragging: Bool) {
            Task { @MainActor [weak self] in
                self?.onDragStateChanged?(isDragging)
            }
        }

        // MARK: - Submit Handler

        func handleEnterKeyForSubmit() -> Bool {
            guard let onSubmit = onSubmit else {
                return false
            }

            Task { @MainActor in
                onSubmit()
            }
            return true
        }

        // MARK: - Navigation Handlers

        func handleDownArrowForNavigation() -> Bool {
            guard let onDownArrow = onDownArrow else {
                return false
            }

            Task { @MainActor in
                onDownArrow()
            }
            return true
        }

        func handleUpArrowForNavigation() -> Bool {
            guard let onUpArrow = onUpArrow else {
                return false
            }

            Task { @MainActor in
                onUpArrow()
            }
            return true
        }

        func handleEnterOverride() -> Bool {
            guard let onEnterOverride = onEnterOverride else {
                return false
            }

            // Call synchronously since we need the return value
            return onEnterOverride()
        }

        // MARK: - Autocomplete

        func handleTabKeyForAutocomplete(textView: NSTextView) -> Bool {
            // Guard against multiple handlers processing the same Tab key event
            // This can happen because we have multiple interception points (local monitor, doCommand, insertTab, keyDown)
            guard !isProcessingTabKey else {
                return true // Already being processed, consume the event
            }

            isProcessingTabKey = true
            defer { isProcessingTabKey = false }

            let autocompleteManager = FilenameAutocompleteManager.shared
            // Use the textView's ObjectIdentifier as the owner ID to uniquely identify this text input
            let ownerId = ObjectIdentifier(textView)

            let acceptedFilename = MainActor.assumeIsolated { () -> String? in
                if autocompleteManager.isAutocompleteActive {
                    // Use ownership-aware accept - returns nil if this text input doesn't own the session
                    return autocompleteManager.acceptSelection(ownerId: ownerId)
                }
                return nil
            }

            if let selectedFilename = acceptedFilename {
                replaceCurrentWord(in: textView, with: selectedFilename)
                return true
            }

            guard let prefix = getCurrentWordPrefix(in: textView) else {
                return false
            }

            if let onAutocompleteRequest = onAutocompleteRequest {
                // Set ownership and store the word range for use by menu selection
                MainActor.assumeIsolated {
                    autocompleteManager.setOwner(ownerId)
                    autocompleteManager.pendingWordRange = currentWordRange
                }

                Task { @MainActor in
                    onAutocompleteRequest(prefix)
                }

                // Note: We intentionally don't auto-select single matches here.
                // This prevents the "double-tab" feel where a single Tab both shows
                // suggestions AND selects. Users should press Tab again to select.

                return true
            }

            return false
        }

        func getCurrentWordPrefix(in textView: NSTextView) -> String? {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString

            guard selectedRange.length == 0 else { return nil }

            let cursorPosition = selectedRange.location
            guard cursorPosition > 0 else { return nil }

            var wordStart = cursorPosition
            while wordStart > 0 {
                let charIndex = wordStart - 1
                let char = text.character(at: charIndex)
                let scalar = UnicodeScalar(char)!

                if CharacterSet.alphanumerics.contains(scalar) ||
                   char == UInt16(UnicodeScalar("_").value) {
                    wordStart -= 1
                } else {
                    break
                }
            }

            let wordLength = cursorPosition - wordStart
            guard wordLength >= 2 else { return nil }

            let wordRange = NSRange(location: wordStart, length: wordLength)
            currentWordRange = wordRange
            return text.substring(with: wordRange)
        }

        func replaceCurrentWord(in textView: NSTextView, with replacement: String) {
            guard let wordRange = currentWordRange ?? findCurrentWordRange(in: textView) else {
                return
            }

            let text = textView.string as NSString
            guard wordRange.location + wordRange.length <= text.length else { return }

            if textView.shouldChangeText(in: wordRange, replacementString: replacement) {
                if let textContentStorage = textView.textContentStorage {
                    textContentStorage.performEditingTransaction {
                        textContentStorage.textStorage?.replaceCharacters(in: wordRange, with: replacement)
                    }
                } else if let textStorage = textView.textStorage {
                    textStorage.replaceCharacters(in: wordRange, with: replacement)
                }
                textView.didChangeText()

                let newCursorPosition = wordRange.location + replacement.utf16.count
                textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
                currentWordRange = nil
            }
        }

        private func findCurrentWordRange(in textView: NSTextView) -> NSRange? {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString

            guard selectedRange.length == 0 else { return nil }

            let cursorPosition = selectedRange.location
            guard cursorPosition > 0 else { return nil }

            var wordStart = cursorPosition
            while wordStart > 0 {
                let charIndex = wordStart - 1
                let char = text.character(at: charIndex)
                let scalar = UnicodeScalar(char)!

                if CharacterSet.alphanumerics.contains(scalar) ||
                   char == UInt16(UnicodeScalar("_").value) {
                    wordStart -= 1
                } else {
                    break
                }
            }

            let wordLength = cursorPosition - wordStart
            guard wordLength > 0 else { return nil }

            return NSRange(location: wordStart, length: wordLength)
        }
    }
}

// MARK: - Backwards Compatibility Alias

/// Alias for backwards compatibility - use SimpleTextEditorContainer instead
typealias PatternHighlightTextEditorContainer = SimpleTextEditorContainer

// MARK: - Convenience Extension for EmptyView default

extension SimpleTextEditorContainer where BottomLeadingContent == EmptyView {
    init(
        text: Binding<String>,
        baseFont: NSFont? = nil,
        baseTextColor: NSColor? = nil,
        backgroundColor: NSColor? = nil,
        backgroundMaterial: Material = .ultraThinMaterial,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.4,
        borderColor: Color? = nil,
        onSubmit: (() -> Void)? = nil,
        isSubmitting: Bool = false,
        submitDisabled: Bool = false,
        onAttachment: ((String) -> Void)? = nil,
        onImageAttachment: ((NSImage) -> Void)? = nil,
        autoExpand: Bool = false,
        minHeight: CGFloat = 80,
        maxHeight: CGFloat = 200,
        contentPadding: CGFloat = 6,
        onAutocompleteRequest: ((String) -> Void)? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onDownArrow: (() -> Void)? = nil,
        onUpArrow: (() -> Void)? = nil,
        onEnterOverride: (() -> Bool)? = nil,
        onInputFocus: (() -> Void)? = nil
    ) {
        self._text = text
        self.baseFont = baseFont
        self.baseTextColor = baseTextColor
        self.backgroundColor = backgroundColor
        self.backgroundMaterial = backgroundMaterial
        self.tintOverlayColor = tintOverlayColor
        self.tintOverlayOpacity = tintOverlayOpacity
        self.borderColor = borderColor
        self.onSubmit = onSubmit
        self.isSubmitting = isSubmitting
        self.submitDisabled = submitDisabled
        self.onAttachment = onAttachment
        self.onImageAttachment = onImageAttachment
        self.autoExpand = autoExpand
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.contentPadding = contentPadding
        self.onAutocompleteRequest = onAutocompleteRequest
        self.onTextChange = onTextChange
        self.onDownArrow = onDownArrow
        self.onUpArrow = onUpArrow
        self.onEnterOverride = onEnterOverride
        self.onInputFocus = onInputFocus
        self.bottomLeadingContent = EmptyView()
    }
}
