import AppKit
import SwiftUI

@main
@MainActor
final class VedaAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = TransAmSettings()
    private let snapshotRenderer = SnapshotRenderer()
    private lazy var overlayManager = OverlayManager(
        settings: settings,
        snapshotRenderer: snapshotRenderer
    )
    private lazy var externalWindowTracker = ExternalWindowTracker(
        settings: settings,
        snapshotRenderer: snapshotRenderer,
        overlayManager: overlayManager
    )

    private var mainWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = VedaAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        settings.onVisualChange = { [weak self] in
            self?.snapshotRenderer.invalidateCache()
        }
        settings.onTrackingStateChange = { [weak self] in
            self?.externalWindowTracker.syncRunningState()
        }

        let window = createMainWindow()
        self.mainWindow = window

        settings.refreshScreenCapturePermission()

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()

        overlayManager.attach(to: window)
        externalWindowTracker.syncRunningState()
        print("Veda launched: window=\(window.frame) scale=\(window.backingScaleFactor) screenCapture=\(settings.hasScreenCapturePermission)")
        fflush(stdout)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings.refreshScreenCapturePermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        externalWindowTracker.stop()
        overlayManager.detach()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createMainWindow() -> NSWindow {
        let contentView = ControlView(settings: settings)
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 350),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 440, height: 260)
        window.title = "Veda — Trans-Am"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.01, blue: 0.04, alpha: 1.0)
        window.contentView = hostingView
        return window
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let screenCaptureItem = NSMenuItem(
            title: "実画面を許可",
            action: #selector(requestScreenCapturePermission(_:)),
            keyEquivalent: ""
        )
        screenCaptureItem.target = self
        appMenu.addItem(screenCaptureItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Veda を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func requestScreenCapturePermission(_ sender: Any?) {
        settings.requestScreenCapturePermission()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(requestScreenCapturePermission(_:)) {
            settings.refreshScreenCapturePermission()
            let granted = settings.hasScreenCapturePermission
            menuItem.state = granted ? .on : .off
            return !granted
        }
        return true
    }
}
