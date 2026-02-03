import SwiftUI

struct SplitButton<Action, Icon>: View
    where Action: Identifiable & Equatable & Hashable,
          Icon: View
{
    let actions: [Action]
    @Binding var selectedAction: Action
    let onTrigger: (Action) -> Void
    let label: (Action) -> String
    let icon: (Action) -> Icon
    let isEnabled: (Action) -> Bool

    @State private var isDropdownOpen = false
    @State private var isPrimaryHovering = false
    @State private var isChevronHovering = false

    @Environment(\.colorScheme) private var colorScheme

    private var buttonHeight: CGFloat {
        if #available(macOS 26.0, *) {
            return colorScheme == .dark ? 32 : 38
        } else {
            return 30
        }
    }

    init(
        actions: [Action],
        selectedAction: Binding<Action>,
        onTrigger: @escaping (Action) -> Void,
        label: @escaping (Action) -> String,
        @ViewBuilder icon: @escaping (Action) -> Icon,
        isEnabled: @escaping (Action) -> Bool
    ) {
        self.actions = actions
        self._selectedAction = selectedAction
        self.onTrigger = onTrigger
        self.label = label
        self.icon = icon
        self.isEnabled = isEnabled
    }

    var body: some View {
        HStack(spacing: 0) {
            // Primary Action Button
            Button(action: {
                onTrigger(selectedAction)
            }) {
                HStack(spacing: 6) {
                    icon(selectedAction)
                    Text(label(selectedAction))
                        .fontWeight(.bold)
                }
                .foregroundColor(AppColors.buttonText)
                .opacity(isEnabled(selectedAction) ? (isPrimaryHovering ? 1.0 : 0.8) : 0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .disabled(!isEnabled(selectedAction))
            .buttonStyle(.plain)
            .onHover { hovering in
                isPrimaryHovering = hovering
            }

            // Separator
            Rectangle()
                .fill(.gray.opacity(0.4))
                .frame(width: 1)
                .padding(.vertical, 6)

            // Dropdown Button
            Button(action: {
                isDropdownOpen.toggle()
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppColors.textSecondary)
                    .opacity(isChevronHovering ? 1.0 : 0.8)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isChevronHovering = hovering
            }
            .popover(isPresented: $isDropdownOpen, arrowEdge: .bottom) {
                SplitButtonDropdownMenu(
                    actions: actions,
                    selectedAction: $selectedAction,
                    label: label,
                    icon: icon,
                    isDropdownOpen: $isDropdownOpen
                )
            }
        }
        .background(AppColors.buttonBackground)
        .clipShape(Capsule())
        .frame(height: buttonHeight)
    }
}

/// Custom dropdown menu view for SplitButton
struct SplitButtonDropdownMenu<Action, Icon>: View
    where Action: Identifiable & Equatable & Hashable,
          Icon: View
{
    let actions: [Action]
    @Binding var selectedAction: Action
    let label: (Action) -> String
    let icon: (Action) -> Icon
    @Binding var isDropdownOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(actions) { action in
                DropdownMenuItem(
                    action: action,
                    selectedAction: $selectedAction,
                    label: label,
                    icon: icon,
                    isDropdownOpen: $isDropdownOpen,
                    isLast: action.id == actions.last?.id
                )
            }
        }
        .frame(minWidth: 180)
        .background(.thinMaterial)
        .cornerRadius(10)
    }
}

/// Individual dropdown menu item with hover state
struct DropdownMenuItem<Action, Icon>: View
    where Action: Identifiable & Equatable & Hashable,
          Icon: View
{
    let action: Action
    @Binding var selectedAction: Action
    let label: (Action) -> String
    let icon: (Action) -> Icon
    @Binding var isDropdownOpen: Bool
    let isLast: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                selectedAction = action
                isDropdownOpen = false
            }) {
                HStack(spacing: 10) {
                    icon(action)
                        .frame(width: 20, height: 20)
                    Text(label(action))
                        .font(.system(size: 13))
                    Spacer()
                }
                .foregroundColor(AppColors.textPrimary)
                .opacity(isHovering ? 1.0 : 0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                selectedAction == action
                    ? AppColors.accent.opacity(0.2)
                    : Color.clear
            )
            .onHover { hovering in
                isHovering = hovering
            }

            if !isLast {
                Divider()
                    .background(AppColors.separator)
            }
        }
    }
}

extension SplitButton where Icon == EmptyView {
    init(
        actions: [Action],
        selectedAction: Binding<Action>,
        onTrigger: @escaping (Action) -> Void,
        label: @escaping (Action) -> String,
        isEnabled: @escaping (Action) -> Bool
    ) {
        self.init(
            actions: actions,
            selectedAction: selectedAction,
            onTrigger: onTrigger,
            label: label,
            icon: { _ in EmptyView() },
            isEnabled: isEnabled
        )
    }
}
