import SwiftUI

/// Unified toolbar: dongle status, latency pill, prominent On-Air button.
/// Toolbar items get the system Liquid Glass automatically – no custom
/// backgrounds here.
struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DongleStatusView(status: model.dongleStatus)
        }

        ToolbarItem(placement: .principal) {
            LatencyPill(milliseconds: model.latencyMilliseconds, isLive: model.isLive, style: .plain)
        }

        ToolbarItem(placement: .primaryAction) {
            UpdateBadgeButton()
        }

        ToolbarItem(placement: .primaryAction) {
            OnAirButton()
        }
    }
}
