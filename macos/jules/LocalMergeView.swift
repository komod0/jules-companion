//
//  LocalMergeView.swift
//  jules
//
//  View for local merge conflict resolution using the Metal-based MergeConflictView.
//

import SwiftUI

struct LocalMergeView: View {
    @StateObject var viewModel: MergeViewModel

    @Environment(\.colorScheme) var colorScheme

    init(session: Session) {
        _viewModel = StateObject(wrappedValue: MergeViewModel(session: session))
    }

    var body: some View {
        // Use Metal-based MergeConflictView for full conflict resolution support
        MergeConflictView(
            text: $viewModel.fileContent,
            isEditable: false,  // Metal view is read-only with action buttons
            language: "swift"
        )
    }
}
