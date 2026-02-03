//
//  MergeConflictWindowController.swift
//  jules
//
//  Window controller for the merge conflict resolution window
//

import SwiftUI
import AppKit

// MARK: - Merge Conflict Window Controller

@available(macOS 14.0, *)
class MergeConflictWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var store: MergeConflictStore
    private var toolbarHostingView: NSHostingView<AnyView>?
    private var splitViewController: NSSplitViewController!

    // Toolbar item identifier
    private static let customToolbarItemIdentifier = NSToolbarItem.Identifier("MergeConflictToolbarItem")

    // MARK: - Initialization

    init(store: MergeConflictStore) {
        self.store = store

        super.init(window: nil)

        store.onClose = { [weak self] in
            self?.close()
        }

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
        let contentView = MergeConflictTahoeView(store: store, onClose: { [weak self] in
            self?.close()
        })

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        configureWindow(window)

        // Setup invisible NSToolbar to enable toolbar area glass effect
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("MergeConflictTahoeToolbar"))
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        self.window = window
        window.delegate = self
    }

    // MARK: - Legacy Window Setup (macOS < 26)

    private func setupLegacyWindow() {
        // Create split view controller for sidebar and content
        splitViewController = NSSplitViewController()

        // Create sidebar
        let sidebarView = MergeConflictSidebar(store: store)
        let sidebarHostingController = NSHostingController(
            rootView: AnyView(
                sidebarView
                    .frame(width: 250)
                    .unifiedBackground(material: .underWindowBackground, blendingMode: .behindWindow, tintOverlayOpacity: 0.5, effectType: .sidebar)
            )
        )

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        sidebarItem.minimumThickness = 250
        sidebarItem.maximumThickness = 250
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(200)

        // Create main content
        let contentView = MergeConflictContentView(store: store)
        let contentHostingController = NSHostingController(
            rootView: AnyView(contentView)
        )

        let contentItem = NSSplitViewItem(viewController: contentHostingController)
        contentItem.holdingPriority = NSLayoutConstraint.Priority(199)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)

        // Enable layer-backed views for smooth animation
        // NOTE: Using .center placement to prevent visual "sliding" artifacts when views
        // re-render. The .scaleProportionallyToFill placement caused cached content to
        // slide during re-renders because it tries to maintain aspect ratio during scaling.
        sidebarHostingController.view.wantsLayer = true
        sidebarHostingController.view.layerContentsRedrawPolicy = .duringViewResize
        sidebarHostingController.view.layerContentsPlacement = .center
        contentHostingController.view.wantsLayer = true
        contentHostingController.view.layerContentsRedrawPolicy = .duringViewResize
        contentHostingController.view.layerContentsPlacement = .center

        // Create root view controller with visual effect background
        let rootViewController = NSViewController()
        let effectView = createAdaptiveEffectView(effectType: .underWindow)
        rootViewController.view = effectView

        // Add tint overlay for unified background styling (only needed on macOS < 26)
        if #unavailable(macOS 26.0) {
            let tintOverlay = NSHostingView(rootView:
                AppColors.background
                    .opacity(0.5)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
            )
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: effectView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
            ])
        }

        // Create and configure window
        let window = NSWindow(contentViewController: rootViewController)
        configureWindow(window)

        // Setup toolbar
        setupToolbarView()
        let toolbar = NSToolbar(identifier: "MergeConflictToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Add split view controller as child
        rootViewController.addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(splitView)

        // Constraints for split view
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: effectView.topAnchor, constant: MergeConflictToolbarView.toolbarHeight + 10),
            splitView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
        ])

        splitView.wantsLayer = true

        self.window = window
        window.delegate = self
    }

    // MARK: - Window Configuration

    private func configureWindow(_ window: NSWindow) {
        // Match SessionController window size (1200x800)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.title = "Merge Conflicts"

        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
    }

    // MARK: - Toolbar Setup

    private func setupToolbarView() {
        let toolbarView = MergeConflictToolbarView(
            store: store,
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(toolbarView))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: MergeConflictToolbarView.toolbarHeight)
        self.toolbarHostingView = hostingView
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.customToolbarItemIdentifier {
            let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            if let hostingView = toolbarHostingView {
                toolbarItem.view = hostingView
                toolbarItem.minSize = NSSize(width: 200, height: MergeConflictToolbarView.toolbarHeight)
                toolbarItem.maxSize = NSSize(width: 10000, height: MergeConflictToolbarView.toolbarHeight)
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        MergeConflictWindowManager.shared.windowDidClose()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

// MARK: - Tahoe State for Merge Conflict Window

@available(macOS 26.0, *)
class MergeConflictTahoeState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    func toggle() {
        columnVisibility = columnVisibility == .all ? .detailOnly : .all
    }
}

// MARK: - Tahoe View (macOS 26+)

@available(macOS 26.0, *)
struct MergeConflictTahoeView: View {
    @ObservedObject var store: MergeConflictStore
    let onClose: () -> Void
    @StateObject private var tahoeState = MergeConflictTahoeState()

    private var subtitleText: String {
        if store.totalConflicts > 0 {
            let resolved = store.totalConflicts - store.totalUnresolvedConflicts
            return resolved == store.totalConflicts
                ? "All conflicts resolved"
                : "\(resolved) of \(store.totalConflicts) resolved"
        }
        return ""
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $tahoeState.columnVisibility) {
            MergeConflictSidebar(store: store)
                .navigationSplitViewColumnWidth(250)
                .glassEffect()
                .ignoresSafeArea(edges: .top)
        } detail: {
            MergeConflictContentView(store: store)
                .environment(\.glassToolbarEnabled, true)
                .ignoresSafeArea(edges: .top)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: {
                            withAnimation {
                                tahoeState.toggle()
                            }
                        }) {
                            Image(systemName: "sidebar.left")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { store.completeMerge() }) {
                            HStack(spacing: 6) {
                                if store.isMerging {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: store.allConflictsResolved ? "checkmark.circle.fill" : "arrow.triangle.merge")
                                }
                                Text("Merge")
                                    .fontWeight(.semibold)

                                if !store.allConflictsResolved {
                                    MergeBadge(count: store.totalUnresolvedConflicts)
                                }
                            }
                            .foregroundColor(store.allConflictsResolved ? AppColors.buttonText : AppColors.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(store.allConflictsResolved ? AppColors.buttonBackground : AppColors.backgroundSecondary)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.allConflictsResolved || store.isMerging)
                    }
                }
                .navigationTitle(Text("Merge Conflicts"))
                .navigationSubtitle(Text(subtitleText))
                .overlay(alignment: .top) {
                    ToolbarGlassOverlay()
                }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Merge Conflict Window Manager

