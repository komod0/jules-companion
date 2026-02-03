import Foundation
import os.signpost
import Darwin

/// A profiler for tracking SessionController and related component loading times.
/// Use this to identify bottlenecks in the loading process before `isLoaded` becomes true.
///
/// Usage:
/// 1. Call `LoadingProfiler.shared.startSession()` at the beginning of SessionController.init()
/// 2. Call checkpoint methods at key points in the loading flow
/// 3. Call `endSession()` when loading is complete
/// 4. View the report with `generateReport()`
@MainActor
final class LoadingProfiler {
    static let shared = LoadingProfiler()

    // MARK: - Configuration

    /// Set to true to enable profiling (disabled by default for production)
    var isEnabled: Bool = false

    /// Set to true to print checkpoints as they occur
    var printLiveUpdates: Bool = true

    /// Set to true to include memory stats in profiling output
    var includeMemoryStats: Bool = true

    /// Set to true to enable memory profiling logs (separate from main profiler)
    /// Controls: [Memory], [MemoryFix], [MemoryDebug], [HeavyData], [DiffCache] logs
    nonisolated(unsafe) static var memoryProfilingEnabled: Bool = false

    /// Filter options for memory logs (only used when memoryProfilingEnabled is true)
    struct MemoryLogFilter {
        /// Minimum delta (MB) to show - hides small memory changes
        var minDeltaMB: Double = 0

        /// Only show logs containing these substrings (empty = show all)
        var includePatterns: [String] = []

        /// Hide logs containing these substrings
        var excludePatterns: [String] = []

        /// Default: show everything
        static let all = MemoryLogFilter()

        /// Only show significant changes (>5 MB delta)
        static let significantOnly = MemoryLogFilter(minDeltaMB: 5.0)

        /// Only show flagged items (🟡, 🟠, 🔴)
        static let flaggedOnly = MemoryLogFilter(minDeltaMB: 10.0)

        /// Focus on specific component
        static func component(_ name: String) -> MemoryLogFilter {
            MemoryLogFilter(includePatterns: [name])
        }

        /// Exclude noisy components
        static func excluding(_ patterns: String...) -> MemoryLogFilter {
            MemoryLogFilter(excludePatterns: Array(patterns))
        }
    }

    /// Current filter for memory logs
    nonisolated(unsafe) static var memoryLogFilter = MemoryLogFilter.all

    // MARK: - Signpost for Instruments

    private let signpostLog = OSLog(subsystem: "com.jules.app", category: "Loading")
    private var signpostID: OSSignpostID?

    // MARK: - Timing Data

    private var sessionStartTime: CFAbsoluteTime?
    private var checkpoints: [(name: String, timestamp: CFAbsoluteTime, duration: CFAbsoluteTime?, memoryMB: Double, memoryDeltaMB: Double?)] = []
    private var activeSpans: [String: (startTime: CFAbsoluteTime, startMemoryMB: Double)] = [:]

    /// Tracks nested operations with their parent relationships
    private var spanStack: [String] = []

    /// Baseline memory at session start
    private var sessionStartMemoryMB: Double = 0

    // MARK: - Memory Tracking

