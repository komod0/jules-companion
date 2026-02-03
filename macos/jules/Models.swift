import Foundation
import SwiftUI
import GRDB
import CodeEditLanguages

// NB: Assumes AppColors struct exists and handles all statuses

// --- Session State Enum ---
enum SessionState: String, Codable, CaseIterable {
    case unspecified = "STATE_UNSPECIFIED"
    case queued = "QUEUED"
    case planning = "PLANNING"
    case awaitingPlanApproval = "AWAITING_PLAN_APPROVAL"
    case awaitingUserFeedback = "AWAITING_USER_FEEDBACK"
    case inProgress = "IN_PROGRESS"
    case paused = "PAUSED"
    case failed = "FAILED"
    case completed = "COMPLETED"
    /// Session was in an active state but was deleted from the server or became unresponsive.
    /// This is a client-side only state used to indicate the session ended but we don't know
    /// the actual outcome (the server may have deleted it, or it may have timed out).
    case completedUnknown = "COMPLETED_UNKNOWN"

    var menuIconName: String {
        switch self {
            case .queued, .planning, .inProgress: return "jules-menu-running-1"
            case .awaitingPlanApproval, .awaitingUserFeedback: return "jules-menu-warning"
            case .failed: return "jules-menu-failed"
            case .paused: return "jules-menu-review"
            case .completed, .completedUnknown: return  "jules-icon"
            case .unspecified: return "jules-icon"
        }
    }

    var iconName: String {
        switch self {
            case .queued: return "hourglass"
            case .planning: return "brain.head.profile"
            case .inProgress: return "bolt.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .awaitingPlanApproval, .awaitingUserFeedback: return "exclamationmark.triangle.fill"
            case .paused: return "pause.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .completedUnknown: return "questionmark.circle.fill"
            case .unspecified: return "bolt.circle.fill"
        }
    }

    var color: Color {
        // Map to existing AppColors if possible, or define new ones
        switch self {
        case .failed: return AppColors.linesRemoved
        case .completed: return AppColors.finished
        case .completedUnknown: return AppColors.finished  // Same as completed, slightly different icon
        case .awaitingPlanApproval, .awaitingUserFeedback: return AppColors.warning
        default: return AppColors.buttonBackground
        }
    }

    /// Human-readable display name for the state.
    /// Shows "Loading" for unspecified state (session just created, state not yet known).
    var displayName: String {
        if self == .unspecified {
            return "Loading"
        }
        if self == .completedUnknown {
            return "Completed (Unknown)"
        }
        return rawValue
            .replacingOccurrences(of: "STATE_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Returns true if this state is considered "active" (session is running or waiting for input)
    var isActive: Bool {
        switch self {
        case .queued, .planning, .inProgress, .awaitingPlanApproval, .awaitingUserFeedback:
            return true
        case .unspecified, .paused, .failed, .completed, .completedUnknown:
            return false
        }
    }

    /// Returns true if this state is considered "terminal" (session has ended)
    var isTerminal: Bool {
        switch self {
        case .completed, .completedUnknown, .failed, .paused:
            return true
        case .unspecified, .queued, .planning, .inProgress, .awaitingPlanApproval, .awaitingUserFeedback:
            return false
        }
    }
}

// --- Source Models ---

struct Source: Identifiable, Codable, Hashable, Equatable {
    let name: String // Full resource name "sources/{source}"
    let id: String   // Output only
    let githubRepo: GitHubRepo?

    var displayName: String {
        return name.replacingOccurrences(of: "sources/github/", with: "")
    }
}

struct GitHubRepo: Codable, Hashable, Equatable {
    let owner: String
    let repo: String
    let isPrivate: Bool?
    let defaultBranch: GitHubBranch?
    let branches: [GitHubBranch]?
}

struct GitHubBranch: Codable, Hashable, Equatable {
    let displayName: String
}

// MARK: - GRDB Extensions for Source
extension Source: FetchableRecord, PersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let json = Column("json")
    }

    init(row: Row) throws {
        let jsonData: Data = row[Columns.json]
        self = try JSONDecoder().decode(Source.self, from: jsonData)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        let jsonData = try JSONEncoder().encode(self)
        container[Columns.json] = jsonData
    }
}

