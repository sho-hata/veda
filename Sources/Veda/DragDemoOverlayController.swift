import AppKit
import CoreGraphics
import QuartzCore

/// superlogical/rex の権限セットアップデモのように、
/// ドラッグ元アイコンからターゲット（システム設定のリスト／Applications ドロップ枠）へ
/// 半透明のゴーストアイコンが弧を描いて飛ぶクリック透過オーバーレイアニメーションを管理する。
@MainActor
final class DragDemoOverlayController {
    enum DemoMode: Equatable {
        case none
        case applications
        case systemSettings
    }

    /// ゴーストが飛行中かどうか（元アイコンを薄く表示して「持ち上げた感」を出す）
    var onFlightStateChanged: ((DemoMode, Bool) -> Void)?
    /// Applications ターゲットへ着地した瞬間のハイライト連動
    var onTargetHighlightChanged: ((DemoMode, Bool) -> Void)?

    private var mode: DemoMode = .none
    private var isUserInteracting: Bool = false
    private var resumeAllowedAfter: CFTimeInterval = 0

    private weak var installSourceIconView: NSView?
    private weak var installTargetView: NSView?
    private weak var screenCaptureSourceIconView: NSView?

    private var overlayPanel: NSPanel?
    private var ghostView: DragGhostIconView?
    private var timer: Timer?

    private var cycleStartTime: CFTimeInterval = 0
    private var lastReportedMode: DemoMode = .none
    private var lastReportedInFlight: Bool = false
    private var lastReportedTargetHighlight: Bool = false

    // Rex のデモ動画（00:15〜00:20）に近いテンポのサイクル定数（計 3.35 秒）
    private let pickupDuration: CFTimeInterval = 0.18
    private let flightDuration: CFTimeInterval = 1.25
    private let dwellDuration: CFTimeInterval = 0.42
    private let fadeOutDuration: CFTimeInterval = 0.30
    private let restDuration: CFTimeInterval = 1.20
    private var totalCycleDuration: CFTimeInterval {
        pickupDuration + flightDuration + dwellDuration + fadeOutDuration + restDuration
    }

    private let panelSize: CGFloat = 96

    func registerInstallAnchors(sourceIconView: NSView?, targetView: NSView?) {
        if let sourceIconView {
            installSourceIconView = sourceIconView
        }
        if let targetView {
            installTargetView = targetView
        }
    }

    func registerScreenCaptureSourceIconView(_ view: NSView?) {
        if let view {
            screenCaptureSourceIconView = view
        }
    }

    /// Applications ドロップ先枠のスクリーン中央座標（完了エフェクトの起点用）を返す。
    func installTargetScreenCenter() -> NSPoint? {
        guard let targetView = installTargetView else { return nil }
        return Self.screenCenter(of: targetView)
    }

    func setMode(_ newMode: DemoMode) {
        guard mode != newMode else { return }
        mode = newMode
        resetVisualState()
        if mode == .none {
            stopTimerAndHidePanel()
        } else {
            cycleStartTime = CACurrentMediaTime()
            ensureTimerRunning()
        }
    }

    func setUserInteracting(_ interacting: Bool) {
        guard isUserInteracting != interacting else { return }
        isUserInteracting = interacting
        if interacting {
            hideGhostImmediately()
        } else {
            // ホバー解除・ドラッグキャンセル直後は少し間を置いてから再開
            resumeAllowedAfter = CACurrentMediaTime() + 0.9
            cycleStartTime = resumeAllowedAfter
        }
    }

    /// システム設定とオンボーディングウィンドウが大きく重なっている場合、
    /// Rex のようにシステム設定の横へスッと並べてドラッグ先を見やすくする。
    func nudgeOnboardingBesideSystemSettingsIfOverlapping() {
        guard let onboardingWindow = screenCaptureSourceIconView?.window
                ?? installSourceIconView?.window,
              onboardingWindow.isVisible,
              let sysFrame = Self.systemSettingsAppKitFrame() else {
            return
        }

        let currentFrame = onboardingWindow.frame
        guard currentFrame.intersects(sysFrame.insetBy(dx: -12, dy: -12)) else {
            return
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(sysFrame) })
            ?? onboardingWindow.screen
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let gap: CGFloat = 18
        let rightCandidateX = sysFrame.maxX + gap
        let leftCandidateX = sysFrame.minX - gap - currentFrame.width

        let targetX: CGFloat
        if rightCandidateX + currentFrame.width <= visible.maxX - 8 {
            targetX = rightCandidateX
        } else if leftCandidateX >= visible.minX + 8 {
            targetX = leftCandidateX
        } else {
            targetX = max(visible.minX + 8, visible.maxX - currentFrame.width - 12)
        }

        let idealY = sysFrame.maxY - currentFrame.height - 24
        let targetY = min(
            max(idealY, visible.minY + 12),
            visible.maxY - currentFrame.height - 12
        )

