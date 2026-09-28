import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen and not fully covered, minimized, or closed.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        VisibilityView(onChange: onChange)
    }

    func updateNSView(_ view: VisibilityView, context: Context) {}

    final class VisibilityView: NSView {
        private let onChange: @MainActor (Bool) -> Void
        private var observers: [any NSObjectProtocol] = []
        private var shown: NSKeyValueObservation?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            shown = nil
            guard let window else { return onChange(false) }
            observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                },
            ]
            // SwiftUI keeps the closed window and shows it again on reopen, so this view never leaves it.
            shown = window.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            }
            #if DEBUG
            if DebugHooks.isActive {
                window.setFrameAutosaveName("")
                if let size = DebugHooks.windowSize { window.setContentSize(size) }
            }
            #endif
            report()
        }

        private func report() {
            guard let window else { return onChange(false) }
            #if DEBUG
            // Automated runs may happen with the screen locked, where nothing counts as visible.
            if DebugHooks.isActive { return onChange(window.isVisible) }
            #endif
            onChange(window.occlusionState.contains(.visible))
        }
    }
}
