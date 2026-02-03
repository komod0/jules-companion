import SwiftUI

struct MainSessionView: View {
    @EnvironmentObject var dataManager: DataManager

    /// The session to display. If nil, shows a new session creation view.
    let session: Session?

    var body: some View {
        TrajectoryView(session: session)
    }
}