        let targetFrame = NSRect(
            x: round(targetX),
            y: round(targetY),
            width: currentFrame.width,
            height: currentFrame.height
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            onboardingWindow.animator().setFrame(targetFrame, display: true)
        }
    }

    func stop() {
        mode = .none
        isUserInteracting = false
        resetVisualState()
        stopTimerAndHidePanel()
        overlayPanel?.close()
        overlayPanel = nil
        ghostView = nil
    }

    // MARK: - Animation Loop

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimerAndHidePanel() {
        timer?.invalidate()
        timer = nil
        overlayPanel?.orderOut(nil)
    }

    private func hideGhostImmediately() {
        overlayPanel?.orderOut(nil)
        reportFlightState(mode: mode, inFlight: false)
        reportTargetHighlight(mode: mode, highlighted: false)
    }

    private func resetVisualState() {
        overlayPanel?.orderOut(nil)
        reportFlightState(mode: mode, inFlight: false)
        reportTargetHighlight(mode: mode, highlighted: false)
    }

    private func reportFlightState(mode: DemoMode, inFlight: Bool) {
        if lastReportedMode == mode && lastReportedInFlight == inFlight {
            return
        }
        lastReportedMode = mode
        lastReportedInFlight = inFlight
        onFlightStateChanged?(mode, inFlight)
    }

    private func reportTargetHighlight(mode: DemoMode, highlighted: Bool) {
        if lastReportedTargetHighlight == highlighted {
            return
        }
        lastReportedTargetHighlight = highlighted
        onTargetHighlightChanged?(mode, highlighted)
    }

    private func tick() {
        guard mode != .none else {
            stopTimerAndHidePanel()
            return
        }

        let now = CACurrentMediaTime()
        if isUserInteracting || now < resumeAllowedAfter {
            hideGhostImmediately()
            return
        }

        guard let endpoints = resolveEndpoints(for: mode) else {
            hideGhostImmediately()
            // ターゲット（例: システム設定ウィンドウ）が現れたら最初のフレームから綺麗に開始
            cycleStartTime = now
            return
        }

        let elapsed = (now - cycleStartTime).truncatingRemainder(dividingBy: totalCycleDuration)
        let pickupEnd = pickupDuration
        let flightEnd = pickupEnd + flightDuration
        let dwellEnd = flightEnd + dwellDuration
        let fadeOutEnd = dwellEnd + fadeOutDuration

        if elapsed >= fadeOutEnd {
            // 休憩区間：ゴーストを隠し、元アイコンも元の明るさに戻す
            hideGhostImmediately()
            return
        }

        let start = endpoints.start
        let end = endpoints.end
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance >= 12 else {
            hideGhostImmediately()
            return
        }

        let arcLift: CGFloat = mode == .systemSettings
            ? min(max(distance * 0.16, 36), 92)
            : min(max(distance * 0.18, 20), 34)
        let control = NSPoint(
            x: (start.x + end.x) * 0.5,
            y: max(start.y, end.y) + arcLift
        )

        let iconSize: CGFloat = mode == .systemSettings ? 54 : 36
        let currentPoint: NSPoint
        let opacity: CGFloat
        let scale: CGFloat
        let targetHighlighted: Bool
        let showDropRing: CGFloat

        if elapsed < pickupEnd {
            let p = easeOutCubic(elapsed / pickupEnd)
            currentPoint = start
            opacity = 0.76 * p
            scale = 0.88 + 0.18 * p
            targetHighlighted = false
            showDropRing = 0
        } else if elapsed < flightEnd {
            let p = easeInOutCubic((elapsed - pickupEnd) / flightDuration)
            currentPoint = quadraticBezier(p0: start, p1: control, p2: end, t: p)
            opacity = 0.76
            scale = 1.06
            targetHighlighted = p > 0.86
            showDropRing = 0
        } else if elapsed < dwellEnd {
            let p = (elapsed - flightEnd) / dwellDuration
            let settle = easeOutCubic(min(1.0, p / 0.45))
            currentPoint = end
            opacity = 0.76
            scale = 1.06 - 0.10 * settle
            targetHighlighted = true
            showDropRing = CGFloat(sin(min(1.0, p) * .pi))
        } else {
            let p = easeInOutCubic((elapsed - dwellEnd) / fadeOutDuration)
            currentPoint = end
            opacity = 0.76 * (1.0 - p)
            scale = 0.96 - 0.08 * p
            targetHighlighted = false
            showDropRing = 0
        }

        let panel = ensureOverlayPanel()
        ghostView?.update(
            iconSize: iconSize,
            opacity: opacity,
            scale: scale,
            dropRingProgress: showDropRing
        )

        let origin = NSPoint(
            x: currentPoint.x - panelSize * 0.5,
            y: currentPoint.y - panelSize * 0.5
        )
        panel.setFrameOrigin(origin)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        reportFlightState(mode: mode, inFlight: true)
        reportTargetHighlight(mode: mode, highlighted: targetHighlighted)
    }

    // MARK: - Endpoint Resolution

    private func resolveEndpoints(for mode: DemoMode) -> (start: NSPoint, end: NSPoint)? {
        switch mode {
        case .none:
            return nil
        case .applications:
            guard let sourceView = installSourceIconView,
                  let targetView = installTargetView,
                  let start = Self.screenCenter(of: sourceView),
                  let end = Self.screenCenter(of: targetView) else {
                return nil
            }
            return (start, end)
        case .systemSettings:
            guard let sourceView = screenCaptureSourceIconView,
                  let start = Self.screenCenter(of: sourceView),
                  let sysFrame = Self.systemSettingsAppKitFrame() else {
                return nil
            }
            // システム設定ウィンドウの右ペイン（画面収録アプリ一覧の中央やや上）を狙う
            let end = NSPoint(
                x: sysFrame.minX + sysFrame.width * 0.65,
                y: sysFrame.maxY - min(sysFrame.height * 0.36, 200)
            )
            return (start, end)
        }
    }

    private static func screenCenter(of view: NSView) -> NSPoint? {
        guard let window = view.window, window.isVisible, !window.isMiniaturized else {
            return nil
        }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let localCenter = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let windowPoint = view.convert(localCenter, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    static func systemSettingsAppKitFrame() -> CGRect? {
        let settingsApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        )
        let pids = Set(
            settingsApps
                .filter { !$0.isTerminated && !$0.isHidden }
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty else { return nil }

        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height, primaryHeight > 0 else {
            return nil
        }

        var bestFrame: CGRect?
        var bestArea: CGFloat = 0

        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            // ツールチップ等の微小ウィンドウを除外
            guard cgRect.width >= 300, cgRect.height >= 260 else { continue }

            let appKitRect = CGRect(
                x: cgRect.origin.x,
                y: primaryHeight - cgRect.origin.y - cgRect.height,
                width: cgRect.width,
                height: cgRect.height
            )
            let area = appKitRect.width * appKitRect.height
            if area > bestArea {
                bestArea = area
                bestFrame = appKitRect
            }
        }

        return bestFrame
    }

    // MARK: - Overlay Panel

    private func ensureOverlayPanel() -> NSPanel {
        if let existing = overlayPanel {
            return existing
        }

        let rect = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let view = DragGhostIconView(frame: NSRect(origin: .zero, size: rect.size))
        panel.contentView = view
        self.ghostView = view
        self.overlayPanel = panel
        return panel
    }

    // MARK: - Math

    private func quadraticBezier(p0: NSPoint, p1: NSPoint, p2: NSPoint, t: CGFloat) -> NSPoint {
        let u = 1.0 - t
        let x = u * u * p0.x + 2.0 * u * t * p1.x + t * t * p2.x
        let y = u * u * p0.y + 2.0 * u * t * p1.y + t * t * p2.y
        return NSPoint(x: x, y: y)
    }

    private func easeOutCubic(_ x: Double) -> CGFloat {
        let clamped = min(max(x, 0), 1)
        let inv = 1.0 - clamped
        return CGFloat(1.0 - inv * inv * inv)
    }

    private func easeInOutCubic(_ x: Double) -> CGFloat {
        let clamped = min(max(x, 0), 1)
        if clamped < 0.5 {
            return CGFloat(4.0 * clamped * clamped * clamped)
        } else {
            let f = -2.0 * clamped + 2.0
            return CGFloat(1.0 - (f * f * f) / 2.0)
        }
    }
}

