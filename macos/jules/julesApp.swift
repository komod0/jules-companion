import SwiftUI

@main
struct MyMenuBarAppApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate


    var body: some Scene {
        // No WindowGroup or MenuBarExtra needed here anymore.
        // The AppDelegate will manage the lifecycle and UI presentation.
        // SwiftUI Settings scene - automatically wires to Settings... menu item
        Settings {
            SettingsWindowView()
                .environmentObject(appDelegate.dataManager)
        }
        .commands {
            // Add View menu commands for font size control
            ViewMenuCommands(appDelegate: appDelegate)
        }
    }
}

// MARK: - View Menu Commands

struct ViewMenuCommands: Commands {
    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                Button("Make Text Bigger") {
                    appDelegate.increaseFontSizeAction()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Make Text Smaller") {
                    appDelegate.decreaseFontSizeAction()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Text Size") {
                    appDelegate.resetFontSizeAction()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            #if DEBUG
            Section {
                Button("Test Merge Conflict View") {
                    appDelegate.showMergeConflictTestAction()
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])
            }
            #endif
        }

        CommandGroup(after: .help) {
            Button("User Feedback…") {
                appDelegate.showFeedbackWindow()
            }
        }
    }
}
