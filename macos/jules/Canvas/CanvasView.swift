//
//  CanvasView.swift
//  jules
//
//  Main canvas view for image annotation
//
//  Architecture Patterns Implemented:
//  1. Normalized Coordinate System (NCS) - All positions stored as 0.0-1.0 ratios
//  2. Dual-State Interaction Pattern - Text view for display, TextField for editing
//  3. Finite State Machine (FSM) - Idle → Selected → Editing state transitions
//  4. Gesture Orchestration - DragGesture with @GestureState for smooth animations
//  5. Hit Testing - contentShape(Rectangle()) with minimum 44x44 touch targets
//  6. Z-Index Management - Selected annotations float above others (zIndex: 100)
//  7. Accessibility - VoiceOver labels, hints, and sort priority by position
//  8. Performance - drawingGroup() for non-interactive annotations
//

import SwiftUI
import AppKit

@available(macOS 14.0, *)
struct CanvasView: View {
    @ObservedObject var store: CanvasStore
    @State private var viewSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Checkered background to show transparency - fills entire canvas area
                CheckerboardBackground()

                // Canvas content - centered and zoomed to fit
                canvasContent
                    .frame(width: store.imageSize.width, height: store.imageSize.height)
                    .scaleEffect(store.zoomScale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewSize = geometry.size
                fitImageToView(viewSize: geometry.size)
            }
            .onChange(of: geometry.size) { newSize in
                viewSize = newSize
                fitImageToView(viewSize: newSize)
            }
        }
        .clipped()
    }

    private func fitImageToView(viewSize: CGSize) {
        let imageSize = store.imageSize
        let padding: CGFloat = 20 // Padding on each side (at least 20 pixels)

        let availableWidth = viewSize.width - (padding * 2)
        let availableHeight = viewSize.height - (padding * 2)

        guard availableWidth > 0 && availableHeight > 0 else { return }

        let widthRatio = availableWidth / imageSize.width
        let heightRatio = availableHeight / imageSize.height

        store.zoomScale = min(widthRatio, heightRatio, 1.0) // Don't scale up beyond 100%
        store.panOffset = .zero
    }

    // MARK: - Canvas Content

    private var canvasContent: some View {
        ZStack {
            // Original image (not draggable)
            Image(nsImage: store.originalImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .allowsHitTesting(false)

            // Drawing layer - only active when draw tool is selected
            DrawingCanvasView(
                drawing: $store.drawing,
                selectedColor: store.selectedColor,
                penSize: store.penSize,
                isEnabled: store.selectedTool == .draw,
                onStrokeCompleted: {
                    store.commitDrawingStroke()
                }
            )
            .allowsHitTesting(store.selectedTool == .draw)

            // Text annotations layer with z-index management
            // Note: We render all annotations in a single ForEach to maintain proper z-ordering
            // The selected annotation has higher zIndex to float above others
            ForEach(store.textAnnotations) { annotation in
                let isSelected = store.selectedTextAnnotationId == annotation.id
                let isEditing = store.interactionState.editingId == annotation.id

                TextAnnotationView(
                    annotation: annotation,
                    imageSize: store.imageSize,
                    isSelected: isSelected,
                    isEditing: isEditing,
                    editingText: isSelected ? $store.editingText : .constant(""),
                    zoomScale: store.zoomScale,
                    onSelect: {
                        store.selectTextAnnotation(annotation.id)
                    },
                    onStartEditing: {
                        store.startEditing()
                    },
                    onMove: { newPosition in
                        store.moveTextAnnotation(id: annotation.id, to: newPosition)
                    },
                    onMoveEnded: {
                        store.commitTextAnnotationMove(id: annotation.id)
                    },
                    onDelete: {
                        store.deleteTextAnnotation(id: annotation.id)
                    },
                    onFinishEditing: {
                        store.finishEditingText()
                    }
                )
                // Use normalized coordinates converted to screen position
                .position(annotation.screenPosition(for: store.imageSize))
                // Z-index: selected annotations float above others
                .zIndex(isSelected ? 100 : 1)
            }

            // Tap area for adding new text - only when text tool is selected and not editing
            if store.selectedTool == .text && !store.isEditingText {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleTextTap(at: location)
                    }
            }
        }
    }

    // MARK: - Tap Handling

    private func handleTextTap(at location: CGPoint) {
        // Check if we tapped on existing annotation (with a larger hit area)
        if let existingAnnotation = store.textAnnotations.first(where: { annotation in
            let screenPos = annotation.screenPosition(for: store.imageSize)
            let dx = abs(screenPos.x - location.x)
            let dy = abs(screenPos.y - location.y)
            return dx < 80 && dy < 40
        }) {
            store.selectTextAnnotation(existingAnnotation.id)
        } else {
            // Add new text annotation at the clicked location
            store.addTextAnnotation(at: location)
        }
    }
}

