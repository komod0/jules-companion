//
//  ImageAttachmentIndicatorView.swift
//  jules
//
//  Created for image drag-drop support
//

import SwiftUI

// NB: Assumes AppColors is defined

struct ImageAttachmentIndicatorView: View {
    // The attached image to preview
    let image: NSImage
    // Action to remove the attachment
    let onRemove: () -> Void
    // Action to edit/annotate the image (optional)
    var onEdit: ((NSImage) -> Void)? = nil

    @State private var isHoveringRemove = false
    @State private var isHoveringImage = false
    @State private var isHoveringEdit = false

    // Compute image dimensions for display
    private var imageSize: String {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return "\(width) x \(height)"
    }

    // Image thumbnail view
    private var imageThumbnail: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 60, maxHeight: 40)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.textSecondary.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                // Edit overlay on hover (only when canvas editor is available)
                Group {
                    if isHoveringImage && isCanvasEditorAvailable {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.4))
                            Image(systemName: "pencil")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                }
            )
            .scaleEffect(isHoveringImage && isCanvasEditorAvailable ? 1.05 : 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Image thumbnail - clickable to edit (on macOS 14+)
            Group {
                if isCanvasEditorAvailable {
                    Button(action: {
                        openCanvasEditor()
                    }) {
                        imageThumbnail
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringImage = hovering
                        }
                    }
                    .help("Click to annotate image")
                } else {
                    imageThumbnail
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Image attached")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 4) {
                    Text(imageSize)
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))

                    // Only show annotate button on macOS 14+
                    if isCanvasEditorAvailable {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary.opacity(0.5))

                        // Edit button
                        Button(action: {
                            openCanvasEditor()
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                Text("Annotate")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(isHoveringEdit ? AppColors.textPrimary : AppColors.textSecondary.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeIn(duration: 0.1)) {
                                isHoveringEdit = hovering
                            }
                        }
                    }
                }
            }

            Spacer()

            // Remove Button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(isHoveringRemove ? AppColors.destructive.opacity(0.8) : AppColors.textSecondary.opacity(0.7))
                    .onHover { hovering in
                        withAnimation(.easeIn(duration: 0.1)) {
                            isHoveringRemove = hovering
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Remove attached image")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .inputOverlayStyle(cornerRadius: 8, useMaterial: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Canvas Editor

    /// Whether the canvas editor is available (requires macOS 14+)
    private var isCanvasEditorAvailable: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private func openCanvasEditor() {
        guard isCanvasEditorAvailable else { return }

        if #available(macOS 14.0, *) {
            CanvasWindowManager.shared.openCanvas(for: image) { annotatedImage in
                // Replace the image with the annotated version
                if let onEdit = onEdit {
                    onEdit(annotatedImage)
                }
            }
        }
    }
}

// Preview Provider
struct ImageAttachmentIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a sample image for preview
        let sampleImage: NSImage = {
            let image = NSImage(size: NSSize(width: 200, height: 150))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 150).fill()
            image.unlockFocus()
            return image
        }()

        ImageAttachmentIndicatorView(image: sampleImage, onRemove: {})
            .padding()
            .background(AppColors.background)
    }
}
