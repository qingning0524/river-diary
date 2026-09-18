import AppKit

@MainActor
enum ActivityLifecycle {
    static func observeTermination(
        center: NotificationCenter = .default,
        close: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // The process may exit as soon as this notification returns.
            // Queueing a Task here can silently discard the final activity.
            MainActor.assumeIsolated { close() }
        }
    }
}
