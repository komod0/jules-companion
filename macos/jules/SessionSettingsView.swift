import SwiftUI

struct SessionSettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var localPath: String = ""
    var session: Session?

    /// Look up the source ID from the source name
    private var sourceId: String? {
        guard let sourceName = session?.sourceContext?.source else { return nil }
        return dataManager.sources.first(where: { $0.name == sourceName })?.id
    }

    var body: some View {
        Form {
            Section(header: Text("Repository Configuration")) {
                if let session = session, let sourceContext = session.sourceContext {
                     Text("Source: \(sourceContext.source)")

                     HStack {
                         Text(localPath.isEmpty ? "No path selected" : localPath)
                             .foregroundColor(localPath.isEmpty ? .secondary : .primary)
                             .lineLimit(1)
                             .truncationMode(.middle)

                         Spacer()

                         Button("Choose Folder...") {
                             promptForFolder()
                         }
                     }
                     .padding(.vertical, 4)

                     Text("Select the root directory of the local repository matching this source.")
                         .font(.caption)
                         .foregroundColor(.secondary)
                } else {
                    Text("No active session to configure.")
                }
            }
        }
        .padding()
        .onAppear {
            loadPath()
        }
    }

    private func loadPath() {
        guard let sourceId = sourceId else { return }
        let paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String]
        localPath = paths?[sourceId] ?? ""
    }

    private func promptForFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Repository Root"

        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                self.localPath = url.path
                savePath(url)
            }
        }
    }

    private func savePath(_ url: URL) {
        guard let sourceId = sourceId else { return }

        // Save bookmark for permission persistence (same as SettingsWindowView)
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = UserDefaults.standard.dictionary(forKey: "localRepoBookmarksKey") as? [String: Data] ?? [:]
            bookmarks[sourceId] = data
            UserDefaults.standard.set(bookmarks, forKey: "localRepoBookmarksKey")
        } catch {
            print("Failed to create bookmark: \(error)")
        }

        // Save path string
        var paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String] ?? [:]
        paths[sourceId] = url.path
        UserDefaults.standard.set(paths, forKey: "localRepoPathsKey")

        // Update autocomplete manager
        FilenameAutocompleteManager.shared.registerRepository(repositoryId: sourceId, localPath: url.path)
    }
}