// MARK: - Checkerboard Background

struct CheckerboardBackground: View {
    let squareSize: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let lightColor = Color(nsColor: NSColor.controlBackgroundColor)
                let darkColor = Color(nsColor: NSColor.separatorColor.withAlphaComponent(0.1))

                let cols = Int(ceil(size.width / squareSize))
                let rows = Int(ceil(size.height / squareSize))

                for row in 0..<rows {
                    for col in 0..<cols {
                        let isEven = (row + col) % 2 == 0
                        let rect = CGRect(
                            x: CGFloat(col) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        context.fill(Path(rect), with: .color(isEven ? lightColor : darkColor))
                    }
                }
            }
        }
    }
}

// MARK: - Text Annotation View

/// View for displaying and editing text annotations
/// Implements the Dual-State Interaction Pattern:
/// - View Mode (Text): Supports drag gestures, tap to select, double-tap to edit
/// - Edit Mode (TextField): Captures all input for text editing
@available(macOS 14.0, *)
struct TextAnnotationView: View {
    let annotation: TextAnnotation
    let imageSize: CGSize
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let zoomScale: CGFloat
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    let onDelete: () -> Void
    let onFinishEditing: () -> Void

    // Use @State for manual control of drag offset (avoids ghosting with @GestureState)
    @State private var dragOffset: CGSize = .zero
    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false

    // Minimum touch target size per Apple HIG (44x44 points)
    private let minimumTouchTarget: CGFloat = 44

    // Computed font size from normalized scale
    private var fontSize: CGFloat {
        annotation.fontSize(for: imageSize)
    }

    // Screen position for calculations
    private var screenPosition: CGPoint {
        annotation.screenPosition(for: imageSize)
    }

