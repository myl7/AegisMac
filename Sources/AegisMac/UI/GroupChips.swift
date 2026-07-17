import SwiftUI

// MARK: - Group filter chip row (ui-style spec §6.2)

/// A horizontally scrolling row of Material-style filter chips. Hidden when the vault has no
/// groups. Includes the placeholder chips "All" (clears the filter) and "No group" (ungrouped),
/// plus one chip per group. Single-select by default; multi-select when the pref is enabled.
struct GroupChips: View {
    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette

    private var multiselect: Bool { app.prefs.groupsMultiselect }

    var body: some View {
        if !app.allGroups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "All", selected: !app.hasActiveGroupFilter) {
                        app.clearGroupFilter()
                    }
                    chip(title: "No group", selected: app.filterIncludesUngrouped) {
                        app.selectGroupFilter(uuid: nil, multiselect: multiselect)
                    }
                    ForEach(app.allGroups, id: \.uuid) { group in
                        chip(title: group.name, selected: app.groupFilter.contains(group.uuid)) {
                            app.selectGroupFilter(uuid: group.uuid, multiselect: multiselect)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                }
                Text(title).font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? palette.primaryColor.opacity(0.22) : palette.surfaceContainerColor)
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : palette.outlineColor.opacity(0.5), lineWidth: 1)
            )
            .foregroundColor(palette.onSurfaceColor)
        }
        .buttonStyle(.plain)
    }
}
