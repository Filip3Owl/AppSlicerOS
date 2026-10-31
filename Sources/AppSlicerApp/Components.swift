import AppKit
import SwiftUI

extension HealthStatus {
    var label: String {
        switch self {
        case .calm: L("status.calm.label")
        case .learning: L("status.learning.label")
        case .elevatedSoon, .elevatedNow: L("status.attention.label")
        }
    }

    var title: String {
        switch self {
        case .calm, .learning: L("status.calm.title")
        case .elevatedSoon: L("status.soon.title")
        case .elevatedNow: L("status.now.title")
        }
    }

    var detail: String {
        switch self {
        case .calm: L("status.calm.detail")
        case .learning: L("status.learning.detail")
        case .elevatedSoon: L("status.soon.detail")
        case .elevatedNow: L("status.now.detail")
        }
    }

    var dotColor: Color {
        needsAttention ? .orange : .secondary
    }
}

struct StatusHeader: View {
    let status: HealthStatus
    var titleSize: CGFloat = 48
    var detailSize: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: titleSize / 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(status.title)
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-titleSize * 0.025)
                .fixedSize(horizontal: false, vertical: true)
            Text(status.detail)
                .font(.system(size: detailSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Card<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let detail: String
    var valueSize: CGFloat = 32

    var body: some View {
        Card(cornerRadius: valueSize < 32 ? 16 : 20, padding: valueSize < 32 ? 12 : 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: valueSize, weight: .semibold))
                    .tracking(-valueSize * 0.02)
                    .monospacedDigit()
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}

struct PageTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 40, weight: .semibold))
                .tracking(-1)
            if let detail {
                Text(detail).font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
    }
}

struct LogoView: View {
    var width: CGFloat

    private static let image = Bundle.module
        .url(forResource: "logo", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .accessibilityLabel("AppSlicerOS")
        } else {
            Text("AppSlicerOS").font(.headline)
        }
    }
}

struct LoadingOrFailure: View {
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failed {
                Text(L("error.title")).font(.title2.weight(.semibold))
                Text(L("error.detail")).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(L("loading")).foregroundStyle(.secondary)
            }
        }
    }
}