    var body: some View {
        Group {
            if isEditing {
                editingView
            } else {
                displayView
            }
        }
        .offset(dragOffset)
        .onHover { hovering in
            isHovering = hovering
        }
        // Accessibility support
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(annotation.text.isEmpty ? "Empty text annotation" : annotation.text)
        .accessibilityValue("Position: \(Int(annotation.normalizedPosition.x * 100))% horizontal, \(Int(annotation.normalizedPosition.y * 100))% vertical")
        .accessibilityHint(isEditing ? "Editing" : (isSelected ? "Double tap to edit" : "Tap to select"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Accessibility sorting by vertical position (top to bottom reading order)
        .accessibilitySortPriority(Double(1000 - annotation.normalizedPosition.y * 1000))
    }

    // MARK: - View Mode (Text Display)

    private var displayView: some View {
        ZStack {
            // Text content (Proxy Representation - not a TextField)
            Text(annotation.text.isEmpty ? "Enter text" : annotation.text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(annotation.text.isEmpty ? annotation.color.opacity(0.5) : annotation.color)
                .shadow(color: isDragging ? .clear : .black.opacity(0.6), radius: 1, x: 0, y: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selectionBackground)
                .overlay(cornerHandles)
        }
        // Rasterize during drag for smoother performance
        .drawingGroup(opaque: false)
        // Ensure minimum touch target size (44x44) for proper hit testing
        .frame(minWidth: minimumTouchTarget, minHeight: minimumTouchTarget)
        // contentShape ensures the entire bounding box is tappable
        .contentShape(Rectangle())
        // Drag gesture for moving - use highPriorityGesture to ensure it takes precedence
        .highPriorityGesture(dragGesture)
        .onTapGesture(count: 2) {
            // Double-click: Select + Start Editing (FSM transition to Editing state)
            onSelect()
            onStartEditing()
        }
        .onTapGesture(count: 1) {
            // Single click: Select (FSM transition to Selected state)
            onSelect()
        }
        .contextMenu {
            Button("Edit") {
                onSelect()
                onStartEditing()
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
        .onChange(of: isHovering) { hovering in
            updateCursor(hovering: hovering)
        }
    }

    // MARK: - Selection Background

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(
                isSelected ? Color.accentColor :
                    (isHovering || isDragging ? Color.white.opacity(0.7) : Color.white.opacity(0.3)),
                lineWidth: isSelected ? 2 : 1
            )
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(isDragging ? 0.15 : (isHovering ? 0.1 : 0.05)))
            )
    }

    // MARK: - Corner Handles

    @ViewBuilder
    private var cornerHandles: some View {
        if isSelected || isHovering {
            GeometryReader { geometry in
                let handleColor = isSelected ? Color.accentColor : Color.white.opacity(0.6)
                let handleSize: CGFloat = 6

                // Four corner handles indicate movability
                Circle()
                    .fill(handleColor)
                    .frame(width: handleSize, height: handleSize)
                    .position(x: 0, y: 0)
                Circle()
                    .fill(handleColor)
                    .frame(width: handleSize, height: handleSize)
                    .position(x: geometry.size.width, y: 0)
                Circle()
                    .fill(handleColor)
                    .frame(width: handleSize, height: handleSize)
                    .position(x: 0, y: geometry.size.height)
                Circle()
                    .fill(handleColor)
                    .frame(width: handleSize, height: handleSize)
                    .position(x: geometry.size.width, y: geometry.size.height)
            }
        }
    }

    // MARK: - Drag Gesture

    private var dragGesture: some Gesture {
        // Use global coordinate space to get screen-space coordinates
        // This avoids issues with the parent's scaleEffect affecting gesture translation
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                // Translation is in screen coordinates (global space)
                // Convert to image coordinates by dividing by zoomScale
                let scaledTranslation = CGSize(
                    width: value.translation.width / zoomScale,
                    height: value.translation.height / zoomScale
                )
                dragOffset = scaledTranslation
                // Set cursor and dragging state once at start
                if !isDragging {
                    isDragging = true
                    NSCursor.closedHand.set()
                }
            }
            .onEnded { value in
                // Translation is in screen coordinates (global space)
                // Convert to image coordinates by dividing by zoomScale
                let scaledWidth = value.translation.width / zoomScale
                let scaledHeight = value.translation.height / zoomScale

                // Calculate final position in image coordinates
                let newPosition = CGPoint(
                    x: screenPosition.x + scaledWidth,
                    y: screenPosition.y + scaledHeight
                )

                // Update store position FIRST (this updates annotation.normalizedPosition)
                onMove(newPosition)
                onMoveEnded()

                // THEN reset drag offset to zero - no ghosting because store is already updated
                dragOffset = .zero
                isDragging = false
                NSCursor.arrow.set()
            }
    }

    // MARK: - Cursor Management

    private func updateCursor(hovering: Bool) {
        if hovering && !isDragging {
            NSCursor.openHand.set()
        } else if !hovering && !isDragging {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Edit Mode (TextField)

    private var editingView: some View {
        TextField("Enter text", text: $editingText, onCommit: {
            onFinishEditing()
        })
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: .medium))
        .foregroundColor(annotation.color)
        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
        )
        // Size to fit the text content, with a small minimum for empty field
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 60)
        // Disable hit testing on background to prevent gesture conflicts
        .allowsHitTesting(true)
        // ESC key handler - finish editing (deletes empty textboxes)
        .onExitCommand {
            onFinishEditing()
        }
    }
}

// MARK: - Drawing Canvas View (macOS-compatible)

@available(macOS 14.0, *)
struct DrawingCanvasView: NSViewRepresentable {
    @Binding var drawing: DrawingData
    let selectedColor: Color
    let penSize: CGFloat
    let isEnabled: Bool
    let onStrokeCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DrawingNSView {
        let canvasView = DrawingNSView()
        canvasView.drawing = drawing
        canvasView.strokeColor = NSColor(selectedColor)
        canvasView.strokeWidth = penSize
        canvasView.isDrawingEnabled = isEnabled
        canvasView.onDrawingChanged = { newDrawing in
            context.coordinator.handleDrawingChanged(newDrawing)
        }
        canvasView.onStrokeCompleted = {
            context.coordinator.handleStrokeCompleted()
        }
        return canvasView
    }

