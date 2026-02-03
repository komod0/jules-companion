import SwiftUI

/// A sheet view for collecting user feedback
struct FeedbackView: View {
    @StateObject private var feedbackManager = FeedbackManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Send Feedback")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .background(AppColors.separator)

            if feedbackManager.showingSuccessMessage {
                // Success state
                successView
            } else {
                // Form
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Help us improve Jules by sharing your feedback, reporting bugs, or suggesting features.")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Name field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name (optional)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)

                            TextField("Your name", text: $feedbackManager.feedbackName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }

                        // Email field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email (optional)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)

                            TextField("your@email.com", text: $feedbackManager.feedbackEmail)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }

                        // Feedback field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Feedback")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)

                            TextEditor(text: $feedbackManager.feedbackComments)
                                .font(.system(size: 13))
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(AppColors.separator, lineWidth: 1)
                                )
                                .scrollContentBackground(.hidden)
                                .background(AppColors.backgroundSecondary)
                                .cornerRadius(6)
                        }

                        // Error message
                        if let error = feedbackManager.lastSubmissionError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                Divider()
                    .background(AppColors.separator)

                // Footer with buttons
                HStack {
                    Spacer()

                    Button("Cancel") {
                        feedbackManager.resetForm()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.textSecondary)

                    Button(action: {
                        if feedbackManager.submitCurrentFeedback() {
                            // Success is handled by the manager
                        }
                    }) {
                        HStack(spacing: 6) {
                            if feedbackManager.isSubmitting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                            }
                            Text("Send Feedback")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.accent)
                    .disabled(feedbackManager.feedbackComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedbackManager.isSubmitting)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 400, height: feedbackManager.showingSuccessMessage ? 200 : 420)
        .background(AppColors.background)
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Thank you!")
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)

            Text("Your feedback has been sent successfully.")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Done") {
                feedbackManager.resetForm()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

#if DEBUG
struct FeedbackView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackView()
    }
}
#endif