// MARK: - Pending Session for Offline Support
/// Represents a session that was created while offline and is waiting to be synced
struct PendingSession: Identifiable, Codable {
    let id: String  // Local UUID
    let sourceName: String  // Full source resource name
    let branchName: String
    let prompt: String
    let createdAt: Date

    init(sourceName: String, branchName: String, prompt: String) {
        self.id = UUID().uuidString
        self.sourceName = sourceName
        self.branchName = branchName
        self.prompt = prompt
        self.createdAt = Date()
    }
}

// MARK: - GRDB Extensions for PendingSession
extension PendingSession: FetchableRecord, PersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
        static let json = Column("json")
    }

    init(row: Row) throws {
        let jsonData: Data = row[Columns.json]
        self = try JSONDecoder().decode(PendingSession.self, from: jsonData)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.createdAt] = createdAt
        let jsonData = try JSONEncoder().encode(self)
        container[Columns.json] = jsonData
    }
}

// --- Cached Diff Model ---
/// A Codable representation of a diff for caching purposes
struct CachedDiff: Codable, Equatable {
    let patch: String
    let language: String?
    let filename: String?
}

// --- Session Models ---

struct Session: Identifiable, Codable, Equatable {
    let name: String // "sessions/{session}"
    let id: String
    let prompt: String
    let sourceContext: SourceContext?
    let title: String?
    let requirePlanApproval: Bool?
    let automationMode: AutomationMode?
    let createTime: String? // Timestamp - optional because create API may not return it
    let updateTime: String? // Timestamp
    var state: SessionState
    let url: String? // Web URL
    let outputs: [SessionOutput]?

    // Client-side only property to store fetched activities
    var activities: [Activity]?

    // Client-side only property to track when activities were last polled
    var lastActivityPollTime: Date?

    // Client-side only property to track when the session was viewed after completion
    var viewedPostCompletionAt: Date?

    // Client-side only property to track when the session was merged locally
    var mergedLocallyAt: Date?

    // Cached computed values - stored to avoid expensive recalculation on every access
    var cachedGitStatsSummary: String?
    var cachedLatestDiffs: [CachedDiff]?

    // Tracks when git stats were last computed (compared against updateTime to detect staleness)
    var cachedGitStatsUpdateTime: String?

    // Flag indicating if diffs are stored in file storage (avoids file system checks)
    var hasCachedDiffsFlag: Bool = false

    /// Returns true if this session has been viewed after completion or is over a day old
    var isViewed: Bool {
        // Explicitly viewed post-completion
        if viewedPostCompletionAt != nil { return true }
        // Treat sessions over a day old as viewed (don't show unviewed indicator)
        if let createTime = createTime,
           let createDate = Date.parseAPIDate(createTime),
           Date().timeIntervalSince(createDate) > 86400 {
            return true
        }
        return false
    }

    /// Returns true if this session is completed (or completedUnknown) but has not been viewed yet
    var isUnviewedCompleted: Bool {
        return (state == .completed || state == .completedUnknown) && !isViewed
    }

    /// Returns true if this session has been merged locally
    var isMergedLocally: Bool {
        return mergedLocallyAt != nil
    }

    /// Returns the cached git stats summary. Use `computeGitStatsSummary()` to calculate it.
    var gitStatsSummary: String? {
        return cachedGitStatsSummary
    }

    /// Returns true if diffs are available for this session WITHOUT triggering any side effects.
    /// Use this for UI conditions to avoid flickering during async loads.
    /// This checks both the DiffStorageManager memory cache and the hasCachedDiffsFlag.
    var hasDiffsAvailable: Bool {
        // Check DiffStorageManager's in-memory cache first (most reliable, persists across Session recreation)
        if DiffStorageManager.shared.hasCachedDiffsInMemory(forSession: id) {
            return true
        }
        // Fall back to the flag stored in the database (set when diffs were saved)
        return hasCachedDiffsFlag
    }

