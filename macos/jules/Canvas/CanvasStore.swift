//
//  CanvasStore.swift
//  jules
//
//  Canvas state management with undo/redo history
//
//  Architecture Notes:
//  - Uses Normalized Coordinate System (0.0-1.0) for resolution independence
//  - Implements Finite State Machine for annotation interaction states
//  - Follows Dual-State Interaction Pattern (View Mode vs Edit Mode)
//

import SwiftUI
import Combine

// MARK: - Annotation Interaction State (FSM)

/// Finite State Machine for annotation interaction
/// Ensures gesture conflicts are avoided by separating view/edit modes
enum AnnotationInteractionState: Equatable {
    case idle
    case selected(UUID)
    case editing(UUID)

    var selectedId: UUID? {
        switch self {
        case .idle:
            return nil
        case .selected(let id), .editing(let id):
            return id
        }
    }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    var editingId: UUID? {
        if case .editing(let id) = self { return id }
        return nil
    }
}

// MARK: - Normalized Geometry

/// Handles coordinate transformations between normalized space (0.0-1.0) and screen space
/// This ensures annotations remain properly positioned regardless of display size or zoom level
struct NormalizedGeometry {
    let imageSize: CGSize

    /// Convert normalized coordinates (0.0-1.0) to screen coordinates
    func toScreenPosition(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: normalized.x * imageSize.width,
            y: normalized.y * imageSize.height
        )
    }

    /// Convert screen coordinates to normalized coordinates (0.0-1.0)
    func toNormalizedPosition(_ screen: CGPoint) -> CGPoint {
        guard imageSize.width > 0 && imageSize.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: screen.x / imageSize.width,
            y: screen.y / imageSize.height
        )
    }

    /// Convert font scale (percentage of image height) to point size
    func toFontSize(_ fontScale: CGFloat) -> CGFloat {
        max(fontScale * imageSize.height, 12) // Minimum 12pt
    }

    /// Convert point size to font scale (percentage of image height)
    func toFontScale(_ fontSize: CGFloat) -> CGFloat {
        guard imageSize.height > 0 else { return 0.05 }
        return fontSize / imageSize.height
    }
}

// MARK: - Annotation Models

/// Represents a text annotation on the canvas using normalized coordinates
struct TextAnnotation: Identifiable, Equatable {
    let id: UUID
    var text: String
    /// Position in normalized coordinates (0.0-1.0 relative to image bounds)
    var normalizedPosition: CGPoint
    var color: Color
    /// Font size as a scale factor (percentage of image height)
    var fontScale: CGFloat

    init(
        id: UUID = UUID(),
        text: String,
        normalizedPosition: CGPoint,
        color: Color,
        fontScale: CGFloat = 0.04 // ~4% of image height
    ) {
        self.id = id
        self.text = text
        self.normalizedPosition = normalizedPosition
        self.color = color
        self.fontScale = fontScale
    }

    /// Convenience initializer with screen coordinates (for backwards compatibility)
    init(
        id: UUID = UUID(),
        text: String,
        screenPosition: CGPoint,
        imageSize: CGSize,
        color: Color,
        fontSize: CGFloat = 24
    ) {
        self.id = id
        self.text = text
        let geometry = NormalizedGeometry(imageSize: imageSize)
        self.normalizedPosition = geometry.toNormalizedPosition(screenPosition)
        self.fontScale = geometry.toFontScale(fontSize)
        self.color = color
    }

    /// Get screen position for a given image size
    func screenPosition(for imageSize: CGSize) -> CGPoint {
        NormalizedGeometry(imageSize: imageSize).toScreenPosition(normalizedPosition)
    }

    /// Get font size for a given image size
    func fontSize(for imageSize: CGSize) -> CGFloat {
        NormalizedGeometry(imageSize: imageSize).toFontSize(fontScale)
    }
}

/// Represents a snapshot of canvas state for undo/redo
struct CanvasSnapshot: Equatable {
    let textAnnotations: [TextAnnotation]
    let drawing: DrawingData

    static func == (lhs: CanvasSnapshot, rhs: CanvasSnapshot) -> Bool {
        lhs.textAnnotations == rhs.textAnnotations &&
        lhs.drawing == rhs.drawing
    }
}

/// Available annotation tools
enum CanvasTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case text = "Text"
    case draw = "Draw"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .draw: return "pencil.tip"
        }
    }
}

// MARK: - Canvas Store

@MainActor
class CanvasStore: ObservableObject {
    // MARK: - Published Properties

    /// The original image being annotated
    @Published var originalImage: NSImage

    /// Current zoom scale
    @Published var zoomScale: CGFloat = 1.0

    /// Current pan offset
    @Published var panOffset: CGSize = .zero

    /// Currently selected tool
    @Published var selectedTool: CanvasTool = .select

    /// Current drawing color
    @Published var selectedColor: Color = .purple

    /// Current font size for text annotations (in points, for UI display)
    @Published var fontSize: CGFloat = 24

