import Foundation

extension Date {
    /// Returns true if the date is today
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    /// Returns true if the date is within this week (but not today)
    var isThisWeekButNotToday: Bool {
        guard !isToday else { return false }
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return false
        }
        return self >= weekStart && self < Date()
    }

    /// Returns true if the date is before this week
    var isBeforeThisWeek: Bool {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return false
        }
        return self < weekStart
    }

    func timeAgoDisplay() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: self, to: Date())

        if let years = components.year, years > 0 {
            return "\(years)y"
        }
        if let months = components.month, months > 0 {
            return "\(months)mo"
        }
        if let days = components.day, days > 0 {
            return "\(days)d"
        }
        if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        }
        if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        }
        if let seconds = components.second, seconds > 0 {
            return "\(seconds)s"
        }
        return "now"
    }

    /// Formats the date for activity timestamps.
    /// - If today: "Today 12:30 PM"
    /// - If this week (but not today): "Tue 12:30 PM"
    /// - Otherwise: "Sun Jan 4 12:30 PM"
    func activityTimestampDisplay() -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeString = timeFormatter.string(from: self)

        if isToday {
            return "Today \(timeString)"
        } else if isThisWeekButNotToday {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"
            let dayString = dayFormatter.string(from: self)
            return "\(dayString) \(timeString)"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEE MMM d"
            let dateString = dateFormatter.string(from: self)
            return "\(dateString) \(timeString)"
        }
    }

    /// Parses a date string from the Jules API, handling variable fractional second precision.
    static func parseAPIDate(_ string: String) -> Date? {
        return JulesDateParser.parse(string)
    }
}

// Private helper to hold formatters
private struct JulesDateParser {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    static let noFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    static func parse(_ string: String) -> Date? {
        // Try with fractional seconds first (most common for modern APIs)
        if let date = withFractional.date(from: string) { return date }
        // Fallback to no fractional seconds
        return noFractional.date(from: string)
    }
}
