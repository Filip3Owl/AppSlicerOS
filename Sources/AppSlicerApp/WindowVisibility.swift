import AppKit
import SwiftUI

extension View {
    /// Counts this view as a visible surface only while its window can actually be seen, so
    /// a minimized or fully covered window stops the readings too.
    func pausesUpdatesWhenHidden(_ model: DashboardModel) -> some View {
        modifier(VisibilityTracking(model: model))
    }
}

private struct VisibilityTracking: ViewModifier {
    let model: DashboardModel
    @State private var isCounted = false

    func body(content: Content) -> some View {
        content
            .background(WindowOcclusionReader(onChange: update))
            .onAppear { update(true) }
            .onDisappear { update(false) }
    }

    private func update(_ isVisible: Bool) {
        guard isVisible != isCounted else { return }
        isCounted = isVisible
        if isVisible {
            model.surfaceAppeared()
        } else {
            model.surfaceDisappeared()
        }
    }
}

private struct WindowOcclusionReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> OcclusionObservingView {
        OcclusionObservingView(onChange: onChange)
    }

    func updateNSView(_ view: OcclusionObservingView, context: Context) {
        view.onChange = onChange
    }
}

private final class OcclusionObservingView: NSView {
    var onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used from a coder")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Selector-based observers are removed automatically when the view is deallocated.
        NotificationCenter.default.removeObserver(self)
        guard let newWindow else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionStateDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: newWindow
        )
    }

    @objc private func occlusionStateDidChange(_ notification: Notification) {
        guard let window else { return }
        onChange(window.occlusionState.contains(.visible))
    }
}
