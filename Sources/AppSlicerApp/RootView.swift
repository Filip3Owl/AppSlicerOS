import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case apps
    case forecast
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("nav.overview")
        case .apps: L("nav.apps")
        case .forecast: L("nav.forecast")
        case .settings: L("nav.settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .apps: "square.grid.2x2"
        case .forecast: "chart.line.uptrend.xyaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .safeAreaInset(edge: .top) {
                LogoView(width: 150)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                Group {
                    switch selection ?? .overview {
                    case .overview: OverviewView()
                    case .apps: AppsView()
                    case .forecast: ForecastView()
                    case .settings: SettingsView()
                    }
                }
                .padding(40)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear(perform: model.surfaceAppeared)
        .onDisappear(perform: model.surfaceDisappeared)
    }
}
