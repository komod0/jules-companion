import SwiftUI
import Sparkle
import AppKit
import HotKey

struct SettingsWindowView: View {
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var fontSizeManager = FontSizeManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @StateObject private var keyboardShortcutsManager = KeyboardShortcutsManager.shared

    // Local state for API key editing
    @State private var apiKeyInput: String = ""
    @State private var isApiKeyVisible: Bool = false
    @State private var showingResetConfirmation: Bool = false
    @State private var showingClearCacheConfirmation: Bool = false
    @State private var isClearingCache: Bool = false
    @State private var cachedSessionCount: Int = 0

    // Local state for folder mappings
    @State private var localRepoPaths: [String: String] = [:]

    // State for inline add form
    @State private var showingAddForm: Bool = false
    @State private var selectedSourceId: String = ""
    @State private var selectedFolderPath: String = ""
    @State private var showingFeedback: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // API Section
                apiSection

                // General Section
                generalSection

                // Key Commands Section
                keyCommandsSection

                // Appearance Section
                appearanceSection

                // Repository Folders Section
                repositoryFoldersSection

                // Storage Section
                storageSection

                // About Section
                aboutSection
            }
            .padding(24)
        }
        .frame(
            width: AppConstants.SettingsWindow.width,
            height: AppConstants.SettingsWindow.height
        )
        .background(AppColors.background)
        .onAppear {
            apiKeyInput = dataManager.apiKey
            loadLocalRepoPaths()
            Task {
                cachedSessionCount = await CacheManager.shared.getCachedSessionCount()
            }
        }
        .alert("Reset Settings", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will reset font sizes to their defaults. Your API key will not be affected.")
        }
        .alert("Clear All Caches", isPresented: $showingClearCacheConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearAllCaches()
            }
        } message: {
            Text("This will clear all cached sessions, preferences, and local data. Your API key will be preserved. The app will refresh data from the server.")
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackView()
        }
    }

    // MARK: - API Section

    private var apiSection: some View {
        SettingsSection(title: "API") {
            VStack(spacing: 0) {
                // API Key Row
                SettingsWindowRow {
                    HStack {
                        Label("Jules API Key", systemImage: "key.fill")
                            .foregroundColor(AppColors.textPrimary)

                        Spacer()

                        HStack(spacing: 8) {
                            if isApiKeyVisible {
                                TextField("Enter API Key", text: $apiKeyInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: 180)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppColors.backgroundSecondary)
                                    .cornerRadius(4)
                                    .onChange(of: apiKeyInput) { newValue in
                                        dataManager.apiKey = newValue
                                        // Preload sources so they're ready for the user
                                        if !newValue.isEmpty {
                                            dataManager.forceRefreshSources()
                                        }
                                    }
                            } else {
                                Text(maskedApiKey)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(AppColors.textSecondary)
                            }

                            Button(action: {
                                isApiKeyVisible.toggle()
                            }) {
                                Image(systemName: isApiKeyVisible ? "eye.slash.fill" : "eye.fill")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                // Get API Key button
                SettingsWindowRow {
                    HStack {
                        Label("Get API Key...", systemImage: "globe")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dataManager.openSettings()
                    }
                }
            }
        }
    }

    private var maskedApiKey: String {
        if apiKeyInput.isEmpty {
            return "Not set"
        }
        let visibleChars = 4
        if apiKeyInput.count <= visibleChars * 2 {
            return String(repeating: "*", count: apiKeyInput.count)
        }
        let prefix = String(apiKeyInput.prefix(visibleChars))
        let suffix = String(apiKeyInput.suffix(visibleChars))
        let masked = String(repeating: "*", count: min(8, apiKeyInput.count - visibleChars * 2))
        return "\(prefix)\(masked)\(suffix)"
    }

    // MARK: - General Section

    private var generalSection: some View {
        SettingsSection(title: "General") {
            VStack(spacing: 0) {
                // Launch at Login
                SettingsWindowRow {
                    HStack {
                        Label("Launch at Login", systemImage: "play.circle")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { newValue in
                                Task {
                                    await launchAtLoginManager.toggle()
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                }

                Divider()

                // Notifications
                SettingsWindowRow {
                    HStack {
                        Label("Notifications", systemImage: "bell.fill")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Toggle("", isOn: $notificationManager.isEnabled)
                            .labelsHidden()
                    }
                }

                Divider()

                // Menu Launch Position
                SettingsWindowRow {
                    HStack {
                        Label("Launch Position", systemImage: "macwindow")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Picker("", selection: $dataManager.menuLaunchPosition) {
                            ForEach(MenuLaunchPosition.allCases, id: \.self) { position in
                                Text(position.displayName).tag(position)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                Divider()

                // Screenshot Permission
                SettingsWindowRow {
                    HStack {
                        Label("Screenshot", systemImage: "camera.viewfinder")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        if screenCaptureManager.hasPermission {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                                Text("Enabled")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        } else if screenCaptureManager.isWaitingForPermission {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                                Text("Waiting...")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.textSecondary)
                                Button(action: {
                                    screenCaptureManager.openSystemSettings()
                                }) {
                                    Image(systemName: "gear")
                                        .font(.system(size: 12))
                                        .foregroundColor(AppColors.accent)
                                }
                                .buttonStyle(.plain)
                                .help("Open System Settings")
                            }
                        } else {
                            Button("Enable") {
                                screenCaptureManager.requestPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(AppColors.accent)
                        }
                    }
                }
                .onAppear {
                    screenCaptureManager.updatePermissionStatus()
                }
            }
        }
    }

    // MARK: - Key Commands Section

    private var keyCommandsSection: some View {
        SettingsSection(title: "Key Commands") {
            VStack(spacing: 0) {
                // Toggle Jules
                SettingsWindowRow {
                    HStack {
                        Label("Toggle Jules", systemImage: "command")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        shortcutPicker(
                            selection: $keyboardShortcutsManager.toggleJulesKey,
                            defaultKey: KeyboardShortcutsManager.defaultToggleJulesKey
                        )
                    }
                }

                Divider()

                // Screenshot
                SettingsWindowRow {
                    HStack {
                        Label("Capture Screenshot", systemImage: "camera.viewfinder")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        shortcutPicker(
                            selection: $keyboardShortcutsManager.screenshotKey,
                            defaultKey: KeyboardShortcutsManager.defaultScreenshotKey
                        )
                    }
                }

                // Voice Input (macOS 26.0+ only)
                if #available(macOS 26.0, *) {
                    Divider()

                    SettingsWindowRow {
                        HStack {
                            Label("Voice Input", systemImage: "mic")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            shortcutPicker(
                                selection: $keyboardShortcutsManager.voiceInputKey,
                                defaultKey: KeyboardShortcutsManager.defaultVoiceInputKey
                            )
                        }
                    }
                }

                Divider()

                // Text Size Commands (non-editable)
                SettingsWindowRow {
                    HStack {
                        Label("Make Text Bigger", systemImage: "plus.magnifyingglass")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        staticShortcutDisplay(shortcut: "\u{2318}++")
                    }
                }

                Divider()

                SettingsWindowRow {
                    HStack {
                        Label("Make Text Smaller", systemImage: "minus.magnifyingglass")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        staticShortcutDisplay(shortcut: "\u{2318}+-")
                    }
                }

                Divider()

                SettingsWindowRow {
                    HStack {
                        Label("Reset Text Size", systemImage: "arrow.counterclockwise.circle")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        staticShortcutDisplay(shortcut: "\u{2318}+0")
                    }
                }

                Divider()

                // Reset to Defaults
                SettingsWindowRow {
                    HStack {
                        Label("Reset Key Commands", systemImage: "arrow.counterclockwise")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        keyboardShortcutsManager.resetToDefaults()
                    }
                }
            }
        }
    }

    private func shortcutPicker(selection: Binding<Key>, defaultKey: Key) -> some View {
        HStack(spacing: 4) {
            Text("^+\u{2325}+")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)

            Picker("", selection: selection) {
                ForEach(KeyboardShortcutsManager.availableKeys) { key in
                    Text(KeyboardShortcutsManager.displayString(for: key))
                        .tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 60)
        }
    }

    private func staticShortcutDisplay(shortcut: String) -> some View {
        Text(shortcut)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(AppColors.textSecondary)
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            VStack(spacing: 0) {
                // Activity Font Size
                SettingsWindowRow {
                    HStack {
                        Label("Activity Text Size", systemImage: "textformat.size")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        StepperControl(
                            value: $fontSizeManager.activityFontSize,
                            range: 9...24,
                            formatter: { "\(Int($0)) pt" }
                        )
                    }
                }

                Divider()

                // Diff Font Size
                SettingsWindowRow {
                    HStack {
                        Label("Diff Text Size", systemImage: "doc.text")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        StepperControl(
                            value: $fontSizeManager.diffFontSize,
                            range: 9...24,
                            formatter: { "\(Int($0)) pt" }
                        )
                    }
                }

                Divider()

                // Reset to Defaults
                SettingsWindowRow {
                    HStack {
                        Label("Reset Text Sizes", systemImage: "arrow.counterclockwise")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingResetConfirmation = true
                    }
                }
            }
        }
    }

    // MARK: - Repository Folders Section

    private var connectedSources: [Source] {
        dataManager.sources.filter { source in
            if let path = localRepoPaths[source.id], !path.isEmpty {
                return true
            }
            return false
        }
    }

    private var unconnectedSources: [Source] {
        dataManager.sources.filter { source in
            localRepoPaths[source.id] == nil || localRepoPaths[source.id]?.isEmpty == true
        }
    }

    private var repositoryFoldersSection: some View {
        SettingsSection(title: "Repository Folders") {
            VStack(spacing: 0) {
                // Show connected repositories
                if !connectedSources.isEmpty {
                    ForEach(connectedSources) { source in
                        VStack(spacing: 0) {
                            SettingsWindowRow {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label(source.displayName, systemImage: "folder")
                                            .foregroundColor(AppColors.textPrimary)
                                        Spacer()
                                    }

                                    HStack {
                                        if let path = localRepoPaths[source.id] {
                                            Text(path)
                                                .font(.system(size: 11))
                                                .foregroundColor(AppColors.textSecondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()

                                        Button(action: {
                                            selectFolder(for: source.id)
                                        }) {
                                            Text("Change")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button(action: {
                                            removeFolder(for: source.id)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(AppColors.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove folder link")
                                    }
                                }
                            }

                            if source.id != connectedSources.last?.id {
                                Divider()
                            }
                        }
                    }

                    Divider()
                }

                // Add button and inline form
                if showingAddForm && !unconnectedSources.isEmpty {
                    SettingsWindowRow {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add Repository Folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Repository:")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textSecondary)

                                Picker("", selection: $selectedSourceId) {
                                    Text("Select a repository").tag("")
                                    ForEach(unconnectedSources) { source in
                                        Text(source.displayName).tag(source.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Local Folder:")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textSecondary)

                                HStack {
                                    if selectedFolderPath.isEmpty {
                                        Text("No folder selected")
                                            .font(.system(size: 11))
                                            .foregroundColor(AppColors.textSecondary.opacity(0.6))
                                    } else {
                                        Text(selectedFolderPath)
                                            .font(.system(size: 11))
                                            .foregroundColor(AppColors.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Button("Select Folder") {
                                        selectFolderForAdd()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            HStack {
                                Button("Cancel") {
                                    cancelAddForm()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Add") {
                                    addFolderConnection()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(selectedSourceId.isEmpty || selectedFolderPath.isEmpty)
                            }
                        }
                    }

                    Divider()
                }

                // Add button
                if !unconnectedSources.isEmpty && !showingAddForm {
                    SettingsWindowRow {
                        HStack {
                            Button(action: {
                                showingAddForm = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add")
                                }
                                .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }
                    }

                    Divider()
                }

                Divider()

                SettingsWindowRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Link local folders to enable autocomplete and local merge features.")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary.opacity(0.8))
                    }
                }
            }
        }
    }

    private func loadLocalRepoPaths() {
        localRepoPaths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String] ?? [:]
    }

    private func selectFolder(for sourceId: String) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Repository Root"
        openPanel.message = "Select the local folder for this repository"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            // Save bookmark for permission persistence
            do {
                let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                var bookmarks = UserDefaults.standard.dictionary(forKey: "localRepoBookmarksKey") as? [String: Data] ?? [:]
                bookmarks[sourceId] = data
                UserDefaults.standard.set(bookmarks, forKey: "localRepoBookmarksKey")
            } catch {
                print("Failed to create bookmark: \(error)")
            }

            // Save path string
            localRepoPaths[sourceId] = url.path
            var paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String] ?? [:]
            paths[sourceId] = url.path
            UserDefaults.standard.set(paths, forKey: "localRepoPathsKey")

            // Update autocomplete manager
            FilenameAutocompleteManager.shared.registerRepository(repositoryId: sourceId, localPath: url.path)
        }
    }

    private func removeFolder(for sourceId: String) {
        // Remove from local state
        localRepoPaths.removeValue(forKey: sourceId)

        // Remove from UserDefaults
        var paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String] ?? [:]
        paths.removeValue(forKey: sourceId)
        UserDefaults.standard.set(paths, forKey: "localRepoPathsKey")

        var bookmarks = UserDefaults.standard.dictionary(forKey: "localRepoBookmarksKey") as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: sourceId)
        UserDefaults.standard.set(bookmarks, forKey: "localRepoBookmarksKey")

        // Update autocomplete manager (unregister watcher)
        FilenameAutocompleteManager.shared.unregisterRepository(repositoryId: sourceId)
        // Re-register without local path (to keep diff cache)
        FilenameAutocompleteManager.shared.registerRepository(repositoryId: sourceId)
    }

    private func selectFolderForAdd() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Repository Root"
        openPanel.message = "Select the local folder for this repository"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            selectedFolderPath = url.path
        }
    }

    private func cancelAddForm() {
        showingAddForm = false
        selectedSourceId = ""
        selectedFolderPath = ""
    }

    private func addFolderConnection() {
        guard !selectedSourceId.isEmpty, !selectedFolderPath.isEmpty else {
            return
        }

        // Save bookmark for permission persistence
        if let url = URL(fileURLWithPath: selectedFolderPath) as URL? {
            do {
                let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                var bookmarks = UserDefaults.standard.dictionary(forKey: "localRepoBookmarksKey") as? [String: Data] ?? [:]
                bookmarks[selectedSourceId] = data
                UserDefaults.standard.set(bookmarks, forKey: "localRepoBookmarksKey")
            } catch {
                print("Failed to create bookmark: \(error)")
            }

            // Save path string
            localRepoPaths[selectedSourceId] = selectedFolderPath
            var paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String] ?? [:]
            paths[selectedSourceId] = selectedFolderPath
            UserDefaults.standard.set(paths, forKey: "localRepoPathsKey")

            // Update autocomplete manager
            FilenameAutocompleteManager.shared.registerRepository(repositoryId: selectedSourceId, localPath: selectedFolderPath)
        }

        // Reset form
        cancelAddForm()
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        SettingsSection(title: "Storage") {
            VStack(spacing: 0) {
                // Cached Sessions Info
                SettingsWindowRow {
                    HStack {
                        Label("Cached Sessions", systemImage: "internaldrive")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Text("\(cachedSessionCount) sessions")
                            .foregroundColor(AppColors.textSecondary)
                    }
                }

                Divider()

                // Clear All Caches
                SettingsWindowRow {
                    HStack {
                        Label(isClearingCache ? "Clearing..." : "Clear All Caches", systemImage: "trash")
                            .foregroundColor(isClearingCache ? AppColors.textSecondary : AppColors.textPrimary)
                        Spacer()
                        if isClearingCache {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isClearingCache {
                            showingClearCacheConfirmation = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            VStack(spacing: 0) {
                // Version
                SettingsWindowRow {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }

                Divider()

                // Check for Updates
                SettingsWindowRow {
                    HStack {
                        Label("Check for Updates...", systemImage: "arrow.down.circle")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        checkForUpdates()
                    }
                }

                Divider()

                // Send Feedback
                SettingsWindowRow {
                    HStack {
                        Label("Send Feedback...", systemImage: "envelope")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingFeedback = true
                    }
                }

                Divider()

                // Credits
                SettingsWindowRow {
                    VStack(spacing: 4) {

                        HStack(spacing: 4) {
                            Text("Made by")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textSecondary.opacity(0.7))

                            if let url = URL(string: "https://x.com/simpsoka") {
                                Link("Kathy Korevec", destination: url)
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.accent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 80, alignment: .leading)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.8))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func checkForUpdates() {
        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
    }

    private func resetAllSettings() {
        fontSizeManager.resetToDefaults()
    }

    private func clearAllCaches() {
        isClearingCache = true

        Task {
            let result = await CacheManager.shared.clearAllCaches()

            await MainActor.run {
                isClearingCache = false
                cachedSessionCount = 0

                if result.success {
                    FlashMessageManager.shared.show(message: "Caches cleared successfully", type: .success)
                    // Trigger a refresh from the server
                    Task {
                        await dataManager.forceRefreshSessions()
                        dataManager.forceRefreshSources()
                    }
                } else {
                    FlashMessageManager.shared.show(message: "Some caches could not be cleared", type: .error)
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            VStack(spacing: 0) {
                content
            }
            .background(AppColors.backgroundSecondary)
            .cornerRadius(8)
        }
    }
}

struct SettingsWindowRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

struct StepperControl: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let formatter: (CGFloat) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(formatter(value))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)

            HStack(spacing: 0) {
                Button(action: {
                    if value > range.lowerBound {
                        value -= 1
                    }
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Divider()
                    .frame(height: 14)

                Button(action: {
                    if value < range.upperBound {
                        value += 1
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }
            .background(AppColors.backgroundSecondary)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.textSecondary.opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}
