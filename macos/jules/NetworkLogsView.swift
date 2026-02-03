import SwiftUI

/// A view that displays network logs for debugging purposes
struct NetworkLogsView: View {
    @StateObject private var networkLogger = NetworkLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLog: NetworkLogger.LogEntry?
    @State private var filterText: String = ""

    private var filteredLogs: [NetworkLogger.LogEntry] {
        if filterText.isEmpty {
            return networkLogger.recentLogs.reversed()
        }
        return networkLogger.recentLogs.reversed().filter { log in
            log.url.localizedCaseInsensitiveContains(filterText) ||
            log.method.localizedCaseInsensitiveContains(filterText) ||
            (log.error?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Network Logs")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .background(AppColors.backgroundSecondary)

            // Filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.textSecondary)
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button(action: { filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(AppColors.background)

            Divider()

            // Logs List
            if filteredLogs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 48))
                        .foregroundColor(AppColors.textSecondary.opacity(0.5))

                    Text(networkLogger.recentLogs.isEmpty ? "No network logs yet" : "No matching logs")
                        .font(.headline)
                        .foregroundColor(AppColors.textSecondary)

                    if !networkLogger.isEnabled {
                        Text("Enable network logging in Settings to capture API requests")
                            .font(.subheadline)
                            .foregroundColor(AppColors.textSecondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.background)
            } else {
                List(filteredLogs) { log in
                    LogEntryRow(log: log, isSelected: selectedLog?.id == log.id)
                        .onTapGesture {
                            if selectedLog?.id == log.id {
                                selectedLog = nil
                            } else {
                                selectedLog = log
                            }
                        }
                }
                .listStyle(.plain)
            }

            // Stats Footer
            HStack {
                Text("\(filteredLogs.count) of \(networkLogger.recentLogs.count) logs")
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)

                Spacer()

                Button(action: {
                    let logs = networkLogger.exportLogs()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs, forType: .string)
                }) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(AppColors.accent)

                Button(action: {
                    networkLogger.clearLogs()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(AppColors.backgroundSecondary)
        }
        .frame(width: 600, height: 500)
    }
}

struct LogEntryRow: View {
    let log: NetworkLogger.LogEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Summary row
            HStack(spacing: 8) {
                // Type indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                // Timestamp
                Text(log.formattedTimestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(AppColors.textSecondary)

                // Method
                Text(log.method)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(methodColor)

                // URL (shortened)
                Text(shortenedURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Status code or duration
                if let statusCode = log.statusCode {
                    Text("\(statusCode)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(statusCodeColor(statusCode))
                }

                if let duration = log.duration {
                    Text(String(format: "%.0fms", duration * 1000))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(AppColors.textSecondary)
                }
            }

            // Expanded details
            if isSelected {
                VStack(alignment: .leading, spacing: 4) {
                    // Full URL
                    Text("URL: \(log.url)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(AppColors.textSecondary)
                        .textSelection(.enabled)

                    if let error = log.error {
                        Text("Error: \(error)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.red)
                    }

                    if let requestBody = log.requestBody {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Request Body:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                            Text(requestBody)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(AppColors.textSecondary)
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(4)
                    }

                    if let responseBody = log.responseBody {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Response Body:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(responseBody)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(AppColors.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(4)
                        .frame(maxHeight: 150)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch log.type {
        case .request:
            return .blue
        case .response:
            if let statusCode = log.statusCode, (200...299).contains(statusCode) {
                return .green
            }
            return .orange
        case .error:
            return .red
        }
    }

    private var methodColor: Color {
        switch log.method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        default: return AppColors.textPrimary
        }
    }

    private var shortenedURL: String {
        log.url
            .replacingOccurrences(of: "https://jules.googleapis.com/v1alpha", with: "")
            .components(separatedBy: "?").first ?? log.url
    }

    private func statusCodeColor(_ code: Int) -> Color {
        switch code {
        case 200...299: return .green
        case 300...399: return .blue
        case 400...499: return .orange
        case 500...599: return .red
        default: return AppColors.textSecondary
        }
    }
}
