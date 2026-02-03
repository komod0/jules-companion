import SwiftUI

/// A splash view shown to new users who haven't configured their Jules API key.
/// Features an animated boids background, the Jules logo, an API key input field,
/// and a link to get an API key from Jules.
struct SplashView: View {
    @EnvironmentObject var dataManager: DataManager

    @State private var apiKeyInput: String = ""
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    // Purple background colors for the boids animation

    private var backgroundColor: Color {
        Color(hex: "#161121")
    }
    private var fishColor: Color {
        Color(red: 0.541, green: 0.459, blue: 1.0)  // Purple fish
    }

    var body: some View {
        ZStack {
            // Animated boids background
            BoidsBackgroundView(
                fishColor: fishColor,
                backgroundColor: backgroundColor,
                configuration: .default
            )

            // Content overlay
            VStack(spacing: 24) {
                Spacer()

                // Large Jules logo
                SquidLogoView()
                    .frame(width: 80, height: 80)

                // Subtitle

                Spacer()

                // API Key input section
                VStack(spacing: 16) {
                    // Input field with visual effect background
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.accent)

                        TextField("Enter your API key", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .focused($isInputFocused)
                            .disabled(isVerifying)
                            .onSubmit {
                                submitApiKey()
                            }

                        if isVerifying {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: AppColors.accent))
                                .scaleEffect(0.8)
                        } else if !apiKeyInput.isEmpty {
                            Button(action: submitApiKey) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(AppColors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(errorMessage != nil ? Color.red.opacity(0.5) : .white.opacity(0.2), lineWidth: 1)
                    }

                    // Error message
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }

                    // Get API Key link
                    Button(action: openGetApiKeyLink) {
                        HStack(spacing: 6) {
                            Text("Get your API key")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(AppColors.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isVerifying)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .onAppear {
            // Focus the input field when view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
        .onChange(of: apiKeyInput) { _, _ in
            // Clear error when user starts typing
            if errorMessage != nil {
                errorMessage = nil
            }
        }
    }

    private func submitApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !isVerifying else { return }

        // Clear any previous error
        errorMessage = nil
        isVerifying = true

        Task {
            let isValid = await APIService.verifyApiKey(trimmedKey)

            await MainActor.run {
                isVerifying = false

                if isValid {
                    dataManager.apiKey = trimmedKey
                    // Preload sources so they're ready for the user
                    dataManager.forceRefreshSources()
                    apiKeyInput = ""
                } else {
                    errorMessage = "Invalid API key. Please check and try again."
                }
            }
        }
    }

    private func openGetApiKeyLink() {
        // Open the Jules settings page to get an API key
        if let url = URL(string: "https://jules.google.com/settings/api") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if DEBUG
struct SplashView_Previews: PreviewProvider {
    static var previews: some View {
        SplashView()
            .frame(width: 400, height: 500)
    }
}
#endif