    func updateNSView(_ canvasView: DrawingNSView, context: Context) {
        if canvasView.drawing != drawing {
            canvasView.drawing = drawing
            canvasView.needsDisplay = true
        }
        canvasView.strokeColor = NSColor(selectedColor)
        canvasView.strokeWidth = penSize
        canvasView.isDrawingEnabled = isEnabled
    }

    class Coordinator: NSObject {
        var parent: DrawingCanvasView
        private var isUpdating = false

        init(_ parent: DrawingCanvasView) {
            self.parent = parent
        }

        func handleDrawingChanged(_ newDrawing: DrawingData) {
            guard !isUpdating else { return }
            isUpdating = true
            DispatchQueue.main.async {
                self.parent.drawing = newDrawing
                self.isUpdating = false
            }
        }

        func handleStrokeCompleted() {
            DispatchQueue.main.async {
                self.parent.onStrokeCompleted()
            }
        }
    }
}

// MARK: - Drawing Data Model

/// A simple drawing data model for macOS (replaces PKDrawing)
struct DrawingData: Equatable {
    var strokes: [DrawingStroke] = []

    static func == (lhs: DrawingData, rhs: DrawingData) -> Bool {
        lhs.strokes == rhs.strokes
    }
}

/// A single stroke in the drawing
struct DrawingStroke: Equatable, Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat

    static func == (lhs: DrawingStroke, rhs: DrawingStroke) -> Bool {
        lhs.id == rhs.id && lhs.points == rhs.points && lhs.lineWidth == rhs.lineWidth
    }
}

// MARK: - Drawing NSView

/// Custom NSView for drawing on macOS
class DrawingNSView: NSView {
    var drawing: DrawingData = DrawingData() {
        didSet {
            needsDisplay = true
        }
    }
    var strokeColor: NSColor = .purple
    var strokeWidth: CGFloat = 3.0
    var isDrawingEnabled: Bool = true
    var onDrawingChanged: ((DrawingData) -> Void)?
    var onStrokeCompleted: (() -> Void)?

    private var currentStroke: DrawingStroke?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Note: isFlipped = true on the view is sufficient for coordinate system alignment
        // Do NOT set layer?.isGeometryFlipped as it causes the background image to flip
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw all completed strokes
        for stroke in drawing.strokes {
            drawStroke(stroke, in: context)
        }

        // Draw current stroke being drawn
        if let current = currentStroke {
            drawStroke(current, in: context)
        }
    }

    private func drawStroke(_ stroke: DrawingStroke, in context: CGContext) {
        guard stroke.points.count > 1 else { return }

        context.setStrokeColor(stroke.color.cgColor)
        context.setLineWidth(stroke.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.beginPath()
        context.move(to: stroke.points[0])
        for point in stroke.points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        guard isDrawingEnabled else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        currentStroke = DrawingStroke(points: [point], color: strokeColor, lineWidth: strokeWidth)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawingEnabled, currentStroke != nil else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        currentStroke?.points.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawingEnabled, let stroke = currentStroke else {
            super.mouseUp(with: event)
            return
        }

        // Add the completed stroke to the drawing
        var newDrawing = drawing
        newDrawing.strokes.append(stroke)
        drawing = newDrawing
        currentStroke = nil

        onDrawingChanged?(drawing)
        onStrokeCompleted?()
        needsDisplay = true
    }
}

// MARK: - DrawingData to NSImage

extension DrawingData {
    /// Renders the drawing to an NSImage
    func toNSImage(size: CGSize, scale: CGFloat = 1.0) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // Flip the context since we use a flipped coordinate system
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        for stroke in strokes {
            guard stroke.points.count > 1 else { continue }

            context.setStrokeColor(stroke.color.cgColor)
            context.setLineWidth(stroke.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.beginPath()
            context.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }

        image.unlockFocus()
        return image
    }
}
