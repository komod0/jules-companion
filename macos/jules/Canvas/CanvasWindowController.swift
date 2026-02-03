//
//  CanvasWindowController.swift
//  jules
//
//  Window controller for the image annotation canvas
//
//  Architecture Overview:
//  - Implements Normalized Coordinate System (0.0-1.0) for resolution independence
//  - Uses Finite State Machine (FSM) for annotation interaction states (Idle/Selected/Editing)
//  - Follows Dual-State Interaction Pattern to avoid gesture conflicts
//  - See CanvasStore.swift for detailed implementation
//

import SwiftUI
import AppKit

@available(macOS 14.0, *)
class CanvasWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var store: CanvasStore
    private var toolbarHostingView: NSHostingView<AnyView>?

    // Toolbar item identifier
    private static let customToolbarItemIdentifier = NSToolbarItem.Identifier("CanvasToolbarItem")

    init(image: NSImage, onFinish: @escaping (NSImage) -> Void) {
        self.store = CanvasStore(image: image)
        self.store.onFinish = onFinish

        super.init(window: nil)

        if #available(macOS 26.0, *) {
            setupTahoeWindow()
        } else {
            setupLegacyWindow()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Tahoe Window Setup (macOS 26+)

    @available(macOS 26.0, *)
    private func setupTahoeWindow() {
        let contentView = CanvasTahoeView(store: store, onFinish: { [weak self] in
            self?.handleFinish()
        })

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1000, height: 750))
        window.minSize = NSSize(width: 700, height: 500)
        window.center()
        window.title = ""

        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Disable movable by background - only the toolbar should drag the window
        window.isMovableByWindowBackground = false

        self.window = window
        window.delegate = self
    }

    // MARK: - Legacy Window Setup (macOS < 26)

    private func setupLegacyWindow() {
        // Create root view controller with visual effect background
        let rootViewController = NSViewController()
        let effectView = createAdaptiveEffectView(effectType: .underWindow)
        rootViewController.view = effectView

        // Create the main canvas content view (without toolbar)
        let canvasContentView = CanvasContentView(store: store)
        let canvasHostingController = NSHostingController(rootView: AnyView(canvasContentView))
        canvasHostingController.view.translatesAutoresizingMaskIntoConstraints = false

        // Add canvas view to effect view
        effectView.addSubview(canvasHostingController.view)

        // Create and configure window
        let window = NSWindow(contentViewController: rootViewController)
        window.setContentSize(NSSize(width: 1000, height: 750))
        window.minSize = NSSize(width: 700, height: 500)
        window.center()
        window.title = ""

        // Window style - matching SessionController
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Disable movable by background - only the toolbar should drag the window
        window.isMovableByWindowBackground = false

        self.window = window
        window.delegate = self

        // Setup toolbar view before creating toolbar
        setupToolbarView()

        // Create and configure toolbar with unified style (matches SessionController)
        let toolbar = NSToolbar(identifier: "CanvasToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Add constraints for canvas view (below toolbar area)
        NSLayoutConstraint.activate([
            canvasHostingController.view.topAnchor.constraint(equalTo: effectView.topAnchor, constant: CanvasToolbarView.toolbarHeight + 10),
            canvasHostingController.view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            canvasHostingController.view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            canvasHostingController.view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
        ])

        // Add child view controller
        rootViewController.addChild(canvasHostingController)
    }

    private func setupToolbarView() {
        let toolbarView = CanvasToolbarView(store: store, onFinish: { [weak self] in
            self?.handleFinish()
        })

        let hostingView = NSHostingView(rootView: AnyView(toolbarView))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: CanvasToolbarView.toolbarHeight)
        self.toolbarHostingView = hostingView
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.customToolbarItemIdentifier {
            let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            if let hostingView = toolbarHostingView {
                toolbarItem.view = hostingView
                toolbarItem.minSize = NSSize(width: 200, height: CanvasToolbarView.toolbarHeight)
                toolbarItem.maxSize = NSSize(width: 10000, height: CanvasToolbarView.toolbarHeight)
            }
            return toolbarItem
        }
        return nil
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.customToolbarItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.customToolbarItemIdentifier]
    }

    // MARK: - Actions

    private func handleFinish() {
        // Export the image and call the callback before closing
        store.finishEditingText()
        if let exportedImage = store.exportToImage() {
            store.onFinish?(exportedImage)
        }
        // Close window after callback is complete
        DispatchQueue.main.async { [weak self] in
            self?.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Cleanup if needed
    }
}

// MARK: - Canvas Content View (without toolbar, for legacy window)

