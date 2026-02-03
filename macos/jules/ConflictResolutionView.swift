//
//  ConflictResolutionView.swift
//  jules
//
//  Wrapper view for conflict resolution using the Metal-based MergeConflictView.
//

import SwiftUI

struct ConflictResolutionView: View {
    @Binding var text: String
    var isEditable: Bool = true
    var language: String = "swift"

    var body: some View {
        // Use the full Metal-based MergeConflictView for conflict resolution
        MergeConflictView(
            text: $text,
            isEditable: isEditable,
            language: language
        )
    }
}