@available(macOS 14.0, *)
@MainActor
class MergeConflictWindowManager {
    static let shared = MergeConflictWindowManager()

    private var activeWindowController: MergeConflictWindowController?
    private var sourceWindow: NSWindow?

    private init() {}

    /// Opens the merge conflict window
    /// - Parameters:
    ///   - store: The store containing conflict data (if nil, uses test data)
    ///   - onMergeComplete: Callback when merge is completed successfully
    func openWindow(store: MergeConflictStore? = nil, onMergeComplete: (() -> Void)? = nil) {
        // Close any existing window
        activeWindowController?.close()

        // Create or use provided store
        let conflictStore = store ?? {
            let testStore = MergeConflictStore()
            testStore.loadTestData()
            return testStore
        }()

        conflictStore.onMergeComplete = { [weak self] in
            onMergeComplete?()
            self?.activeWindowController?.close()
        }

        // Capture source window
        sourceWindow = NSApp.keyWindow

        // Create and show window
        let controller = MergeConflictWindowController(store: conflictStore)
        activeWindowController = controller

        // Show window and bring to front
        controller.showWindow(nil)
        if let window = controller.window {
            // Make this window key and bring to front
            window.makeKeyAndOrderFront(nil)
        }

        // Activate the application to ensure window focus
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when the window closes
    func windowDidClose() {
        // Return focus to source window
        if let sourceWindow = sourceWindow {
            sourceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        activeWindowController = nil
        sourceWindow = nil
    }

    /// Closes the active window if any
    func closeWindow() {
        activeWindowController?.close()
    }
}
