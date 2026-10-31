import AppKit
import AppSlicerMetrics
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: L("nav.apps"), detail: L("apps.detail"))
            if model.apps.isEmpty {
                LoadingOrFailure(failed: false)
            } else {
                Card(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(model.apps, id: \.name) { app in
                            AppRow(app: app, largest: model.apps.first?.footprintBytes ?? 1)
                        }
                    }
                }
            }
            if model.unreadableProcessCount > 0 {
                Text(L("apps.unreadable", model.unreadableProcessCount))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppRow: View {
    let app: AppMemory
    let largest: UInt64

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if app.processCount > 1 {
                    Text(L("apps.processes", app.processCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView(value: Double(app.footprintBytes), total: Double(max(largest, 1)))
                .tint(.primary)
                .frame(width: 180)
                .accessibilityHidden(true)

            Text(Formatting.gigabytes(app.footprintBytes))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

struct ForecastView: View {
    @EnvironmentObject private var model: DashboardModel

    private var content: (title: String, detail: String) {
        switch model.forecast {
        case .unavailable:
            (L("forecast.unavailable.title"), L("forecast.unavailable.detail"))
        case .learning:
            (L("forecast.learning.title"), L("forecast.learning.detail"))
        case .ready(let probability):
            (
                L(probability >= HealthStatus.attentionProbability ? "forecast.high.title" : "forecast.low.title"),
                L("forecast.ready.detail", Formatting.percent(probability))
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: L("nav.forecast"), detail: L("forecast.page.detail"))
            Card(padding: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(content.title).font(.system(size: 20, weight: .semibold))
                    Text(content.detail)
                }
            }
            if case .learning(let elevated, let calm, let required) = model.forecast {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("forecast.progress.title")).font(.system(size: 16, weight: .semibold))
                            Text(L("forecast.progress.detail")).foregroundStyle(.secondary)
                        }
                        ExampleProgress(label: L("forecast.progress.calm"), count: calm, required: required)
                        ExampleProgress(label: L("forecast.progress.elevated"), count: elevated, required: required)
                    }
                }
            }
        }
    }
}

private struct ExampleProgress: View {
    let label: String
    let count: Int
    let required: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(L("forecast.progress.count", min(count, required), required))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(min(count, required)), total: Double(max(required, 1)))
                .tint(.primary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: DashboardModel

    private var collectionText: String {
        switch model.collection {
        case .active: L("collection.active")
        case .stopped: L("collection.stopped")
        case .neverStarted: L("collection.never")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: L("nav.settings"), detail: nil)
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.collection.title")).font(.system(size: 16, weight: .semibold))
                    Text(collectionText).foregroundStyle(.secondary)
                }
            }
            Card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.privacy.title")).font(.system(size: 16, weight: .semibold))
                        Text(L("settings.privacy.detail")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let folder = model.dataFolder {
                        Button(L("settings.privacy.show")) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LogoView(width: 120)
            if let snapshot = model.snapshot, let status = model.status {
                StatusHeader(status: status, titleSize: 24, detailSize: 13)
                HStack(spacing: 8) {
                    StatTile(
                        label: L("tile.memory"),
                        value: Formatting.gigabytes(snapshot.usedBytes),
                        detail: L("tile.memory.of", Formatting.gigabytes(snapshot.counters.physicalMemoryBytes)),
                        valueSize: 20
                    )
                    StatTile(
                        label: L("tile.swap"),
                        value: Formatting.gigabytes(snapshot.counters.swapUsedBytes),
                        detail: L(model.isSwapGrowing ? "tile.swap.growing" : "tile.swap.steady"),
                        valueSize: 20
                    )
                }
            } else {
                LoadingOrFailure(failed: model.loadFailed)
            }
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text(L("menu.open")).frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L("menu.quit")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: model.surfaceAppeared)
        .onDisappear(perform: model.surfaceDisappeared)
    }
}
