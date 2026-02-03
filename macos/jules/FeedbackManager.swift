import Foundation
import AppKit

/// Manages user feedback submissions
/// In this open source version, feedback is displayed locally (you can integrate your own backend)
final class FeedbackManager: ObservableObject {
    static let shared = FeedbackManager()

    @Published var isShowingFeedbackSheet = false
    @Published var feedbackName: String = ""
    @Published var feedbackEmail: String = ""
    @Published var feedbackComments: String = ""
    @Published var isSubmitting = false
    @Published var lastSubmissionError: String?
    @Published var showingSuccessMessage = false

    private init() {}

    /// Submits user feedback
    /// In this open source version, feedback is logged locally.
    /// You can integrate your own feedback backend here.
    /// - Parameters:
    ///   - name: User's name (optional)
    ///   - email: User's email (optional)
    ///   - comments: The feedback message (required)
    /// - Returns: True if submission was successful
    @MainActor
    func submitFeedback(
        name: String = "",
        email: String = "",
        comments: String
    ) -> Bool {
        guard !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastSubmissionError = "Please enter your feedback message"
            return false
        }

        isSubmitting = true
        lastSubmissionError = nil

        // Integrate your own feedback backend here
        // Example: Send to your own API endpoint, email service, or analytics platform
        #if DEBUG
        let feedbackName = name.isEmpty ? "Anonymous" : name
        print("📝 [DEBUG] Feedback submitted by \(feedbackName)")
        #endif

        isSubmitting = false
        showingSuccessMessage = true

        // Clear the form
        self.feedbackName = ""
        self.feedbackEmail = ""
        feedbackComments = ""

        return true
    }

    /// Submits feedback using the current form values
    @MainActor
    func submitCurrentFeedback() -> Bool {
        return submitFeedback(
            name: feedbackName,
            email: feedbackEmail,
            comments: feedbackComments
        )
    }

    /// Shows the feedback sheet
    @MainActor
    func showFeedbackSheet() {
        lastSubmissionError = nil
        showingSuccessMessage = false
        isShowingFeedbackSheet = true
    }

    /// Hides the feedback sheet
    @MainActor
    func hideFeedbackSheet() {
        isShowingFeedbackSheet = false
    }

    /// Resets all form fields
    @MainActor
    func resetForm() {
        feedbackName = ""
        feedbackEmail = ""
        feedbackComments = ""
        lastSubmissionError = nil
        showingSuccessMessage = false
    }
}