@available(macOS 14.0, *)
struct CanvasContentView: View {
    @ObservedObject var store: CanvasStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            CanvasView(store: store)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Canvas Tahoe View (macOS 26+ with SwiftUI toolbar)

@available(macOS 26.0, *)
struct CanvasTahoeView: View {
    @ObservedObject var store: CanvasStore
    let onFinish: () -> Void

    @State private var showColorPicker = false

    private let colors: [Color] = [
        .purple, .red, .orange, .yellow, .green, .blue, .pink, .white, .black
    ]

    var body: some View {
        VStack(spacing: 0) {
            CanvasView(store: store)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Extend content under toolbar for glass effect (Mac Notes style)
        .ignoresSafeArea(edges: .top)
        // Glass toolbar overlay at top
        .overlay(alignment: .top) {
            ToolbarGlassOverlay()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Tool selection
                ForEach(CanvasTool.allCases) { tool in
                    Button(action: {
                        let previousTool = store.selectedTool
                        store.selectedTool = tool
                        if tool != .text {
                            store.finishEditingText()
                        }
                        if tool == .text && previousTool != .text && store.textAnnotations.isEmpty {
                            store.addTextAnnotationAtCenter()
                        }
                    }) {
                        Image(systemName: tool.systemImage)
                    }
                    .help(tool.rawValue)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Color picker
                Button(action: { showColorPicker.toggle() }) {
                    Circle()
                        .fill(store.selectedColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                }
                .popover(isPresented: $showColorPicker) {
                    HStack(spacing: 6) {
                        ForEach(colors, id: \.self) { color in
                            Button(action: { store.selectedColor = color }) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(store.selectedColor == color ? AppColors.accent : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }

                // Undo/Redo
                Button(action: { store.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .help("Undo (⌘Z)")

                Button(action: { store.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!store.canRedo)
                .help("Redo (⌘⇧Z)")

                Button(action: {
                    if let selectedId = store.selectedTextAnnotationId {
                        store.deleteTextAnnotation(id: selectedId)
                    }
                }) {
                    Image(systemName: "trash")
                }
                .disabled(store.selectedTextAnnotationId == nil)
                .help("Delete selected")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onFinish) {
                    Text("Done")
                }
                .padding(.horizontal, 6)
                .buttonStyle(.borderedProminent)
                .tint(AppColors.buttonBackground)
            }
        }
    }
}

// MARK: - Canvas Toolbar View (for legacy NSToolbar)

@available(macOS 14.0, *)
struct CanvasToolbarView: View {
    @ObservedObject var store: CanvasStore
    let onFinish: () -> Void

    @State private var isFinishHovering = false
    @State private var showColorPicker = false

    // Height for custom toolbar content (matches SessionController)
    static let toolbarHeight: CGFloat = 43

    private let colors: [Color] = [
        .purple, .red, .orange, .yellow, .green, .blue, .pink, .white, .black
    ]

    var body: some View {
        ZStack {
            // Background layer - allows window dragging
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Content layer
            HStack(spacing: 12) {
                // Tool selection
                toolSection

                Divider()
                    .frame(height: 28)

                // Tool-specific options
                toolOptionsSection

                Divider()
                    .frame(height: 28)

                // Color picker
                colorSection

                Divider()
                    .frame(height: 28)

                // Undo/Redo
                historySection

                Spacer()

                // Finish button
                finishButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 2) // Optical centering adjustment
        }
        .frame(height: Self.toolbarHeight)
    }

    // MARK: - Tool Section

    private var toolSection: some View {
        HStack(spacing: 4) {
            ForEach(CanvasTool.allCases) { tool in
                Button(action: {
                    let previousTool = store.selectedTool
                    store.selectedTool = tool
                    if tool != .text {
                        store.finishEditingText()
                    }
                    // When selecting text tool, auto-add a text annotation at center
                    if tool == .text && previousTool != .text && store.textAnnotations.isEmpty {
                        store.addTextAnnotationAtCenter()
                    }
                }) {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(store.selectedTool == tool ? AppColors.accent.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(store.selectedTool == tool ? AppColors.accent : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.buttonBackground)
                .help(tool.rawValue)
            }
        }
    }

    // MARK: - Tool Options Section

    @ViewBuilder
    private var toolOptionsSection: some View {
        switch store.selectedTool {
        case .draw:
            penSizeControl
        case .text:
            fontSizeControl
        case .select:
            if store.selectedTextAnnotationId != nil {
                fontSizeControl
            } else {
                // Keep empty space when nothing selected
                EmptyView()
            }
        }
    }

    private var penSizeControl: some View {
        HStack(spacing: 8) {
            Text("Size:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                ForEach([2.0, 4.0, 6.0, 10.0, 16.0], id: \.self) { size in
                    Button(action: {
                        store.penSize = size
                    }) {
                        Circle()
                            .fill(AppColors.buttonBackground)
                            .frame(width: size + 4, height: size + 4)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.penSize == size ? AppColors.accent.opacity(0.2) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(store.penSize == size ? AppColors.accent : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fontSizeControl: some View {
        HStack(spacing: 8) {
            Text("Font:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                Button(action: {
                    adjustFontSize(delta: -4)
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ToolbarButtonStyle())

                Text("\(Int(store.fontSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40)

                Button(action: {
                    adjustFontSize(delta: 4)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ToolbarButtonStyle())
            }
        }
    }

    /// Adjust font size with clamping and update selected annotation
    private func adjustFontSize(delta: CGFloat) {
        let newSize = max(12, min(72, store.fontSize + delta))
        store.fontSize = newSize
        if let id = store.selectedTextAnnotationId {
            store.updateTextAnnotationFontSize(id: id, fontSize: newSize)
        }
    }

    // MARK: - Color Section

    private var colorSection: some View {
        HStack(spacing: 4) {
            // Current color button
            Button(action: { showColorPicker.toggle() }) {
                Circle()
                    .fill(store.selectedColor)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            if showColorPicker {
                HStack(spacing: 3) {
                    ForEach(colors, id: \.self) { color in
                        Button(action: {
                            store.selectedColor = color
                        }) {
                            Circle()
                                .fill(color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            store.selectedColor == color ? AppColors.accent : Color.primary.opacity(0.2),
                                            lineWidth: store.selectedColor == color ? 2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        HStack(spacing: 4) {
            Button(action: { store.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(!store.canUndo)
            .help("Undo (⌘Z)")

            Button(action: { store.redo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(!store.canRedo)
            .help("Redo (⌘⇧Z)")

            Button(action: {
                if let selectedId = store.selectedTextAnnotationId {
                    store.deleteTextAnnotation(id: selectedId)
                }
            }) {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(store.selectedTextAnnotationId == nil)
            .help("Delete selected")
        }
    }

    // MARK: - Finish Button

    private var finishButton: some View {
        Button(action: onFinish) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Done")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(AppColors.buttonText)
            .opacity(isFinishHovering ? 1.0 : 0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(AppColors.buttonBackground)
            )
            .scaleEffect(isFinishHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isFinishHovering = hovering
            }
        }
    }
}

// MARK: - Canvas Source Context

/// Tracks where the canvas was opened from for proper navigation on close
@available(macOS 14.0, *)
enum CanvasSourceContext {
    case menuPopover  // Opened from the menu bar popover
    case sessionWindow(NSWindow)  // Opened from a session window
    case unknown
}

// MARK: - Canvas Window Manager

@available(macOS 14.0, *)
@MainActor
class CanvasWindowManager {
    static let shared = CanvasWindowManager()

    private var activeWindowController: CanvasWindowController?
    private var sourceContext: CanvasSourceContext = .unknown
    private var sourceWindow: NSWindow?

    private init() {}

    /// Opens a canvas window for annotating an image
    /// - Parameters:
    ///   - image: The image to annotate
    ///   - onFinish: Callback with the annotated image when finished
    func openCanvas(for image: NSImage, onFinish: @escaping (NSImage) -> Void) {
        // Close any existing canvas window
        activeWindowController?.close()

        // Capture the source window before opening canvas
        sourceWindow = NSApp.keyWindow

        // Determine source context based on the current key window
        if let keyWindow = NSApp.keyWindow {
            // Check if it's the popover's window (typically has specific characteristics)
            if keyWindow.styleMask.contains(.borderless) || keyWindow.level == .popUpMenu {
                sourceContext = .menuPopover
            } else {
                sourceContext = .sessionWindow(keyWindow)
            }
        } else {
            sourceContext = .menuPopover  // Default to popover if no key window
        }

        // Create new canvas window
        let controller = CanvasWindowController(image: image, onFinish: { [weak self] annotatedImage in
            onFinish(annotatedImage)
            self?.returnToSourceContext()
        })
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        activeWindowController = controller
    }

    /// Returns focus to the source context after canvas closes
    private func returnToSourceContext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            switch self.sourceContext {
            case .menuPopover:
                // For popover, just activate the app - popover will reappear if needed
                NSApp.activate(ignoringOtherApps: true)
            case .sessionWindow(let window):
                // Return to the session window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            case .unknown:
                NSApp.activate(ignoringOtherApps: true)
            }

            self.sourceContext = .unknown
            self.sourceWindow = nil
        }
    }

    /// Closes the active canvas window if any
    func closeCanvas() {
        activeWindowController?.close()
        activeWindowController = nil
        returnToSourceContext()
    }
}
