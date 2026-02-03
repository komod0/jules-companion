import SwiftUI
import AppKit

/// A test harness view for MergeConflictView that allows testing merge conflict resolution
/// without needing an actual git merge conflict.
struct MergeConflictTestView: View {
    @Binding var isShowingTest: Bool
    @State private var testContent: String = MergeConflictTestData.sampleConflictText
    @StateObject private var conflictCoordinator = MergeConflictCoordinator()
    @State private var selectedFileIndex: Int = 0

    // Sample files for multi-file testing
    private var testFiles: [TestConflictFile] {
        [
            TestConflictFile(name: "User.swift", language: "swift", content: testContent),
            TestConflictFile(name: "UserService.swift", language: "swift", content: MergeConflictTestData.sampleConflictText2),
            TestConflictFile(name: "config.json", language: "json", content: MergeConflictTestData.jsonConflictText)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button and status
            HStack {
                Button(action: {
                    isShowingTest = false
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Session")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.accent)

                Spacer()

                Text("Merge Conflict Editor")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                // Reset button
                Button(action: {
                    testContent = MergeConflictTestData.sampleConflictText
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppColors.backgroundSecondary)

            Divider()

            // File tabs for multi-file support
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(testFiles.enumerated()), id: \.offset) { index, file in
                        FileTab(
                            name: file.name,
                            isSelected: index == selectedFileIndex,
                            hasConflicts: index == 0 && conflictCoordinator.conflicts.count > 0
                        ) {
                            selectedFileIndex = index
                        }
                    }
                    Spacer()
                }
            }
            .background(Color(nsColor: AppColors.diffEditorFileHeaderBg))

            // File header with conflict status
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(AppColors.textSecondary)
                Text(testFiles[selectedFileIndex].name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                if selectedFileIndex == 0 {
                    Text("\(conflictCoordinator.conflicts.count) conflict\(conflictCoordinator.conflicts.count == 1 ? "" : "s") remaining")
                        .font(.caption)
                        .foregroundColor(conflictCoordinator.conflicts.count > 0 ? AppColors.warning : AppColors.running)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: AppColors.diffEditorFileHeaderBg).opacity(0.5))

            // Main content area with the SourceEditor-based merge conflict view
            if selectedFileIndex == 0 {
                MergeConflictView(
                    text: $testContent,
                    isEditable: true,
                    language: testFiles[selectedFileIndex].language
                )
            } else {
                // For other files, show read-only preview with sample content
                MergeConflictView(
                    text: .constant(testFiles[selectedFileIndex].content),
                    isEditable: false,
                    language: testFiles[selectedFileIndex].language
                )
            }

            Divider()

            // Footer with instructions
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(AppColors.accent)
                Text("Edit the code directly or use \"Accept Current\"/\"Accept Incoming\" buttons to resolve conflicts")
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()

                // Keyboard shortcuts hint
                Text("⌘S to save")
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppColors.backgroundSecondary)
        }
        .background(AppColors.background)
        .onAppear {
            conflictCoordinator.update(text: testContent)
        }
        .onChange(of: testContent) { newValue in
            conflictCoordinator.update(text: newValue)
        }
    }
}

// MARK: - File Tab Component

struct FileTab: View {
    let name: String
    let isSelected: Bool
    let hasConflicts: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                if hasConflicts {
                    Circle()
                        .fill(AppColors.warning)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? AppColors.backgroundSecondary : Color.clear)
            .foregroundColor(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle()
                .fill(isSelected ? AppColors.accent : Color.clear)
                .frame(height: 2),
            alignment: .bottom
        )
    }
}

// MARK: - Test Conflict File Model

struct TestConflictFile {
    let name: String
    let language: String
    let content: String
}

enum ConflictResolution {
    case acceptCurrent
    case acceptIncoming
}

// MARK: - Test Data