    /// Returns the cached latest diffs as tuples for compatibility.
    /// Uses cache-only access to avoid blocking the main thread.
    /// If diffs aren't in cache, triggers async load and returns nil.
    /// Observe .diffsDidLoad notification to know when diffs become available.
    var latestDiffs: [(patch: String, language: String?, filename: String?)]? {
        // IMPORTANT: Check DiffStorageManager's cache FIRST, before Session's cachedLatestDiffs.
        // This is critical because:
        // 1. DiffStorageManager's NSCache persists across Session object recreations
        // 2. When GRDB ValueObservation fires, new Session objects are created with cachedLatestDiffs = nil
        //    (because we don't store diffs in the JSON to keep it small)
        // 3. Checking DiffStorageManager first ensures we find diffs that are already loaded
        if let memoryCached = DiffStorageManager.shared.getCachedDiffs(forSession: id), !memoryCached.isEmpty {
            return memoryCached.map { (patch: $0.patch, language: $0.language, filename: $0.filename) }
        }

        // Fall back to Session's in-memory cache (useful during same-object lifecycle)
        if let cached = cachedLatestDiffs, !cached.isEmpty {
            return cached.map { (patch: $0.patch, language: $0.language, filename: $0.filename) }
        }

        // Not in any cache - trigger async load if not already loading
        // This avoids blocking the main thread with disk I/O
        if !DiffStorageManager.shared.isLoadingDiffs(forSession: id) {
            DiffStorageManager.shared.preloadDiffs(forSession: id)
        }

        return nil
    }

    // MARK: - Static Computation Methods (call once when activities change)

    /// Computes the git stats summary from activities. Call this when activities are updated.
    static func computeGitStatsSummary(from activities: [Activity]?) -> String? {
        guard let activities = activities else { return nil }

        // Find the last activity from the list that has a git patch.
        // The list is sorted from oldest to newest.
        guard let latestActivityWithPatch = activities.last(where: {
            $0.artifacts?.contains(where: { $0.changeSet?.gitPatch?.unidiffPatch != nil }) ?? false
        }) else {
            return nil
        }

        var totalAdded = 0
        var totalRemoved = 0

        // Get all patches from that single, most recent activity.
        let patches = latestActivityWithPatch.artifacts?.compactMap { $0.changeSet?.gitPatch?.unidiffPatch } ?? []

        for patch in patches {
            let lines = patch.split(separator: "\n")
            for line in lines {
                if line.starts(with: "+") && !line.starts(with: "+++") {
                    totalAdded += 1
                } else if line.starts(with: "-") && !line.starts(with: "---") {
                    totalRemoved += 1
                }
            }
        }

        if totalAdded == 0 && totalRemoved == 0 {
            return nil
        }

        return "+\(totalAdded) -\(totalRemoved)"
    }

    /// Computes the latest diffs from activities. Call this when activities are updated.
    static func computeLatestDiffs(from activities: [Activity]?) -> [CachedDiff]? {
        guard let activities = activities else { return nil }

        guard let latestActivityWithPatch = activities.last(where: {
            $0.artifacts?.contains(where: { $0.changeSet?.gitPatch?.unidiffPatch != nil }) ?? false
        }) else {
            return nil
        }

        guard let artifacts = latestActivityWithPatch.artifacts else { return nil }

        var allDiffs: [CachedDiff] = []

        for artifact in artifacts {
            guard let changeSet = artifact.changeSet,
                  let patch = changeSet.gitPatch?.unidiffPatch else { continue }

            // Split multi-file patches into individual file patches
            let filePatchesFromArtifact = splitPatchByFile(patch)

            for filePatch in filePatchesFromArtifact {
                let effectiveFilename = filePatch.filename ?? changeSet.source
                let language = detectLanguageStatic(from: filePatch.patch) ?? effectiveFilename.flatMap { detectLanguageFromPathStatic($0) }
                allDiffs.append(CachedDiff(patch: filePatch.patch, language: language, filename: effectiveFilename))
            }
        }

        return allDiffs.isEmpty ? nil : allDiffs
    }

    /// Updates the cached values from activities. Call this when activities are set.
    /// Also records the session's updateTime at the time of computation for staleness checks.
    mutating func updateCachedDiffData() {
        cachedGitStatsSummary = Session.computeGitStatsSummary(from: activities)
        cachedLatestDiffs = Session.computeLatestDiffs(from: activities)
        cachedGitStatsUpdateTime = updateTime ?? createTime
    }

    /// Returns true if we have cached git stats available
    var hasCachedGitStats: Bool {
        // Check in-memory cache first, then the persisted flag
        return cachedGitStatsSummary != nil || cachedLatestDiffs != nil || hasCachedDiffsFlag
    }