    /// Current pen/stroke size for drawing
    @Published var penSize: CGFloat = 3.0

    /// Text annotations on the canvas
    @Published var textAnnotations: [TextAnnotation] = []

    /// Drawing data
    @Published var drawing: DrawingData = DrawingData()

    /// Whether we can undo
    @Published var canUndo: Bool = false

    /// Whether we can redo
    @Published var canRedo: Bool = false

    /// Current interaction state (FSM) - manages Idle/Selected/Editing states
    @Published var interactionState: AnnotationInteractionState = .idle

    /// Text being edited in the selected annotation
    @Published var editingText: String = ""

    // MARK: - Computed Properties (FSM Accessors)

    /// Currently selected text annotation ID (derived from FSM state)
    var selectedTextAnnotationId: UUID? {
        interactionState.selectedId
    }

    /// Whether we're currently editing text (derived from FSM state)
    var isEditingText: Bool {
        interactionState.isEditing
    }

    /// Geometry helper for coordinate conversions
    var geometry: NormalizedGeometry {
        NormalizedGeometry(imageSize: imageSize)
    }

    // MARK: - History

    private var undoStack: [CanvasSnapshot] = []
    private var redoStack: [CanvasSnapshot] = []
    private let maxHistorySize = 50
    private var isUndoRedoInProgress = false

    // MARK: - Callbacks

    var onFinish: ((NSImage) -> Void)?

    // MARK: - Computed Properties

    var imageSize: CGSize {
        originalImage.size
    }

    // MARK: - Initialization

    init(image: NSImage) {
        self.originalImage = image
        // Save initial empty state
        let initialSnapshot = CanvasSnapshot(textAnnotations: [], drawing: DrawingData())
        undoStack.append(initialSnapshot)
        updateHistoryState()
    }

    // MARK: - Zoom & Pan

    func zoomIn() {
        zoomScale = min(zoomScale * 1.25, 5.0)
    }

