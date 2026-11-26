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
    private var onboardingWindow: NSWindow?

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

        if shouldShowOnboardingOnLaunch() {
            presentOnboardingWindow()
        }

        print("Veda launched: window=\(window.frame) scale=\(window.backingScaleFactor) screenCapture=\(settings.hasScreenCapturePermission) install=\(AppInstallHelper.currentInstallState())")
        fflush(stdout)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings.refreshScreenCapturePermission()
        settings.triggerAutoDirectCaptureAuthIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        externalWindowTracker.stop()
        overlayManager.detach()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createMainWindow() -> NSWindow {
        let contentView = ControlView(
            settings: settings,
            onOpenSetup: { [weak self] in
                self?.presentOnboardingWindow()
            }
        )
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
        window.backgroundColor = NSColor(calibratedRed: 0.008, green: 0.025, blue: 0.016, alpha: 1.0)
        window.contentView = hostingView
        return window
    }

    private func shouldShowOnboardingOnLaunch() -> Bool {
        let installState = AppInstallHelper.currentInstallState()
        if installState.requiresInstallAttention {
            return true
        }
        if !settings.hasCompletedOnboarding {
            return true
        }
        return false
    }

    private func presentOnboardingWindow() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let onboardingView = OnboardingView(
            settings: settings,
            onContinue: { [weak self] in
                self?.closeOnboardingWindow()
            }
        )
        let hostingView = NSHostingView(rootView: onboardingView)

        let showInstallStep = !AppInstallHelper.currentInstallState().isInstalled
        let onboardingHeight: CGFloat = showInstallStep ? 354 : 256

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: onboardingHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Veda"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.012, green: 0.042, blue: 0.028, alpha: 1.0)
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onboardingWindow = nil
            }
        }

        self.onboardingWindow = window
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let setupItem = NSMenuItem(
            title: "初期セットアップ / 権限設定...",
            action: #selector(openOnboardingMenu(_:)),
            keyEquivalent: ","
        )
        setupItem.target = self
        appMenu.addItem(setupItem)

        let installItem = NSMenuItem(
            title: "Applications へインストール...",
            action: #selector(installToApplicationsMenu(_:)),
            keyEquivalent: ""
        )
        installItem.target = self
        appMenu.addItem(installItem)

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

    @objc private func openOnboardingMenu(_ sender: Any?) {
        presentOnboardingWindow()
    }

    @objc private func installToApplicationsMenu(_ sender: Any?) {
        do {
            let destinationURL = try AppInstallHelper.copyToApplications()
            GNParticleRingEffectController.play(centeredOn: onboardingWindow ?? mainWindow) {
                AppInstallHelper.launchInstalledAppAndTerminate(at: destinationURL)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func requestScreenCapturePermission(_ sender: Any?) {
        settings.requestScreenCapturePermission()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(requestScreenCapturePermission(_:)) {
            settings.refreshScreenCapturePermission()
            let ready = settings.isScreenCaptureReady
            menuItem.state = ready ? .on : .off
            return !ready
        }
        if menuItem.action == #selector(installToApplicationsMenu(_:)) {
            let state = AppInstallHelper.currentInstallState()
            menuItem.state = state.isInstalled ? .on : .off
            return AppInstallHelper.isAppBundle && !state.isInstalled
        }
        return true
    }
}