    /// Returns true if the cached git stats are stale (session was updated since last computation)
    var areCachedGitStatsStale: Bool {
        // If we have no cached update time, stats are stale
        guard let cachedTime = cachedGitStatsUpdateTime else { return true }
        // Compare against session's updateTime (or createTime if no updateTime)
        let currentTime = updateTime ?? createTime
        return cachedTime != currentTime
    }

    /// Returns the time interval since the session was last updated
    /// Uses the createTime from the last activity if available,
    /// otherwise falls back to session's updateTime, then createTime
    var timeSinceLastUpdate: TimeInterval? {
        // Priority order:
        // 1. Last activity's createTime - most accurate if activities are loaded
        // 2. Session's updateTime - reflects last server update if activities not loaded
        // 3. Session's createTime - last resort fallback
        let timeString: String?
        if let lastActivity = activities?.last, let activityTime = lastActivity.createTime {
            timeString = activityTime
        } else {
            // Fall back to updateTime first (more recent than createTime)
            // This is critical for old sessions where activities haven't been fetched
            timeString = updateTime ?? createTime
        }
        guard let timeString = timeString,
              let date = Date.parseAPIDate(timeString) else {
            return nil
        }
        return Date().timeIntervalSince(date)
    }

    /// Returns true if this session is stale (hasn't been updated for over an hour)
    /// Only applies to sessions in active states
    var isStaleActive: Bool {
        guard state.isActive else { return false }
        guard let elapsed = timeSinceLastUpdate else { return false }
        // Consider stale if no updates for over 1 hour (3600 seconds)
        return elapsed > 3600
    }

    /// Returns true if this session needs activity fetching for git stats
    /// - For completed/completedUnknown sessions: only if stats are stale (never computed, or session updated since)
    /// - For in-progress sessions: always (keep polling for updates)
    /// - For other sessions: only if stats are stale (updateTime changed since last computation)
    var needsActivityFetchForStats: Bool {
        switch state {
        case .completed, .completedUnknown:
            // Completed sessions only need stats computed once
            // Check if stats are stale (never computed, or session updated since computation)
            // This properly handles sessions with no git changes (where stats are nil but computed)
            return areCachedGitStatsStale
        case .queued, .planning, .inProgress:
            // Active sessions always need polling
            return true
        default:
            // For other states (awaiting feedback, paused, failed), check staleness
            return areCachedGitStatsStale
        }
    }

    /// Splits a unified diff patch containing multiple files into individual file patches
    private static func splitPatchByFile(_ patch: String) -> [(patch: String, filename: String?)] {
        let lines = patch.components(separatedBy: "\n")
        var results: [(patch: String, filename: String?)] = []
        var currentPatchLines: [String] = []
        var currentFilename: String? = nil

        for line in lines {
            if line.hasPrefix("diff --git ") {
                // Save previous file's patch if exists
                if !currentPatchLines.isEmpty {
                    results.append((patch: currentPatchLines.joined(separator: "\n"), filename: currentFilename))
                }
                // Start new file
                currentPatchLines = [line]
                // Extract filename from "diff --git a/path b/path"
                let parts = line.components(separatedBy: " ")
                if parts.count >= 4 {
                    var path = parts[3]
                    if path.hasPrefix("b/") {
                        path = String(path.dropFirst(2))
                    }
                    currentFilename = path
                }
            } else {
                currentPatchLines.append(line)
            }
        }

        // Don't forget the last file
        if !currentPatchLines.isEmpty {
            results.append((patch: currentPatchLines.joined(separator: "\n"), filename: currentFilename))
        }

        // If no "diff --git" markers were found, return the original patch as-is
        if results.isEmpty && !patch.isEmpty {
            return [(patch: patch, filename: nil)]
        }

        return results
    }

    var latestProgressTitle: String? {
        guard let activities = activities else { return nil }
        return activities.compactMap { $0.progressUpdated?.title }.last
    }

    private static func detectLanguageStatic(from unidiffPatch: String) -> String? {
        guard let newFileHeader = unidiffPatch.split(separator: "\n").first(where: { $0.starts(with: "+++") }) else {
            return nil
        }

        var pathString = String(newFileHeader.dropFirst(4).trimmingCharacters(in: .whitespaces))
        // Remove "b/" prefix if present (common in git diffs)
        if pathString.hasPrefix("b/") {
            pathString = String(pathString.dropFirst(2))
        }

        return languageFromPathStatic(pathString)
    }