/// クリック透過フローティングパネル上に描画される半透明ゴーストアイコン。
@MainActor
private final class DragGhostIconView: NSView {
    private let iconLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private var cachedIconSize: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = NSColor(
            calibratedRed: 0.22,
            green: 0.98,
            blue: 0.54,
            alpha: 0.70
        ).cgColor
        ringLayer.lineWidth = 2.0
        ringLayer.opacity = 0
        layer?.addSublayer(ringLayer)

        iconLayer.contentsGravity = .resizeAspect
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOpacity = 0.42
        iconLayer.shadowRadius = 10
        iconLayer.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(iconLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        iconSize: CGFloat,
        opacity: CGFloat,
        scale: CGFloat,
        dropRingProgress: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if abs(cachedIconSize - iconSize) > 0.5 {
            cachedIconSize = iconSize
            let image = AppInstallHelper.appIconImage(size: iconSize)
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
            var proposedRect = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
            if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                iconLayer.contents = cgImage
                iconLayer.contentsScale = scaleFactor
            } else {
                iconLayer.contents = image
            }
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        iconLayer.position = center
        iconLayer.opacity = Float(opacity)
        iconLayer.transform = CATransform3DMakeScale(scale, scale, 1.0)

        if dropRingProgress > 0.01 {
            let ringRadius = iconSize * (0.48 + 0.22 * dropRingProgress)
            let ringRect = CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            )
            ringLayer.path = CGPath(ellipseIn: ringRect, transform: nil)
            ringLayer.opacity = Float(0.45 * dropRingProgress)
        } else {
            ringLayer.opacity = 0
        }

        CATransaction.commit()
    }
}