    /// Returns current memory usage in MB using mach API
    nonisolated func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    /// Formats memory size for display
    private func formatMemory(_ mb: Double) -> String {
        if abs(mb) < 1 {
            return String(format: "%.1f KB", mb * 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Session Management

    /// Starts a new profiling session. Call this at the very beginning of SessionController.init()
    func startSession(label: String = "SessionController Load") {
        guard isEnabled else { return }

        // Reset state
        checkpoints.removeAll()
        activeSpans.removeAll()
        spanStack.removeAll()
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        sessionStartMemoryMB = currentMemoryMB()

        // Start signpost for Instruments
        signpostID = OSSignpostID(log: signpostLog)
        if let id = signpostID {
            os_signpost(.begin, log: signpostLog, name: "SessionLoad", signpostID: id, "%{public}s", label)
        }

        if printLiveUpdates {
            print("📊 [LoadingProfiler] Started profiling: \(label)")
        }
    }

    /// Records a checkpoint (instant marker) in the loading flow
    func checkpoint(_ name: String) {
        guard isEnabled, let startTime = sessionStartTime else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = (now - startTime) * 1000 // Convert to milliseconds
        let currentMem = currentMemoryMB()
        let memDelta = currentMem - sessionStartMemoryMB

        checkpoints.append((name: name, timestamp: now, duration: nil, memoryMB: currentMem, memoryDeltaMB: memDelta))

        // Signpost event
        os_signpost(.event, log: signpostLog, name: "Checkpoint", "%{public}s", name)

        if printLiveUpdates {
            let indent = String(repeating: "  ", count: spanStack.count)
            let memStr = includeMemoryStats ? " [mem: \(formatMemory(currentMem)), Δ\(memDelta >= 0 ? "+" : "")\(formatMemory(memDelta))]" : ""
            print("📊 [LoadingProfiler] \(indent)✓ \(name) @ \(String(format: "%.2f", elapsed))ms\(memStr)")
        }
    }

    /// Begins a named span (for measuring duration of an operation)
    func beginSpan(_ name: String) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let currentMem = currentMemoryMB()
        activeSpans[name] = (startTime: now, startMemoryMB: currentMem)
        spanStack.append(name)

        // Signpost interval begin
        if let id = signpostID {
            os_signpost(.begin, log: signpostLog, name: "Span", signpostID: id, "%{public}s", name)
        }

        if printLiveUpdates {
            let indent = String(repeating: "  ", count: spanStack.count - 1)
            let memStr = includeMemoryStats ? " [mem: \(formatMemory(currentMem))]" : ""
            print("📊 [LoadingProfiler] \(indent)→ \(name) started\(memStr)")
        }
    }

    /// Ends a named span and records its duration
    func endSpan(_ name: String) {
        guard isEnabled, let spanData = activeSpans[name] else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let duration = (now - spanData.startTime) * 1000 // Convert to milliseconds
        let currentMem = currentMemoryMB()
        let memDelta = currentMem - spanData.startMemoryMB

        checkpoints.append((name: name, timestamp: now, duration: duration, memoryMB: currentMem, memoryDeltaMB: memDelta))
        activeSpans.removeValue(forKey: name)

        if let index = spanStack.lastIndex(of: name) {
            spanStack.remove(at: index)
        }

        // Signpost interval end
        if let id = signpostID {
            os_signpost(.end, log: signpostLog, name: "Span", signpostID: id, "%{public}s", name)
        }

        if printLiveUpdates {
            let indent = String(repeating: "  ", count: spanStack.count)
            let emoji = duration > 100 ? "🔴" : duration > 50 ? "🟡" : "🟢"
            let memEmoji = memDelta > 10 ? "🔺" : memDelta > 5 ? "🔸" : memDelta < -1 ? "🔻" : ""
            let memStr = includeMemoryStats ? " [Δmem: \(memDelta >= 0 ? "+" : "")\(formatMemory(memDelta))\(memEmoji)]" : ""
            print("📊 [LoadingProfiler] \(indent)\(emoji) \(name) completed in \(String(format: "%.2f", duration))ms\(memStr)")
        }
    }

    /// Ends the profiling session and returns the total load time
    @discardableResult
    func endSession() -> CFAbsoluteTime {
        guard isEnabled, let startTime = sessionStartTime else { return 0 }

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // End signpost
        if let id = signpostID {
            os_signpost(.end, log: signpostLog, name: "SessionLoad", signpostID: id, "Total: %.2fms", totalTime)
        }

        if printLiveUpdates {
            print("📊 [LoadingProfiler] ═══════════════════════════════════════")
            print("📊 [LoadingProfiler] Session load complete: \(String(format: "%.2f", totalTime))ms")
            print("📊 [LoadingProfiler] ═══════════════════════════════════════")
        }

        return totalTime
    }

    // MARK: - Memory-Only Logging (Controlled by memoryProfilingEnabled)

    /// Checks if a log message should be shown based on current filter
    nonisolated private func shouldShowLog(_ label: String, delta: Double? = nil) -> Bool {
        let filter = Self.memoryLogFilter

        // Check delta threshold
        if let d = delta, abs(d) < filter.minDeltaMB {
            return false
        }

        // Check include patterns (if any specified, must match at least one)
        if !filter.includePatterns.isEmpty {
            let matches = filter.includePatterns.contains { label.contains($0) }
            if !matches { return false }
        }

        // Check exclude patterns
        for pattern in filter.excludePatterns {
            if label.contains(pattern) { return false }
        }

        return true
    }

    /// Logs memory usage for debugging purposes.
    /// Controlled by LoadingProfiler.memoryProfilingEnabled flag.
    /// Use for debugging specific operations like activity fetching.
    nonisolated func logMemory(_ label: String) {
        guard Self.memoryProfilingEnabled else { return }
        guard shouldShowLog(label) else { return }
        let currentMem = currentMemoryMB()
        print("🧠 [Memory] \(label): \(String(format: "%.1f", currentMem)) MB")
    }

    /// Logs memory delta between two points.
    /// Call startMemoryTrace to get a baseline, then endMemoryTrace to log the delta.
    nonisolated(unsafe) private var memoryTraceBaselines: [String: Double] = [:]
    private let memoryTraceLock = NSLock()

    nonisolated func startMemoryTrace(_ label: String) {
        guard Self.memoryProfilingEnabled else { return }
        // Always record baseline even if filtered, so endMemoryTrace can calculate delta
        let currentMem = currentMemoryMB()
        memoryTraceLock.lock()
        memoryTraceBaselines[label] = currentMem
        memoryTraceLock.unlock()
        guard shouldShowLog(label) else { return }
        print("🧠 [Memory] \(label) START: \(String(format: "%.1f", currentMem)) MB")
    }

    nonisolated func endMemoryTrace(_ label: String) {
        guard Self.memoryProfilingEnabled else { return }
        let currentMem = currentMemoryMB()
        memoryTraceLock.lock()
        let baseline = memoryTraceBaselines.removeValue(forKey: label) ?? currentMem
        memoryTraceLock.unlock()
        let delta = currentMem - baseline
        // For end traces, check filter with the actual delta value
        guard shouldShowLog(label, delta: delta) else { return }
        let emoji = delta > 50 ? "🔴" : delta > 20 ? "🟠" : delta > 10 ? "🟡" : delta < -5 ? "🟢" : ""
        print("🧠 [Memory] \(label) END: \(String(format: "%.1f", currentMem)) MB (Δ\(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta)) MB) \(emoji)")
    }

    // MARK: - Report Generation

    /// Generates a detailed report of all checkpoints and spans
    func generateReport() -> String {
        guard isEnabled, let startTime = sessionStartTime else {
            return "Profiling not enabled or no session started"
        }

        var report = """
        ╔══════════════════════════════════════════════════════════════╗
        ║            SessionController Loading Profile Report           ║
        ╠══════════════════════════════════════════════════════════════╣

        """

        // Sort checkpoints by timestamp
        let sortedCheckpoints = checkpoints.sorted { $0.timestamp < $1.timestamp }

        // Group into categories
        let categories = [
            "Init": sortedCheckpoints.filter { $0.name.hasPrefix("Init:") },
            "Setup": sortedCheckpoints.filter { $0.name.hasPrefix("Setup:") },
            "View": sortedCheckpoints.filter { $0.name.hasPrefix("View:") },
            "Data": sortedCheckpoints.filter { $0.name.hasPrefix("Data:") },
            "Other": sortedCheckpoints.filter { name in
                !["Init:", "Setup:", "View:", "Data:"].contains(where: { name.name.hasPrefix($0) })
            }
        ]

        for (category, items) in categories where !items.isEmpty {
            report += "── \(category) ──────────────────────────────────────────────\n"
            for item in items {
                let relativeTime = (item.timestamp - startTime) * 1000
                if let duration = item.duration {
                    let emoji = duration > 100 ? "🔴" : duration > 50 ? "🟡" : "🟢"
                    report += String(format: "  %@ %-40s %7.2fms (@ %7.2fms)\n",
                                    emoji, (item.name as NSString).utf8String ?? "",
                                    duration, relativeTime)
                } else {
                    report += String(format: "  ✓ %-40s          (@ %7.2fms)\n",
                                    (item.name as NSString).utf8String ?? "",
                                    relativeTime)
                }
            }
            report += "\n"
        }

        // Summary
        let totalTime = checkpoints.last.map { ($0.timestamp - startTime) * 1000 } ?? 0
        let slowestSpans = checkpoints
            .filter { $0.duration != nil }
            .sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
            .prefix(5)

        report += """
        ── Summary ────────────────────────────────────────────────────
          Total Load Time: \(String(format: "%.2f", totalTime))ms

          Top 5 Slowest Operations:
        """

        for (index, span) in slowestSpans.enumerated() {
            if let duration = span.duration {
                report += String(format: "\n    %d. %-35s %7.2fms", index + 1, (span.name as NSString).utf8String ?? "", duration)
            }
        }

        report += "\n\n╚══════════════════════════════════════════════════════════════╝"

        return report
    }

    // MARK: - Convenience Methods for Common Operations

    /// Profiles a synchronous block of code
    func profile<T>(_ name: String, block: () -> T) -> T {
        beginSpan(name)
        let result = block()
        endSpan(name)
        return result
    }

    /// Profiles an async block of code
    func profileAsync<T>(_ name: String, block: () async -> T) async -> T {
        beginSpan(name)
        let result = await block()
        endSpan(name)
        return result
    }

    /// Profiles an async throwing block of code
    func profileAsync<T>(_ name: String, block: () async throws -> T) async throws -> T {
        beginSpan(name)
        do {
            let result = try await block()
            endSpan(name)
            return result
        } catch {
            endSpan(name)
            throw error
        }
    }
}

// MARK: - Debug Helper Extension

extension LoadingProfiler {
    /// Enables profiling and prints instructions
    func enableWithInstructions() {
        isEnabled = true
        printLiveUpdates = true
        print("""

        ╔══════════════════════════════════════════════════════════════╗
        ║              LoadingProfiler ENABLED                          ║
        ╠══════════════════════════════════════════════════════════════╣
        ║                                                               ║
        ║  Profiling will track:                                        ║
        ║  • SessionController initialization stages                    ║
        ║  • Deferred view loading (isLoaded transitions)              ║
        ║  • DataManager fetch operations                               ║
        ║  • View rendering times                                       ║
        ║                                                               ║
        ║  Use Instruments with os_signpost for detailed analysis       ║
        ║                                                               ║
        ╚══════════════════════════════════════════════════════════════╝

        """)
    }
}