    private static func detectLanguageFromPathStatic(_ path: String) -> String? {
        return languageFromPathStatic(path)
    }

    private static func languageFromPathStatic(_ path: String) -> String? {
        // Use CodeLanguage.detectLanguageFrom for comprehensive language detection
        // This handles file extensions, special filenames (Dockerfile, Makefile), and more
        let fileURL = URL(fileURLWithPath: path)
        let language = CodeLanguage.detectLanguageFrom(url: fileURL)

        // Return nil for default/unknown languages to allow fallback behavior
        if language == .default {
            return nil
        }

        // Return the language ID which is used by FluxParser for syntax highlighting
        return language.id.rawValue
    }

    // Helper to conform to Identifiable with stable ID
    // id is already defined

    enum CodingKeys: String, CodingKey {
        case name, id, prompt, sourceContext, title, requirePlanApproval, automationMode, createTime, updateTime, state, url, outputs, activities, lastActivityPollTime, viewedPostCompletionAt, mergedLocallyAt, cachedGitStatsSummary, cachedLatestDiffs, cachedGitStatsUpdateTime, hasCachedDiffsFlag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.id = try container.decode(String.self, forKey: .id)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.sourceContext = try container.decodeIfPresent(SourceContext.self, forKey: .sourceContext)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.requirePlanApproval = try container.decodeIfPresent(Bool.self, forKey: .requirePlanApproval)
        self.automationMode = try container.decodeIfPresent(AutomationMode.self, forKey: .automationMode)
        self.createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        self.updateTime = try container.decodeIfPresent(String.self, forKey: .updateTime)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.outputs = try container.decodeIfPresent([SessionOutput].self, forKey: .outputs)
        self.state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .unspecified
        self.activities = try container.decodeIfPresent([Activity].self, forKey: .activities)
        self.lastActivityPollTime = try container.decodeIfPresent(Date.self, forKey: .lastActivityPollTime)
        self.viewedPostCompletionAt = try container.decodeIfPresent(Date.self, forKey: .viewedPostCompletionAt)
        self.mergedLocallyAt = try container.decodeIfPresent(Date.self, forKey: .mergedLocallyAt)
        self.cachedGitStatsSummary = try container.decodeIfPresent(String.self, forKey: .cachedGitStatsSummary)
        self.cachedLatestDiffs = try container.decodeIfPresent([CachedDiff].self, forKey: .cachedLatestDiffs)
        self.cachedGitStatsUpdateTime = try container.decodeIfPresent(String.self, forKey: .cachedGitStatsUpdateTime)
        self.hasCachedDiffsFlag = try container.decodeIfPresent(Bool.self, forKey: .hasCachedDiffsFlag) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(id, forKey: .id)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(sourceContext, forKey: .sourceContext)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(requirePlanApproval, forKey: .requirePlanApproval)
        try container.encodeIfPresent(automationMode, forKey: .automationMode)
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(updateTime, forKey: .updateTime)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(outputs, forKey: .outputs)
        // NOTE: Activities should already be stripped before being assigned to the session.
        // DataManager.fetchActivities() and related methods strip heavy data (media, patches, large bash output)
        // before assigning to session.activities. We encode directly without re-stripping to avoid
        // creating unnecessary copies of the activities array, which was causing ~11MB memory amplification.
        // Diffs are stored separately in DiffStorageManager, not in the session JSON.
        try container.encodeIfPresent(activities, forKey: .activities)
        try container.encodeIfPresent(lastActivityPollTime, forKey: .lastActivityPollTime)
        try container.encodeIfPresent(viewedPostCompletionAt, forKey: .viewedPostCompletionAt)
        try container.encodeIfPresent(mergedLocallyAt, forKey: .mergedLocallyAt)
        try container.encodeIfPresent(cachedGitStatsSummary, forKey: .cachedGitStatsSummary)
        // NOTE: cachedLatestDiffs is intentionally NOT encoded to JSON.
        // Diffs are stored separately in DiffStorageManager to avoid duplicating
        // large patch data (~20-50MB per session) in the session JSON blob.
        // Use hasCachedDiffsFlag and the latestDiffs property instead.
        try container.encodeIfPresent(cachedGitStatsUpdateTime, forKey: .cachedGitStatsUpdateTime)
        try container.encode(hasCachedDiffsFlag, forKey: .hasCachedDiffsFlag)
    }

