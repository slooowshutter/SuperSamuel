import SwiftUI

/// The left pane of the native split view. AppKit draws it as the floating Liquid Glass
/// sidebar on macOS 26.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        List(SettingsSection.allCases, selection: $model.selection) { section in
            Label(section.title, systemImage: section.symbol)
        }
    }
}

/// The right pane, without cards: each label sits on top of its control, and every line
/// starts at the same left edge.
struct SettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let section = model.selection ?? .keys
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(section.summary(model))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSectionFields(section: section, model: model)
                }
                .labeledContentStyle(LabelOnTopStyle())
                .toggleStyle(.switch)
                Divider().padding(.vertical, 4)
                Text(SettingsSection.saveNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LabelOnTopStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label.font(.headline)
            configuration.content
        }
    }
}