    func zoomOut() {
        zoomScale = max(zoomScale / 1.25, 0.25)
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    func fitToView(viewSize: CGSize) {
        let imageSize = self.imageSize
        let widthRatio = viewSize.width / imageSize.width
        let heightRatio = viewSize.height / imageSize.height
        zoomScale = min(widthRatio, heightRatio) * 0.9 // 90% to leave some margin
        panOffset = .zero
    }

    // MARK: - Text Annotations

    /// Add a text annotation at the given screen position
    func addTextAnnotation(at screenPosition: CGPoint) {
        saveSnapshotForUndo()
        let annotation = TextAnnotation(
            text: "",
            screenPosition: screenPosition,
            imageSize: imageSize,
            color: selectedColor,
            fontSize: fontSize
        )
        textAnnotations.append(annotation)
        editingText = annotation.text
        // FSM: Transition to editing state
        interactionState = .editing(annotation.id)
    }

    /// Add a text annotation at the center of the image
    func addTextAnnotationAtCenter() {
        let centerPosition = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        addTextAnnotation(at: centerPosition)
    }

    /// Update the text content of an annotation
    func updateTextAnnotation(id: UUID, text: String) {
        guard let index = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[index].text = text
    }

    /// Update the font size of an annotation (converts to font scale internally)
    func updateTextAnnotationFontSize(id: UUID, fontSize: CGFloat) {
        guard let index = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        saveSnapshotForUndo()
        textAnnotations[index].fontScale = geometry.toFontScale(fontSize)
    }

    /// Move an annotation to a new screen position (converts to normalized internally)
    func moveTextAnnotation(id: UUID, to screenPosition: CGPoint) {
        guard let index = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[index].normalizedPosition = geometry.toNormalizedPosition(screenPosition)
    }

    /// Commit the annotation move (saves undo state)
    func commitTextAnnotationMove(id: UUID) {
        saveSnapshotForUndo()
    }

    /// Delete an annotation
    func deleteTextAnnotation(id: UUID) {
        saveSnapshotForUndo()
        textAnnotations.removeAll { $0.id == id }
        // FSM: Transition to idle if we deleted the selected annotation
        if interactionState.selectedId == id {
            interactionState = .idle
        }
    }

    /// Finish editing text and commit changes
    func finishEditingText() {
        guard let id = interactionState.editingId else {
            // Not in editing state, just ensure we're idle
            if interactionState.selectedId == nil {
                interactionState = .idle
            }
            editingText = ""
            return
        }

        if editingText.isEmpty {
            // Delete empty annotations
            textAnnotations.removeAll { $0.id == id }
            interactionState = .idle
        } else if let index = textAnnotations.firstIndex(where: { $0.id == id }) {
            if textAnnotations[index].text != editingText {
                saveSnapshotForUndo()
                textAnnotations[index].text = editingText
            }
            // FSM: Transition from editing to selected
            interactionState = .selected(id)
        } else {
            interactionState = .idle
        }
        editingText = ""
    }

    /// Select an annotation (FSM state transition)
    func selectTextAnnotation(_ id: UUID?) {
        // First, finish any ongoing editing
        if case .editing(let editingId) = interactionState, editingId != id {
            finishEditingText()
        }

        guard let id = id else {
            // FSM: Transition to idle
            interactionState = .idle
            editingText = ""
            return
        }

        // FSM: Transition to selected state
        interactionState = .selected(id)

        // Load annotation data for editing
        if let annotation = textAnnotations.first(where: { $0.id == id }) {
            editingText = annotation.text
            fontSize = annotation.fontSize(for: imageSize)
        }
    }

    /// Start editing the currently selected annotation (FSM state transition)
    func startEditing() {
        guard case .selected(let id) = interactionState else { return }
        if let annotation = textAnnotations.first(where: { $0.id == id }) {
            editingText = annotation.text
            // FSM: Transition from selected to editing
            interactionState = .editing(id)
        }
    }

    /// Deselect and return to idle state
    func deselectAll() {
        finishEditingText()
        interactionState = .idle
        editingText = ""
    }

    // MARK: - Drawing

    func updateDrawing(_ newDrawing: DrawingData) {
        guard !isUndoRedoInProgress else { return }
        drawing = newDrawing
    }

    func commitDrawingStroke() {
        // Save snapshot after a stroke is complete
        saveSnapshotForUndo()
    }

    func clearDrawing() {
        saveSnapshotForUndo()
        drawing = DrawingData()
    }

    // MARK: - History (Undo/Redo)

    private func saveSnapshotForUndo() {
        guard !isUndoRedoInProgress else { return }

        let snapshot = CanvasSnapshot(textAnnotations: textAnnotations, drawing: drawing)

        // Don't save if it's the same as the last snapshot
        if let lastSnapshot = undoStack.last, lastSnapshot == snapshot {
            return
        }

        undoStack.append(snapshot)
        if undoStack.count > maxHistorySize {
            undoStack.removeFirst()
        }
        redoStack.removeAll() // Clear redo stack when new action is taken
        updateHistoryState()
    }

    func undo() {
        guard undoStack.count > 1 else { return } // Keep at least initial state
        isUndoRedoInProgress = true

        // Pop the current state
        let currentSnapshot = undoStack.removeLast()
        redoStack.append(currentSnapshot)

        // Restore the previous state
        if let previousState = undoStack.last {
            textAnnotations = previousState.textAnnotations
            drawing = previousState.drawing
        }

        updateHistoryState()
        isUndoRedoInProgress = false
    }

    func redo() {
        guard let nextState = redoStack.popLast() else { return }
        isUndoRedoInProgress = true

        // Save current snapshot to undo stack
        let currentSnapshot = CanvasSnapshot(textAnnotations: textAnnotations, drawing: drawing)
        undoStack.append(currentSnapshot)

        // Restore the redo state
        textAnnotations = nextState.textAnnotations
        drawing = nextState.drawing

        updateHistoryState()
        isUndoRedoInProgress = false
    }

    private func updateHistoryState() {
        canUndo = undoStack.count > 1
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Export

    func exportToImage() -> NSImage? {
        let imageSize = self.imageSize
        guard imageSize.width > 0 && imageSize.height > 0 else { return nil }

        let resultImage = NSImage(size: imageSize)
        resultImage.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            resultImage.unlockFocus()
            return nil
        }

        // Draw original image first WITHOUT any transforms
        // NSImage.draw handles coordinate systems correctly on its own
        originalImage.draw(in: NSRect(origin: .zero, size: imageSize))

        // Now flip the context for strokes (which were captured in flipped coordinate space)
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)

        // Draw strokes directly in the flipped context
        for stroke in drawing.strokes {
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

        // Draw text annotations in the flipped context (skip empty ones)
        for annotation in textAnnotations where !annotation.text.isEmpty {
            // Save the context state
            context.saveGState()

            // For text, we need to flip back because NSAttributedString.draw expects non-flipped
            context.translateBy(x: 0, y: imageSize.height)
            context.scaleBy(x: 1, y: -1)

            // Convert normalized position to screen position
            let screenPosition = annotation.screenPosition(for: imageSize)
            // Convert position from flipped to non-flipped
            let flippedY = imageSize.height - screenPosition.y

            // Get font size from font scale
            let fontSize = annotation.fontSize(for: imageSize)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor(annotation.color)
            ]
            let attributedString = NSAttributedString(string: annotation.text, attributes: attributes)

            // Calculate size and adjust position (text is centered at position)
            let textSize = attributedString.size()
            let drawPoint = CGPoint(
                x: screenPosition.x - textSize.width / 2,
                y: flippedY - textSize.height / 2
            )
            attributedString.draw(at: drawPoint)

            context.restoreGState()
        }

        resultImage.unlockFocus()
        return resultImage
    }

    // MARK: - Finish

    func finish() {
        finishEditingText()
        if let exportedImage = exportToImage() {
            onFinish?(exportedImage)
        }
    }
}