    // Memberwise initializer for use in previews or manual creation.
    init(name: String, id: String, prompt: String, sourceContext: SourceContext?, title: String?, requirePlanApproval: Bool?, automationMode: AutomationMode?, createTime: String? = nil, updateTime: String?, state: SessionState, url: String?, outputs: [SessionOutput]?, activities: [Activity]? = nil, lastActivityPollTime: Date? = nil, viewedPostCompletionAt: Date? = nil, mergedLocallyAt: Date? = nil, cachedGitStatsSummary: String? = nil, cachedLatestDiffs: [CachedDiff]? = nil, cachedGitStatsUpdateTime: String? = nil, hasCachedDiffsFlag: Bool = false) {
        self.name = name
        self.id = id
        self.prompt = prompt
        self.sourceContext = sourceContext
        self.title = title
        self.requirePlanApproval = requirePlanApproval
        self.automationMode = automationMode
        self.createTime = createTime
        self.updateTime = updateTime
        self.state = state
        self.url = url
        self.outputs = outputs
        self.activities = activities
        self.lastActivityPollTime = lastActivityPollTime
        self.viewedPostCompletionAt = viewedPostCompletionAt
        self.mergedLocallyAt = mergedLocallyAt
        self.cachedGitStatsSummary = cachedGitStatsSummary
        self.cachedLatestDiffs = cachedLatestDiffs
        self.cachedGitStatsUpdateTime = cachedGitStatsUpdateTime
        self.hasCachedDiffsFlag = hasCachedDiffsFlag
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        return lhs.id == rhs.id &&
        lhs.updateTime == rhs.updateTime &&
        lhs.state == rhs.state &&
        lhs.activities == rhs.activities
    }
}

