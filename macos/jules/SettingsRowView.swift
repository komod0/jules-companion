import SwiftUI

/// A reusable settings row component with icon, label, and accessory view
struct SettingsRowView<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let accessory: () -> Accessory

    init(
        icon: String,
        iconColor: Color = AppColors.textSecondary,
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.backgroundSecondary)
    }
}

/// A settings row with a toggle switch
struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var isOn: Bool

    init(
        icon: String,
        iconColor: Color = AppColors.textSecondary,
        title: String,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        SettingsRowView(icon: icon, iconColor: iconColor, title: title) {
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: AppColors.accent))
                .labelsHidden()
        }
    }
}

/// A settings row with a dropdown picker
struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var selection: SelectionValue
    let content: () -> Content

    init(
        icon: String,
        iconColor: Color = AppColors.textSecondary,
        title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self._selection = selection
        self.content = content
    }

    var body: some View {
        SettingsRowView(icon: icon, iconColor: iconColor, title: title) {
            Picker("", selection: $selection) {
                content()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AppColors.textSecondary)
        }
    }
}

/// A settings row with navigation chevron
struct SettingsNavigationRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String?
    let action: () -> Void

    init(
        icon: String,
        iconColor: Color = AppColors.textSecondary,
        title: String,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowView(icon: icon, iconColor: iconColor, title: title) {
                HStack(spacing: 4) {
                    if let value = value {
                        Text(value)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.textSecondary.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A settings row with a stepper for numeric values
struct SettingsStepperRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let formatter: (CGFloat) -> String

    init(
        icon: String,
        iconColor: Color = AppColors.textSecondary,
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        formatter: @escaping (CGFloat) -> String = { "\(Int($0))" }
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.formatter = formatter
    }

    var body: some View {
        SettingsRowView(icon: icon, iconColor: iconColor, title: title) {
            HStack(spacing: 8) {
                Button(action: {
                    if value > range.lowerBound {
                        value = max(value - step, range.lowerBound)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(value > range.lowerBound ? AppColors.textSecondary : AppColors.textSecondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Text(formatter(value))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(minWidth: 30)

                Button(action: {
                    if value < range.upperBound {
                        value = min(value + step, range.upperBound)
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(value < range.upperBound ? AppColors.textSecondary : AppColors.textSecondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }
        }
    }
}

/// Section header for settings
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}

/// Container for grouping settings rows with rounded corners
struct SettingsSectionContainer<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: 1) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}