struct MergeConflictTestData {
    /// Sample text with multiple merge conflicts for testing
    static let sampleConflictText = """
import SwiftUI
import Foundation

// MARK: - User Model

struct User {
    let id: UUID
    let name: String
<<<<<<< HEAD
    let email: String
    let createdAt: Date
=======
    let emailAddress: String
    let registrationDate: Date
    let isVerified: Bool
>>>>>>> feature/user-updates
}

// MARK: - User Service

class UserService {
    private var users: [User] = []

<<<<<<< HEAD
    func fetchUser(by id: UUID) -> User? {
        return users.first { $0.id == id }
    }

    func updateUser(_ user: User) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
=======
    func fetchUser(by id: UUID) async throws -> User? {
        // New async implementation
        try await Task.sleep(nanoseconds: 100_000_000)
        return users.first { $0.id == id }
    }

    func updateUser(_ user: User) async throws {
        guard let index = users.firstIndex(where: { $0.id == user.id }) else {
            throw UserError.notFound
        }
        users[index] = user
>>>>>>> feature/user-updates
    }
}

// MARK: - View Model

@MainActor
class UserViewModel: ObservableObject {
    @Published var currentUser: User?
    @Published var isLoading = false
<<<<<<< HEAD
    @Published var errorMessage: String?
=======
    @Published var error: UserError?
    @Published var lastRefreshDate: Date?
>>>>>>> feature/user-updates

    private let service = UserService()

<<<<<<< HEAD
    func loadUser(id: UUID) {
        isLoading = true
        currentUser = service.fetchUser(by: id)
        isLoading = false
=======
    func loadUser(id: UUID) async {
        isLoading = true
        defer { isLoading = false }

        do {
            currentUser = try await service.fetchUser(by: id)
            lastRefreshDate = Date()
        } catch {
            self.error = error as? UserError ?? .unknown
        }
>>>>>>> feature/user-updates
    }
}

// MARK: - Error Types

enum UserError: Error {
    case notFound
    case networkError
    case unknown
}

// MARK: - User View

struct UserView: View {
    @StateObject private var viewModel = UserViewModel()
    let userId: UUID

    var body: some View {
        VStack {
            if viewModel.isLoading {
                ProgressView()
            } else if let user = viewModel.currentUser {
<<<<<<< HEAD
                Text(user.name)
                    .font(.title)
                Text(user.email)
                    .font(.subheadline)
=======
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.name)
                        .font(.title)
                    Text(user.emailAddress)
                        .font(.subheadline)
                    if user.isVerified {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    }
                }
>>>>>>> feature/user-updates
            } else {
                Text("No user found")
            }
        }
        .padding()
    }
}
"""

    /// Second sample file with conflicts (UserService)
    static let sampleConflictText2 = """
import Foundation

// MARK: - Network Service

class NetworkService {
    static let shared = NetworkService()
    private let session: URLSession

<<<<<<< HEAD
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
=======
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 5
        self.session = URLSession(configuration: config)
    }
>>>>>>> feature/network-improvements

    func fetch<T: Decodable>(from url: URL) async throws -> T {
<<<<<<< HEAD
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
=======
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
>>>>>>> feature/network-improvements
    }
}

enum NetworkError: Error {
    case invalidResponse
    case decodingFailed
}
"""

    /// JSON config file with conflicts
    static let jsonConflictText = """
{
    "appName": "Jules",
    "version": "1.0.0",
<<<<<<< HEAD
    "apiEndpoint": "https://api.example.com/v1",
    "timeout": 30,
    "features": {
        "darkMode": true,
        "notifications": false
    }
=======
    "apiEndpoint": "https://api.example.com/v2",
    "timeout": 60,
    "retryCount": 3,
    "features": {
        "darkMode": true,
        "notifications": true,
        "analytics": true,
        "offlineMode": false
    }
>>>>>>> feature/config-update
}
"""
}

// MARK: - Host Views for SessionController Integration

/// Simple host view for legacy (non-Tahoe) macOS that wraps MergeConflictTestView
struct MergeConflictTestHostView: View {
    var onDismiss: () -> Void
    @State private var isShowingTest = true

    var body: some View {
        MergeConflictTestView(isShowingTest: $isShowingTest)
            .onChange(of: isShowingTest) { newValue in
                if !newValue {
                    onDismiss()
                }
            }
    }
}

/// Wrapper view for Tahoe (macOS 26+) that conditionally shows either the test view or normal content
@available(macOS 13.0, *)
struct MergeConflictTestWrapper: View {
    let isShowingTest: Bool
    @ObservedObject var selectionState: SessionSelectionState
    let initialSession: Session?
    let dataManager: DataManager
    @ObservedObject var tahoeState: TahoeState
    var onDismiss: () -> Void
    var onPreviousSession: (() -> Void)?
    var onNextSession: (() -> Void)?
    var onNewChat: (() -> Void)?
    @State private var localShowingTest: Bool = true

    var body: some View {
        Group {
            if isShowingTest {
                MergeConflictTestView(isShowingTest: $localShowingTest)
                    .onChange(of: localShowingTest) { newValue in
                        if !newValue {
                            onDismiss()
                        }
                    }
            } else {
                DeferredTahoeContentView(
                    selectionState: selectionState,
                    initialSession: initialSession,
                    onPreviousSession: onPreviousSession,
                    onNextSession: onNextSession,
                    onNewChat: onNewChat,
                    tahoeState: tahoeState
                )
                .environmentObject(dataManager)
            }
        }
        .unifiedBackground(material: .underWindowBackground, blendingMode: .behindWindow, tintOverlayOpacity: 0.5)
    }
}

// MARK: - Preview

#Preview {
    MergeConflictTestView(isShowingTest: .constant(true))
        .frame(width: 800, height: 600)
}