// MARK: - GRDB Extensions
extension Session: FetchableRecord, PersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let updateTime = Column(CodingKeys.updateTime)
        static let createTime = Column(CodingKeys.createTime)
        static let state = Column("state")
        static let lastActivityPollTime = Column(CodingKeys.lastActivityPollTime)
        static let hasCachedDiffs = Column("hasCachedDiffs")
        static let json = Column("json")
    }

    init(row: Row) throws {
        // Decode the JSON blob
        let jsonData: Data = row[Columns.json]
        self = try JSONDecoder().decode(Session.self, from: jsonData)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        // Use updateTime, fall back to createTime, or use current time if both are nil
        // This handles sessions just created where the API hasn't populated timestamps yet
        let fallbackTime = ISO8601DateFormatter().string(from: Date())
        container[Columns.updateTime] = updateTime ?? createTime ?? fallbackTime
        container[Columns.createTime] = createTime ?? fallbackTime
        container[Columns.state] = state.rawValue // Store state for indexed queries
        container[Columns.lastActivityPollTime] = lastActivityPollTime // Store for indexed queries
        container[Columns.hasCachedDiffs] = hasCachedDiffsFlag // Store for fast lookup

        // Create a copy without cachedLatestDiffs to avoid storing large patches in JSON
        // Diffs are stored separately in compressed file storage
        var sessionForJson = self
        sessionForJson.cachedLatestDiffs = nil
        let jsonData = try JSONEncoder().encode(sessionForJson)
        container[Columns.json] = jsonData
    }

    /// Save session with its cached diffs
    /// Session is saved to database, diffs are saved to compressed files
    /// IMPORTANT: Diffs are saved to file BEFORE database to avoid race condition
    /// where ValueObservation triggers before file exists
    /// MEMORY: After saving, cachedLatestDiffs is cleared from the in-memory Session
    /// since DiffStorageManager is now the source of truth. This prevents duplicate
    /// storage of diffs in both the Session object and DiffStorageManager's NSCache.
    mutating func saveWithDiffs(_ db: Database) throws {
        // DEBUG: Verify activities are stripped before saving.
        // This catches bugs where unstripped activities (with media, large patches, large bash output)
        // are accidentally saved, which would bloat the database.
        #if DEBUG
        if let activities = activities {
            for activity in activities {
                for artifact in activity.artifacts ?? [] {
                    // Media should be stripped (nil)
                    assert(artifact.media == nil,
                           "🚨 Unstripped activity detected: media data should be nil before saving session \(id)")
                    // Large unidiffPatch should be stripped (stored separately in DiffStorageManager)
                    if let patch = artifact.changeSet?.gitPatch?.unidiffPatch, patch.count > 1000 {
                        assertionFailure("🚨 Unstripped activity detected: unidiffPatch (\(patch.count) chars) should be nil before saving session \(id)")
                    }
                    // Large bash output should be truncated
                    if let output = artifact.bashOutput?.output, output.count > 15000 {
                        assertionFailure("🚨 Unstripped activity detected: bash output (\(output.count) chars) should be truncated before saving session \(id)")
                    }
                }
            }
        }
        #endif

        // Set flag if we have diffs to save (so hasCachedGitStats can avoid file system checks)
        if let diffs = cachedLatestDiffs, !diffs.isEmpty {
            hasCachedDiffsFlag = true
            // Save diffs to file-based storage FIRST (before DB save)
            // This ensures the file exists when ValueObservation triggers and
            // the latestDiffs computed property tries to lazy-load from file
            try DiffStorageManager.shared.saveDiffs(diffs, forSession: id)

            // MEMORY FIX: Clear cachedLatestDiffs after saving to DiffStorageManager.
            // The diffs are now stored in DiffStorageManager's NSCache and database,
            // so keeping them here would duplicate memory usage. The latestDiffs
            // computed property will load from DiffStorageManager when needed.
            cachedLatestDiffs = nil
        } else {
            // Sync the flag with actual storage state.
            // This handles the case where:
            // 1. Activities are fetched but don't contain git patches (older sessions)
            // 2. computeLatestDiffs() returns nil
            // 3. But diffs were previously saved and still exist in DiffDatabase
            // By checking storage, we ensure the flag accurately reflects reality
            // and also recover from any previous flag/storage inconsistencies.
            hasCachedDiffsFlag = DiffStorageManager.shared.hasDiffs(forSession: id)
        }

        try save(db)
    }

    /// Load cached diffs from file storage
    static func loadCachedDiffs(for sessionId: String) -> [CachedDiff]? {
        return DiffStorageManager.shared.loadDiffs(forSession: sessionId)
    }

    /// Delete cached diffs for a session
    static func deleteCachedDiffs(for sessionId: String) {
        DiffStorageManager.shared.deleteDiffs(forSession: sessionId)
    }

    /// Fetch session with its cached diffs
    static func fetchOneWithDiffs(_ db: Database, key: String) throws -> Session? {
        guard var session = try Session.fetchOne(db, key: key) else { return nil }
        session.cachedLatestDiffs = loadCachedDiffs(for: key)
        return session
    }
}

struct SourceContext: Codable, Equatable {
    let source: String // "sources/{source}"
    let githubRepoContext: GitHubRepoContext?
}

struct GitHubRepoContext: Codable, Equatable {
    let startingBranch: String?
}

enum AutomationMode: String, Codable, Equatable {
    case unspecified = "AUTOMATION_MODE_UNSPECIFIED"
    case autoCreatePr = "AUTO_CREATE_PR"
}

struct SessionOutput: Codable, Equatable {
    let pullRequest: PullRequest?
}

struct PullRequest: Codable, Equatable {
    let url: String
    let title: String
    let description: String
}

// --- Activity Models ---

struct Activity: Identifiable, Codable, Equatable {
    let name: String // "sessions/{session}/activities/{activity}"
    let id: String
    let title: String?
    let description: String?
    let createTime: String?
    let originator: String // "user", "agent", "system"
    var artifacts: [Artifact]?

    // Union fields
    let agentMessaged: AgentMessaged?
    let userMessaged: UserMessaged?
    let planGenerated: PlanGenerated?
    let planApproved: PlanApproved?
    let progressUpdated: ProgressUpdated?
    let sessionCompleted: SessionCompleted?
    let sessionFailed: SessionFailed?

    // Client-side properties for Gemini-generated content
    // NOTE: These are excluded from Equatable to prevent unnecessary UI redraws
    // when Gemini processes activity descriptions asynchronously
    var generatedDescription: String?
    var generatedTitle: String?

