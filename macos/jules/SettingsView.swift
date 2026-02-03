import SwiftUI
import Sparkle
import HotKey

struct SettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var fontSizeManager = FontSizeManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @StateObject private var networkLogger = NetworkLogger.shared
    @StateObject private var keyboardShortcutsManager = KeyboardShortcutsManager.shared
    @Binding var showSettings: Bool

    // Local state for API key editing
    @State private var apiKeyInput: String = ""
    @State private var isApiKeyVisible: Bool = false
    @State private var showingResetConfirmation: Bool = false
    @State private var showingNetworkLogs: Bool = false
    @State private var showingFeedback: Bool = false

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Header with Back Button ---
            settingsHeader

            Divider()
                .background(AppColors.separator)

            // --- Settings Content ---
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // API Section
                    apiSection

                    // General Section
                    generalSection

                    // Key Commands Section
                    keyCommandsSection

                    // Appearance Section
                    appearanceSection

                    // Developer Section
                    developerSection

                    // About Section
                    aboutSection
                }
                .padding(.bottom, verticalPadding)
            }
        }
        .frame(width: dataManager.isPopoverExpanded ? AppConstants.Popover.expandedWidth : AppConstants.Popover.minimizedWidth)
        .background(AppColors.background)
        .onAppear {
            apiKeyInput = dataManager.apiKey
        }
        .alert("Reset Settings", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will reset font sizes to their defaults. Your API key will not be affected.")
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Button(action: {
                // Save API key when leaving settings
                if apiKeyInput != dataManager.apiKey {
                    dataManager.apiKey = apiKeyInput
                }
                withAnimation {
                    showSettings = false
                }
            }) {
                Image(systemName: "arrow.left")
                    .foregroundColor(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, horizontalPadding)

            Spacer()

            Text("Settings")
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            // Balance the back button
            Image(systemName: "arrow.left")
                .foregroundColor(.clear)
                .padding(.trailing, horizontalPadding)
        }
        .padding(.vertical, verticalPadding)
    }

    // MARK: - API Section

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "API")

            SettingsSectionContainer {
                // API Key Row
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.accent)
                        .frame(width: 20)

                    Text("Jules API Key")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textPrimary)

                    Spacer()

                    HStack(spacing: 8) {
                        if isApiKeyVisible {
                            TextField("Enter API Key", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(AppColors.textPrimary)
                                .frame(maxWidth: 120)
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
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppColors.backgroundSecondary)

                // Get API Key button
                SettingsNavigationRow(
                    icon: "globe",
                    title: "Get API Key...",
                    action: {
                        dataManager.openSettings()
                    }
                )
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
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "General")

            SettingsSectionContainer {
                SettingsToggleRow(
                    icon: "play.circle",
                    title: "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { newValue in
                            Task {
                                await launchAtLoginManager.toggle()
                            }
                        }
                    )
                )

                SettingsToggleRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    isOn: $notificationManager.isEnabled
                )

                // Launch Position
                SettingsPickerRow(
                    icon: "macwindow",
                    title: "Launch Position",
                    selection: $dataManager.menuLaunchPosition
                ) {
                    ForEach(MenuLaunchPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }

                // Screen Capture Permission
                SettingsRowView(
                    icon: "camera.viewfinder",
                    iconColor: screenCaptureManager.hasPermission ? AppColors.textSecondary : AppColors.accent,
                    title: "Screenshot"
                ) {
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
                .onAppear {
                    screenCaptureManager.updatePermissionStatus()
                }
                .onChange(of: screenCaptureManager.hasPermission) { _ in
                    // Force UI refresh when permission changes
                }
            }
        }
    }

    // MARK: - Key Commands Section

    private var keyCommandsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Key Commands")

            SettingsSectionContainer {
                // Toggle Jules
                keyCommandRow(
                    icon: "command",
                    title: "Toggle Jules",
                    selection: $keyboardShortcutsManager.toggleJulesKey
                )

                // Screenshot
                keyCommandRow(
                    icon: "camera.viewfinder",
                    title: "Capture Screenshot",
                    selection: $keyboardShortcutsManager.screenshotKey
                )

                // Voice Input (macOS 26.0+ only)
                if #available(macOS 26.0, *) {
                    keyCommandRow(
                        icon: "mic",
                        title: "Voice Input",
                        selection: $keyboardShortcutsManager.voiceInputKey
                    )
                }

                // Text Size Commands (non-editable)
                staticKeyCommandRow(
                    icon: "plus.magnifyingglass",
                    title: "Make Text Bigger",
                    shortcut: "\u{2318}++"
                )

                staticKeyCommandRow(
                    icon: "minus.magnifyingglass",
                    title: "Make Text Smaller",
                    shortcut: "\u{2318}+-"
                )

                staticKeyCommandRow(
                    icon: "arrow.counterclockwise.circle",
                    title: "Reset Text Size",
                    shortcut: "\u{2318}+0"
                )

                // Reset Key Commands
                SettingsNavigationRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset Key Commands",
                    action: {
                        keyboardShortcutsManager.resetToDefaults()
                    }
                )
            }
        }
    }

    private func keyCommandRow(icon: String, title: String, selection: Binding<Key>) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            HStack(spacing: 4) {
                Text("^+\u{2325}+")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AppColors.textSecondary)

                Picker("", selection: selection) {
                    ForEach(KeyboardShortcutsManager.availableKeys) { key in
                        Text(KeyboardShortcutsManager.displayString(for: key))
                            .tag(key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 50)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
    }

    private func staticKeyCommandRow(icon: String, title: String, shortcut: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Appearance")

            SettingsSectionContainer {
                // Activity Font Size
                SettingsStepperRow(
                    icon: "textformat.size",
                    title: "Activity Text Size",
                    value: $fontSizeManager.activityFontSize,
                    range: 9...24,
                    step: 1,
                    formatter: { "\(Int($0)) pt" }
                )

                // Diff Font Size
                SettingsStepperRow(
                    icon: "doc.text",
                    title: "Diff Text Size",
                    value: $fontSizeManager.diffFontSize,
                    range: 9...24,
                    step: 1,
                    formatter: { "\(Int($0)) pt" }
                )

                // Reset to Defaults
                SettingsNavigationRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset Text Sizes",
                    action: {
                        showingResetConfirmation = true
                    }
                )
            }
        }
    }

    // MARK: - Developer Section

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Developer")

            SettingsSectionContainer {
                // Network Logging Toggle
                SettingsToggleRow(
                    icon: "network",
                    title: "Network Logging",
                    isOn: $networkLogger.isEnabled
                )

                // Log Response Bodies Toggle (only shown if logging is enabled)
                if networkLogger.isEnabled {
                    SettingsToggleRow(
                        icon: "doc.text",
                        title: "Log Response Bodies",
                        isOn: $networkLogger.logResponseBodies
                    )

                    // View Logs
                    SettingsNavigationRow(
                        icon: "list.bullet.rectangle",
                        title: "View Network Logs",
                        value: "\(networkLogger.recentLogs.count) entries",
                        action: {
                            showingNetworkLogs = true
                        }
                    )

                    // Export Logs
                    SettingsNavigationRow(
                        icon: "square.and.arrow.up",
                        title: "Export Logs to File",
                        action: {
                            exportNetworkLogs()
                        }
                    )

                    // Clear Logs
                    SettingsNavigationRow(
                        icon: "trash",
                        title: "Clear Logs",
                        action: {
                            networkLogger.clearLogs()
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showingNetworkLogs) {
            NetworkLogsView()
        }
    }

    private func exportNetworkLogs() {
        if let logFileURL = networkLogger.getLogFilePath() {
            NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "About")

            SettingsSectionContainer {
                // Version
                SettingsRowView(icon: "info.circle", title: "Version") {
                    Text(appVersion)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                }

                // Check for Updates
                SettingsNavigationRow(
                    icon: "arrow.down.circle",
                    title: "Check for Updates...",
                    action: {
                        checkForUpdates()
                    }
                )

                // Send Feedback
                SettingsNavigationRow(
                    icon: "envelope",
                    title: "Send Feedback...",
                    action: {
                        showingFeedback = true
                    }
                )

                // Keyboard Shortcuts
                SettingsNavigationRow(
                    icon: "keyboard",
                    title: "Keyboard Shortcuts",
                    value: "",
                    action: {
                        // Could show a sheet with shortcuts in the future
                    }
                )
            }

            // Keyboard shortcuts info
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)

                Group {
                    shortcutRow(keys: keyboardShortcutsManager.fullShortcutString(for: .toggleJules), description: "Toggle Jules")
                    shortcutRow(keys: keyboardShortcutsManager.fullShortcutString(for: .screenshot), description: "Capture screenshot")
                    if #available(macOS 26.0, *) {
                        shortcutRow(keys: keyboardShortcutsManager.fullShortcutString(for: .voiceInput), description: "Voice input")
                    }
                    shortcutRow(keys: "\u{2318}++", description: "Increase text size")
                    shortcutRow(keys: "\u{2318}+-", description: "Decrease text size")
                    shortcutRow(keys: "\u{2318}+0", description: "Reset text size")
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)

            // Credits footer
            VStack(spacing: 4) {

                HStack(spacing: 4) {
                    Text("Made by")
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.textSecondary.opacity(0.6))

                    Link("Kathy Korevec", destination: URL(string: "https://x.com/simpsoka")!)
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackView()
        }
    }

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 70, alignment: .leading)

            Text(description)
                .font(.system(size: 10))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func checkForUpdates() {
        // Post notification to AppDelegate to check for updates
        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
    }

    private func resetAllSettings() {
        fontSizeManager.resetToDefaults()
    }
}

extension NSNotification.Name {
    static let checkForUpdates = NSNotification.Name("checkForUpdates")
    static let openSettings = NSNotification.Name("openSettings")
}
