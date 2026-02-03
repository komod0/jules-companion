import SwiftUI

// NB: Assumes FlashMessageType and AppColors are defined

struct FlashMessageView: View {
    // Observed properties from the manager
    let message: String
    let type: FlashMessageType

    // Allow manual dismissal via tap (optional)
    let onDismiss: (() -> Void)? // Closure to call when dismissed

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: type.iconName)
                .font(.title3) // Adjust icon size
                .foregroundColor(type.foregroundColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(type.foregroundColor)
                .lineLimit(2) // Allow up to two lines

            Spacer() // Pushes content left

            // Optional close button
             if onDismiss != nil {
                 Button {
                     onDismiss?()
                 } label: {
                     Image(systemName: "xmark")
                         .font(.caption.weight(.bold))
                         .foregroundColor(type.foregroundColor.opacity(0.7))
                 }
                 .buttonStyle(.plain)
                 .padding(.leading, 5)
             }

        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(type.backgroundColor) // Use dynamic background color
        .cornerRadius(8)
        // Add a subtle shadow for depth
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
        // Allow tapping the whole message to dismiss (if onDismiss is provided)
        .contentShape(Rectangle())
        .onTapGesture {
             onDismiss?()
        }

    }
}

// Example Preview
struct FlashMessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            FlashMessageView(message: "Task submitted successfully!", type: .success, onDismiss: {})
            FlashMessageView(message: "Failed to load repositories. Please check connection.", type: .error, onDismiss: {})
            FlashMessageView(message: "This is just informational.", type: .info, onDismiss: {})
             FlashMessageView(message: "Warning: Low disk space detected.", type: .warning, onDismiss: {})
        }
        .padding()
        .background(Color.gray.opacity(0.3))
    }
}