    // Custom Equatable implementation that excludes generatedDescription and generatedTitle
    // This prevents diff view redraws when only these client-side fields change
    static func == (lhs: Activity, rhs: Activity) -> Bool {
        return lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.title == rhs.title &&
            lhs.description == rhs.description &&
            lhs.createTime == rhs.createTime &&
            lhs.originator == rhs.originator &&
            lhs.artifacts == rhs.artifacts &&
            lhs.agentMessaged == rhs.agentMessaged &&
            lhs.userMessaged == rhs.userMessaged &&
            lhs.planGenerated == rhs.planGenerated &&
            lhs.planApproved == rhs.planApproved &&
            lhs.progressUpdated == rhs.progressUpdated &&
            lhs.sessionCompleted == rhs.sessionCompleted &&
            lhs.sessionFailed == rhs.sessionFailed
    }

    /// Returns a copy of this activity with heavy data stripped for storage.
    /// Removes:
    /// - unidiffPatch from gitPatch (stored separately in DiffDatabase)
    /// - media data (base64 images can be 1-5MB each, re-fetched on demand)
    /// - large bash outputs (truncated to prevent memory bloat)
    /// Preserves Gemini content (generatedDescription, generatedTitle) and other metadata.
    func strippedForStorage() -> Activity {
        var copy = self
        copy.artifacts = artifacts?.map { artifact in
            // Strip unidiffPatch if present
            var strippedChangeSet = artifact.changeSet
            if let changeSet = artifact.changeSet,
               let gitPatch = changeSet.gitPatch,
               gitPatch.unidiffPatch != nil {
                let strippedGitPatch = GitPatch(
                    unidiffPatch: nil,
                    baseCommitId: gitPatch.baseCommitId,
                    suggestedCommitMessage: gitPatch.suggestedCommitMessage
                )
                strippedChangeSet = ChangeSet(source: changeSet.source, gitPatch: strippedGitPatch)
            }

            // Strip media data entirely - base64 images are huge and can be re-fetched
            // A single screenshot can be 1-5MB, causing 200MB+ spikes with multiple sessions
            let strippedMedia: Media? = nil

            // Truncate large bash outputs to prevent memory bloat
            // Keep command and exit code, but limit output size
            var strippedBashOutput = artifact.bashOutput
            if let bash = artifact.bashOutput, let output = bash.output, output.count > 10000 {
                // Truncate to ~10KB with indicator
                let truncated = String(output.prefix(10000)) + "\n... [truncated for storage]"
                strippedBashOutput = BashOutput(command: bash.command, output: truncated, exitCode: bash.exitCode)
            }

            return Artifact(changeSet: strippedChangeSet, media: strippedMedia, bashOutput: strippedBashOutput)
        }
        return copy
    }
}

struct Artifact: Codable, Equatable {
    let changeSet: ChangeSet?
    let media: Media?
    let bashOutput: BashOutput?
}

struct ChangeSet: Codable, Equatable {
    let source: String?
    let gitPatch: GitPatch?
}

struct GitPatch: Codable, Equatable {
    let unidiffPatch: String?
    let baseCommitId: String?
    let suggestedCommitMessage: String?
}

struct Media: Codable, Equatable {
    let data: String // Base64
    let mimeType: String
}

struct BashOutput: Codable, Equatable {
    let command: String?
    let output: String?
    let exitCode: Int?
}

struct AgentMessaged: Codable, Equatable {
    let agentMessage: String
}

struct UserMessaged: Codable, Equatable {
    let userMessage: String
}

struct PlanGenerated: Codable, Equatable {
    let plan: Plan
}

struct Plan: Codable, Equatable {
    let id: String
    let steps: [PlanStep]
    let createTime: String?
}

struct PlanStep: Codable, Equatable {
    let id: String
    let title: String?
    let description: String?
    let index: Int?
}

struct PlanApproved: Codable, Equatable {
    let planId: String
}

struct ProgressUpdated: Codable, Equatable {
    let title: String?
    let description: String?
}

struct SessionCompleted: Codable, Equatable {} // Empty object

struct SessionFailed: Codable, Equatable {
    let reason: String?
}


// --- App Notification (Keep for now if still needed, or update if API has changed) ---
struct AppNotification: Decodable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let title: String
    let subtitle: String?
    let body: String
    let timestamp: Date
    let relatedUrl: String?
    let viewedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, body, timestamp
        case relatedUrl = "related_url"
        case viewedAt = "viewed_at"
        case sessionId
    }
}
