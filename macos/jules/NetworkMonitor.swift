import Foundation
import Network
import Combine

/// Monitors network connectivity and provides reactive updates
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "NetworkMonitor")

    /// Current network connectivity status
    @Published private(set) var isConnected: Bool = true

    /// Current network path status
    @Published private(set) var pathStatus: NWPath.Status = .satisfied

    /// Whether the connection is expensive (cellular)
    @Published private(set) var isExpensive: Bool = false

    /// Publisher that emits when connectivity is restored (transitions from offline to online)
    let connectivityRestoredPublisher = PassthroughSubject<Void, Never>()

    private var wasConnected: Bool = true

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let newIsConnected = path.status == .satisfied
                let previouslyConnected = self.wasConnected

                self.pathStatus = path.status
                self.isConnected = newIsConnected
                self.isExpensive = path.isExpensive
                self.wasConnected = newIsConnected

                // Emit connectivity restored event when transitioning from offline to online
                if !previouslyConnected && newIsConnected {
                    print("🌐 Network connectivity restored")
                    self.connectivityRestoredPublisher.send()
                } else if previouslyConnected && !newIsConnected {
                    print("📴 Network connectivity lost")
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
