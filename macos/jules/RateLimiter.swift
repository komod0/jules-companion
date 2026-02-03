import Foundation

/// A sliding window rate limiter to track API requests and prevent exceeding quota.
/// Default limit: 100 requests per 60 seconds.
actor RateLimiter {
    private var requestTimestamps: [Date] = []
    private let windowDuration: TimeInterval
    private let maxRequests: Int
    private let warningThreshold: Int

    /// Creates a rate limiter with the specified limits.
    /// - Parameters:
    ///   - maxRequests: Maximum requests allowed in the window (default: 100)
    ///   - windowDuration: Duration of the sliding window in seconds (default: 60)
    ///   - warningThreshold: Number of requests at which to start throttling (default: 80)
    init(maxRequests: Int = 100, windowDuration: TimeInterval = 60, warningThreshold: Int = 80) {
        self.maxRequests = maxRequests
        self.windowDuration = windowDuration
        self.warningThreshold = warningThreshold
    }

    /// Cleans up old timestamps outside the sliding window.
    private func pruneOldTimestamps() {
        let cutoff = Date().addingTimeInterval(-windowDuration)
        requestTimestamps.removeAll { $0 < cutoff }
    }

    /// Records a new request.
    func recordRequest() {
        pruneOldTimestamps()
        requestTimestamps.append(Date())
    }

    /// Returns the current number of requests in the sliding window.
    func currentRequestCount() -> Int {
        pruneOldTimestamps()
        return requestTimestamps.count
    }

    /// Returns true if we're at or above the warning threshold.
    func isApproachingLimit() -> Bool {
        return currentRequestCount() >= warningThreshold
    }

    /// Returns true if we've hit the maximum request limit.
    func isAtLimit() -> Bool {
        return currentRequestCount() >= maxRequests
    }

    /// Returns the number of seconds until the oldest request expires from the window.
    /// This can be used to determine how long to wait before making more requests.
    func secondsUntilSlotAvailable() -> TimeInterval {
        pruneOldTimestamps()
        guard let oldestTimestamp = requestTimestamps.first else {
            return 0
        }
        let expirationTime = oldestTimestamp.addingTimeInterval(windowDuration)
        let waitTime = expirationTime.timeIntervalSinceNow
        return max(0, waitTime)
    }

    /// Checks if a request can be made immediately, or returns the wait time needed.
    /// - Returns: A tuple of (canProceed, waitTimeIfNeeded)
    func checkAvailability() -> (canProceed: Bool, waitTime: TimeInterval) {
        pruneOldTimestamps()
        if requestTimestamps.count < maxRequests {
            return (true, 0)
        }
        return (false, secondsUntilSlotAvailable())
    }

    /// Waits if necessary and then records a request.
    /// Use this for throttled requests that should wait rather than fail.
    func waitAndRecord() async {
        let (canProceed, waitTime) = checkAvailability()
        if !canProceed && waitTime > 0 {
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        recordRequest()
    }

    /// Returns the number of remaining requests available in the current window.
    func remainingRequests() -> Int {
        pruneOldTimestamps()
        return max(0, maxRequests - requestTimestamps.count)
    }
}

/// A priority-aware async semaphore that processes high-priority requests first.
/// Priority requests bypass the queue and are processed immediately (up to the limit).
/// Regular requests wait in a FIFO queue when the limit is reached.
actor PriorityAsyncSemaphore {
    private let limit: Int
    private var currentCount: Int = 0
    private var regularWaiters: [CheckedContinuation<Void, Never>] = []
    private var priorityWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a priority semaphore with the specified concurrency limit.
    /// - Parameter limit: Maximum number of concurrent operations allowed
    init(limit: Int) {
        self.limit = limit
    }

    /// Acquires a slot with priority handling.
    /// Priority requests are processed before regular requests in the queue.
    /// - Parameter priority: If true, this request gets priority over regular requests
    func acquire(priority: Bool) async {
        if currentCount < limit {
            currentCount += 1
            return
        }

        // Wait for a slot to become available
        await withCheckedContinuation { continuation in
            if priority {
                priorityWaiters.append(continuation)
            } else {
                regularWaiters.append(continuation)
            }
        }
        currentCount += 1
    }

    /// Releases a slot, allowing a waiting operation to proceed.
    /// Priority waiters are resumed before regular waiters.
    func release() {
        currentCount -= 1
        // Priority waiters get served first
        if let waiter = priorityWaiters.first {
            priorityWaiters.removeFirst()
            waiter.resume()
        } else if let waiter = regularWaiters.first {
            regularWaiters.removeFirst()
            waiter.resume()
        }
    }

    /// Returns the number of currently active operations.
    var activeCount: Int {
        return currentCount
    }

    /// Returns the number of operations waiting for a slot.
    var waitingCount: Int {
        return priorityWaiters.count + regularWaiters.count
    }

    /// Returns the number of priority operations waiting.
    var priorityWaitingCount: Int {
        return priorityWaiters.count
    }
}
