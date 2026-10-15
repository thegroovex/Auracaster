import SwiftUI

/// Edge-to-edge sidebar (Golden Gate) with colored SF Symbols.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: $selection) {
            Section("Quellen") {
                row(.systemAudio)
                row(.apps, badge: model.sources.filter { $0.category == .apps }.count)
                row(.inputs, badge: model.sources.filter { $0.category == .inputs }.count)
            }
            Section("Broadcast") {
                row(.broadcasts)
                row(.routing)
                row(.receivers, badge: model.receivers.count)
            }
            Section {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(item.tint)
        }
        .badge(badge)
        .tag(item)
    }
}
