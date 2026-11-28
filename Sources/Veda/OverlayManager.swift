import AppKit
import QuartzCore

@MainActor
final class OverlayManager {
    private weak var mainWindow: NSWindow?
    private let settings: TransAmSettings
    private let snapshotRenderer: SnapshotRenderer
    private let missionControlMonitor: MissionControlMonitor
    private var missionControlObserverToken: UUID?

    private var overlayWindow: NSWindow?
    private var rootLayer: CALayer?

    private var lastSpawnTime: CFTimeInterval = 0
    private var lastSpawnFrame: CGRect?
    private var lastObservedSize: CGSize?
    private var isLiveResizing: Bool = false
    private var lastOrderedTargetWindowNumber: Int?
    private var activeLayers: [CALayer] = []
    private var suppressAfterimagesUntil: CFTimeInterval = 0

    /// 過剰なレイヤー蓄積を防ぐ上限
    private let maxActiveLayers: Int = 64

    /// 仮想デスクトップ切替直後のシステムアニメーションによる誤発光を防ぐ抑止時間（秒）
    private let spaceSwitchSuppressionDuration: CFTimeInterval = 0.45

    init(
        settings: TransAmSettings,
        snapshotRenderer: SnapshotRenderer,
        missionControlMonitor: MissionControlMonitor
    ) {
        self.settings = settings
        self.snapshotRenderer = snapshotRenderer
        self.missionControlMonitor = missionControlMonitor
    }

    func attach(to window: NSWindow) {
        detach()
        self.mainWindow = window

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let overlayFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let overlay = createOverlayWindow(frame: overlayFrame, level: window.level)
        self.overlayWindow = overlay

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWindowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowWillStartLiveResize(_:)),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowBackingChanged(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowOrderSync(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowOrderSync(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowWillMiniaturize(_:)),
            name: NSWindow.willMiniaturizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        missionControlObserverToken = missionControlMonitor.addObserver { [weak self] isActive in
            self?.handleMissionControlStateChanged(isActive)
        }

        let initialRect = currentContentRectInScreen(for: window)
        lastSpawnFrame = initialRect
        lastObservedSize = initialRect.size
        isLiveResizing = false
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let token = missionControlObserverToken {
            missionControlMonitor.removeObserver(token)
            missionControlObserverToken = nil
        }

        clearAllEffects()
        overlayWindow = nil
        rootLayer = nil
        mainWindow = nil
        lastSpawnFrame = nil
        lastObservedSize = nil
        isLiveResizing = false
        lastSpawnTime = 0
        suppressAfterimagesUntil = 0
        snapshotRenderer.clearCache()
    }

    func orderOverlayBehindMainWindow(forceOrderIn: Bool = false) {
        guard !missionControlMonitor.isActive else { return }
        guard let mainWindow, let overlayWindow else { return }
        guard mainWindow.isVisible else { return }
        guard forceOrderIn || !activeLayers.isEmpty else { return }

        if overlayWindow.level != mainWindow.level {
            overlayWindow.level = mainWindow.level
        }
        if activeLayers.isEmpty || lastOrderedTargetWindowNumber != mainWindow.windowNumber {
            overlayWindow.order(.below, relativeTo: mainWindow.windowNumber)
            lastOrderedTargetWindowNumber = mainWindow.windowNumber
        }
    }

    private func hideOverlayIfIdle() {
        guard activeLayers.isEmpty else { return }
        overlayWindow?.orderOut(nil)
        lastOrderedTargetWindowNumber = nil
    }

    private func isPrimaryMouseButtonPressed() -> Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    private func createOverlayWindow(frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let overlay = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        // Mission Control（仮想ディスプレイ一覧）表示中はシステム側でも非表示・一覧除外にする
        overlay.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.level = level
        overlay.animationBehavior = .none
        overlay.isReleasedWhenClosed = false

        let hostView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        hostView.autoresizingMask = [.width, .height]

        let layer = CALayer()
        layer.frame = hostView.bounds
        layer.backgroundColor = NSColor.clear.cgColor
        layer.masksToBounds = false
        layer.contentsScale = overlay.backingScaleFactor

        // AppKit の layer-hosting view は layer を先に設定してから wantsLayer = true にする
        hostView.layer = layer
        hostView.wantsLayer = true

        overlay.contentView = hostView
        self.rootLayer = layer
        return overlay
    }

    private func syncOverlayScreenIfNeeded(for screen: NSScreen? = nil) {
        guard let overlayWindow else { return }
        guard let targetScreen = screen ?? mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let newFrame = targetScreen.frame
        let oldFrame = overlayWindow.frame
        guard oldFrame != newFrame else { return }

        let dx = oldFrame.origin.x - newFrame.origin.x
        let dy = oldFrame.origin.y - newFrame.origin.y

        overlayWindow.setFrame(newFrame, display: false)

        if let rootLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rootLayer.frame = CGRect(origin: .zero, size: newFrame.size)
            rootLayer.contentsScale = overlayWindow.backingScaleFactor
            // 画面切り替え時も既存残像のスクリーン座標を保つ
            for layer in activeLayers {
                layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
            }
            CATransaction.commit()
        }
    }

    /// 他のアプリのウィンドウ用に、対象ウィンドウのすぐ背面へトランザム残像を配置する
    func spawnExternalAfterimage(
        screenRect: CGRect,
        targetWindowNumber: Int,
        snapshotImage: CGImage?,
        scale: CGFloat
    ) {
        guard !missionControlMonitor.isActive else { return }
        guard let overlayWindow else { return }
        guard CACurrentMediaTime() >= suppressAfterimagesUntil else { return }

        let targetScreen = screenContaining(rect: screenRect)
        syncOverlayScreenIfNeeded(for: targetScreen)

        if overlayWindow.level != .normal {
            overlayWindow.level = .normal
        }
        if activeLayers.isEmpty || lastOrderedTargetWindowNumber != targetWindowNumber {
            overlayWindow.order(.below, relativeTo: targetWindowNumber)
            lastOrderedTargetWindowNumber = targetWindowNumber
        }

        spawnAfterimageLayer(
            screenRect: screenRect,
            snapshotImage: snapshotImage,
            snapshotScale: scale,
            cornerRadius: 11.0
        )
    }

    /// 縮小・最小化時に、元サイズから縮小先へ向かって段階的なトランザム残像を生成する
    func spawnShrinkBurstAfterimages(
        fromRect: CGRect,
        toRect: CGRect,
        targetWindowNumber: Int?,
        snapshotImage: CGImage?,
        scale: CGFloat,
        cornerRadius: CGFloat = 11.0,
        steps: Int = 4
    ) {
        guard settings.isEnabled else { return }
        guard !missionControlMonitor.isActive else { return }
        guard CACurrentMediaTime() >= suppressAfterimagesUntil else { return }
        guard let overlayWindow else { return }

        let targetScreen = screenContaining(rect: fromRect)
        syncOverlayScreenIfNeeded(for: targetScreen)

        if overlayWindow.level != .normal {
            overlayWindow.level = .normal
        }
        if let targetWindowNumber {
            if activeLayers.isEmpty || lastOrderedTargetWindowNumber != targetWindowNumber {
                overlayWindow.order(.below, relativeTo: targetWindowNumber)
                lastOrderedTargetWindowNumber = targetWindowNumber
            }
        } else {
            overlayWindow.orderFront(nil)
            lastOrderedTargetWindowNumber = nil
        }

        let clampedSteps = max(1, min(6, steps))
        for step in 0..<clampedSteps {
            let progress = CGFloat(step) / CGFloat(clampedSteps)
            let rect = interpolateRect(from: fromRect, to: toRect, t: progress)
            let opacity = Float(max(0.45, 0.84 - Double(step) * 0.08))
            let delayMs = step * 24

            if delayMs == 0 {
                spawnAfterimageLayer(
                    screenRect: rect,
                    snapshotImage: snapshotImage,
                    snapshotScale: scale,
                    cornerRadius: cornerRadius,
                    startOpacity: opacity,
                    endScale: 0.96
                )
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard let self,
                          self.settings.isEnabled,
                          !self.missionControlMonitor.isActive,
                          CACurrentMediaTime() >= self.suppressAfterimagesUntil,
                          let overlayWindow = self.overlayWindow else {
                        return
                    }
                    if let targetWindowNumber {
                        if self.activeLayers.isEmpty || self.lastOrderedTargetWindowNumber != targetWindowNumber {
                            overlayWindow.order(.below, relativeTo: targetWindowNumber)
                            self.lastOrderedTargetWindowNumber = targetWindowNumber
                        }
                    } else {
                        overlayWindow.orderFront(nil)
                        self.lastOrderedTargetWindowNumber = nil
                    }
                    self.spawnAfterimageLayer(
                        screenRect: rect,
                        snapshotImage: snapshotImage,
                        snapshotScale: scale,
                        cornerRadius: cornerRadius,
                        startOpacity: opacity,
                        endScale: 0.96
                    )
                }
            }
        }
    }

    private func interpolateRect(from: CGRect, to: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * t,
            y: from.origin.y + (to.origin.y - from.origin.y) * t,
            width: max(24, from.size.width + (to.size.width - from.size.width) * t),
            height: max(24, from.size.height + (to.size.height - from.size.height) * t)
        )
    }

    private func currentContentRectInScreen(for window: NSWindow) -> CGRect {
        guard let contentView = window.contentView else { return window.frame }
        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        return window.convertToScreen(contentRectInWindow)
    }

    private func screenContaining(rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        return NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Notifications

    @objc private func handleWindowDidMove(_ notification: Notification) {
        guard let mainWindow, let contentView = mainWindow.contentView else { return }

        let now = CACurrentMediaTime()
        let currentRect = currentContentRectInScreen(for: mainWindow)
        let sizeChangedSinceLastEvent = lastObservedSize.map {
            abs(currentRect.width - $0.width) >= 1.0 || abs(currentRect.height - $0.height) >= 1.0
        } ?? false
        lastObservedSize = currentRect.size

        // リサイズを伴う座標変化（左上・左辺・下辺ドラッグ等）は didResize 側で処理する
        if isLiveResizing || sizeChangedSinceLastEvent {
            return
        }

        missionControlMonitor.refreshFromSystemWindowListIfStale()

        guard settings.isEnabled,
              !missionControlMonitor.isActive,
              now >= suppressAfterimagesUntil,
              isPrimaryMouseButtonPressed() else {
            lastSpawnFrame = currentRect
            return
        }

        if let previousRect = lastSpawnFrame {
            // 過去の未達リサイズ由来のサイズズレがあれば基準をリセットして移動を継続できるようにする
            if abs(currentRect.width - previousRect.width) >= 1.0
                || abs(currentRect.height - previousRect.height) >= 1.0 {
                lastSpawnFrame = currentRect
                return
            }

            let distance = hypot(
                currentRect.origin.x - previousRect.origin.x,
                currentRect.origin.y - previousRect.origin.y
            )
            guard distance >= settings.minimumMoveDistance else { return }
        }

        // 生成間隔チェック
        guard (now - lastSpawnTime) >= settings.spawnIntervalSeconds else { return }

        syncOverlayScreenIfNeeded()
        orderOverlayBehindMainWindow(forceOrderIn: true)

        let spawnRect = lastSpawnFrame ?? currentRect
        lastSpawnTime = now
        lastSpawnFrame = currentRect

        spawnAfterimage(for: mainWindow, contentView: contentView, screenRect: spawnRect, now: now)
    }

    @objc private func handleWindowWillStartLiveResize(_ notification: Notification) {
        guard let mainWindow, let contentView = mainWindow.contentView else { return }
        isLiveResizing = true
        let rect = currentContentRectInScreen(for: mainWindow)
        lastSpawnFrame = rect
        lastObservedSize = rect.size
        if settings.isEnabled {
            let scale = max(1.0, mainWindow.backingScaleFactor)
            _ = snapshotRenderer.snapshot(
                for: contentView,
                scale: scale,
                glowIntensity: settings.glowIntensity,
                now: CACurrentMediaTime()
            )
        }
    }

    @objc private func handleWindowDidEndLiveResize(_ notification: Notification) {
        isLiveResizing = false
        if let mainWindow {
            let rect = currentContentRectInScreen(for: mainWindow)
            lastSpawnFrame = rect
            lastObservedSize = rect.size
        }
        snapshotRenderer.invalidateCache()
    }

    @objc private func handleWindowDidResize(_ notification: Notification) {
        guard let mainWindow, let contentView = mainWindow.contentView else {
            snapshotRenderer.invalidateCache()
            orderOverlayBehindMainWindow()
            return
        }

        let now = CACurrentMediaTime()
        let currentRect = currentContentRectInScreen(for: mainWindow)
        lastObservedSize = currentRect.size

        missionControlMonitor.refreshFromSystemWindowListIfStale()

        if settings.isEnabled,
           !missionControlMonitor.isActive,
           now >= suppressAfterimagesUntil,
           let previousRect = lastSpawnFrame {
            let dw = previousRect.width - currentRect.width
            let dh = previousRect.height - currentRect.height
            let areaShrank = (currentRect.width * currentRect.height) < (previousRect.width * previousRect.height)
            let shrinkDelta = max(max(0, dw), max(0, dh))

            if areaShrank && shrinkDelta >= settings.minimumShrinkDelta {
                let isLiveDrag = isLiveResizing || isPrimaryMouseButtonPressed()
                if isLiveDrag {
                    if (now - lastSpawnTime) >= settings.spawnIntervalSeconds {
                        syncOverlayScreenIfNeeded()
                        orderOverlayBehindMainWindow(forceOrderIn: true)
                        // ライブ縮小中は開始時キャッシュを再利用し、メインスレッドの再キャプチャによるカクつきを防ぐ
                        spawnAfterimage(
                            for: mainWindow,
                            contentView: contentView,
                            screenRect: previousRect,
                            now: now,
                            preferCached: true
                        )
                        lastSpawnTime = now
                        lastSpawnFrame = currentRect
                    }
                    return
                } else if shrinkDelta >= 44.0 {
                    // 一括縮小（タイル配置や拡大解除など）は段階的な縮小残像を発生させる
                    let scale = max(1.0, mainWindow.backingScaleFactor)
                    let snapshot = snapshotRenderer.reusableCachedSnapshot()
                        ?? snapshotRenderer.snapshot(
                            for: contentView,
                            scale: scale,
                            glowIntensity: settings.glowIntensity,
                            now: now
                        )
                    let cornerRadius = resolvedWindowCornerRadius(for: mainWindow)
                    spawnShrinkBurstAfterimages(
                        fromRect: previousRect,
                        toRect: currentRect,
                        targetWindowNumber: mainWindow.windowNumber,
                        snapshotImage: snapshot?.cgImage,
                        scale: snapshot?.backingScaleFactor ?? scale,
                        cornerRadius: cornerRadius,
                        steps: 4
                    )
                    lastSpawnTime = now
                    lastSpawnFrame = currentRect
                    snapshotRenderer.invalidateCache()
                    return
                }
            } else if !areaShrank {
                // 拡大時は基準サイズを更新し、次に縮小し始めた瞬間に最大サイズから残像が出るようにする
                lastSpawnFrame = currentRect
            }
        } else {
            lastSpawnFrame = currentRect
        }

        if !isLiveResizing {
            snapshotRenderer.invalidateCache()
        }
        orderOverlayBehindMainWindow()
    }

    @objc private func handleWindowBackingChanged(_ notification: Notification) {
        snapshotRenderer.invalidateCache()
        if let overlayWindow, let rootLayer {
            rootLayer.contentsScale = overlayWindow.backingScaleFactor
        }
    }

    @objc private func handleWindowOrderSync(_ notification: Notification) {
        snapshotRenderer.invalidateCache()
        syncOverlayScreenIfNeeded()
        orderOverlayBehindMainWindow()
    }

    @objc private func handleWindowWillMiniaturize(_ notification: Notification) {
        guard let mainWindow, let contentView = mainWindow.contentView else {
            clearAllEffects()
            return
        }

        missionControlMonitor.refreshFromSystemWindowListIfStale()

        let now = CACurrentMediaTime()
        guard settings.isEnabled,
              !missionControlMonitor.isActive,
              now >= suppressAfterimagesUntil else {
            clearAllEffects()
            return
        }

        let fromRect = currentContentRectInScreen(for: mainWindow)
        let screenFrame = (mainWindow.screen ?? screenContaining(rect: fromRect))?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let targetWidth = max(64, fromRect.width * 0.28)
        let targetHeight = max(44, fromRect.height * 0.28)
        let targetX = min(
            max(screenFrame.minX + 16, fromRect.midX - targetWidth * 0.5),
            screenFrame.maxX - targetWidth - 16
        )
        let toRect = CGRect(
            x: targetX,
            y: screenFrame.minY + 12,
            width: targetWidth,
            height: targetHeight
        )

        let scale = max(1.0, mainWindow.backingScaleFactor)
        let snapshot = snapshotRenderer.snapshot(
            for: contentView,
            scale: scale,
            glowIntensity: settings.glowIntensity,
            now: now
        )
        let cornerRadius = resolvedWindowCornerRadius(for: mainWindow)

        spawnShrinkBurstAfterimages(
            fromRect: fromRect,
            toRect: toRect,
            targetWindowNumber: nil,
            snapshotImage: snapshot?.cgImage,
            scale: snapshot?.backingScaleFactor ?? scale,
            cornerRadius: cornerRadius,
            steps: 5
        )
    }

    @objc private func handleWindowDidDeminiaturize(_ notification: Notification) {
        if let mainWindow {
            lastSpawnFrame = currentContentRectInScreen(for: mainWindow)
        }
        snapshotRenderer.invalidateCache()
        syncOverlayScreenIfNeeded()
        orderOverlayBehindMainWindow()
    }

    @objc private func handleWindowDidChangeScreen(_ notification: Notification) {
        if let mainWindow {
            lastSpawnFrame = currentContentRectInScreen(for: mainWindow)
        }
        snapshotRenderer.invalidateCache()
        syncOverlayScreenIfNeeded()
        orderOverlayBehindMainWindow()
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        suppressAfterimagesUntil = max(suppressAfterimagesUntil, CACurrentMediaTime() + 0.30)
        clearAllEffects()
        lastSpawnFrame = mainWindow.map { currentContentRectInScreen(for: $0) }
        snapshotRenderer.invalidateCache()
        syncOverlayScreenIfNeeded()
    }

    @objc private func handleActiveSpaceDidChange(_ notification: Notification) {
        suppressAfterimagesUntil = CACurrentMediaTime() + spaceSwitchSuppressionDuration
        clearAllEffects()
        lastSpawnFrame = mainWindow.map { currentContentRectInScreen(for: $0) }
        snapshotRenderer.invalidateCache()
    }

    private func handleMissionControlStateChanged(_ isActive: Bool) {
        if isActive {
            isLiveResizing = false
            clearAllEffects()
        } else {
            suppressAfterimagesUntil = max(
                suppressAfterimagesUntil,
                CACurrentMediaTime() + spaceSwitchSuppressionDuration
            )
            clearAllEffects()
            let currentRect = mainWindow.map { currentContentRectInScreen(for: $0) }
            lastSpawnFrame = currentRect
            lastObservedSize = currentRect?.size
            snapshotRenderer.invalidateCache()
        }
    }

    // MARK: - Afterimage Spawning & Lifecycle

    private func spawnAfterimage(
        for mainWindow: NSWindow,
        contentView: NSView,
        screenRect: CGRect,
        now: CFTimeInterval,
        preferCached: Bool = false
    ) {
        let scale = max(1.0, mainWindow.backingScaleFactor)
        let resolvedSnapshot: SnapshotRenderer.CachedSnapshot?
        if preferCached, let cached = snapshotRenderer.reusableCachedSnapshot() {
            resolvedSnapshot = cached
        } else {
            resolvedSnapshot = snapshotRenderer.snapshot(
                for: contentView,
                scale: scale,
                glowIntensity: settings.glowIntensity,
                now: now
            )
        }
        guard let snapshot = resolvedSnapshot else {
            return
        }

        let cornerRadius = resolvedWindowCornerRadius(for: mainWindow)

        spawnAfterimageLayer(
            screenRect: screenRect,
            snapshotImage: snapshot.cgImage,
            snapshotScale: snapshot.backingScaleFactor,
            cornerRadius: cornerRadius
        )
    }

    private func spawnAfterimageLayer(
        screenRect: CGRect,
        snapshotImage: CGImage?,
        snapshotScale: CGFloat,
        cornerRadius: CGFloat,
        startOpacity: Float = 0.84,
        endScale: CGFloat = 0.992
    ) {
        guard let overlayWindow, let overlayView = overlayWindow.contentView, let rootLayer else {
            return
        }

        // スクリーン座標 -> オーバーレイウィンドウ座標 -> 物理ピクセル境界スナップ
        let rectInOverlayWindow = overlayWindow.convertFromScreen(screenRect)
        let rectInOverlayView = overlayView.convert(rectInOverlayWindow, from: nil)
        let alignedFrame = overlayWindow.backingAlignedRect(rectInOverlayView, options: .alignAllEdgesNearest)

        let scale = max(1.0, snapshotScale)
        let glowIntensity = settings.glowIntensity
        let duration = max(0.05, settings.fadeDuration)

        // 外側グロー用コンテナ（ボヤけを抑えたタイトな赤グロー）
        let containerLayer = CALayer()
        containerLayer.frame = alignedFrame
        containerLayer.contentsScale = scale
        containerLayer.masksToBounds = false
        containerLayer.shadowColor = NSColor(
            calibratedRed: 1.0,
            green: 0.08,
            blue: 0.30,
            alpha: 1.0
        ).cgColor
        let baseShadowRadius = CGFloat(4.0 + glowIntensity * 7.0)
        containerLayer.shadowRadius = baseShadowRadius
        containerLayer.shadowOpacity = Float(min(0.80, 0.35 + glowIntensity * 0.35))
        containerLayer.shadowOffset = .zero
        containerLayer.shadowPath = CGPath(
            roundedRect: containerLayer.bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // 内側スナップショット用レイヤー（角丸マスク + クッキリした赤発光リム）
        let imageLayer = CALayer()
        imageLayer.frame = containerLayer.bounds
        imageLayer.contentsScale = scale
        imageLayer.cornerRadius = cornerRadius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = CGFloat(1.4 + glowIntensity * 0.7)
        imageLayer.borderColor = NSColor(
            calibratedRed: 1.0,
            green: 0.30,
            blue: 0.54,
            alpha: CGFloat(min(0.98, 0.65 + glowIntensity * 0.35))
        ).cgColor

        if let snapshotImage {
            imageLayer.contents = snapshotImage
            imageLayer.contentsGravity = .resize
        } else {
            // 画面収録権限未許可時や初回キャプチャ待ちでも輪郭がくっきり見える透過フレーム
            let gradient = CAGradientLayer()
            gradient.frame = imageLayer.bounds
            gradient.contentsScale = scale
            gradient.colors = [
                NSColor(calibratedRed: 1.0, green: 0.14, blue: 0.38, alpha: 0.30).cgColor,
                NSColor(calibratedRed: 0.78, green: 0.04, blue: 0.24, alpha: 0.18).cgColor,
                NSColor(calibratedRed: 1.0, green: 0.20, blue: 0.46, alpha: 0.28).cgColor
            ]
            gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
            gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
            imageLayer.addSublayer(gradient)
        }

        containerLayer.addSublayer(imageLayer)

        // 上限超過時は最も古い残像を即時破棄してメモリ増加を防ぐ
        if activeLayers.count >= maxActiveLayers, let oldest = activeLayers.first {
            removeAfterimageLayer(oldest)
        }

        let endOpacity: Float = 0.0

        // モデル層の最終値を先に設定し、アニメーション終了時のチラつきと不要な fillMode 保持を防ぐ
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.opacity = endOpacity
        containerLayer.transform = CATransform3DMakeScale(endScale, endScale, 1.0)
        rootLayer.addSublayer(containerLayer)
        CATransaction.commit()

        activeLayers.append(containerLayer)
        settings.activeAfterimageCount = activeLayers.count

        // シャドウ半径を固定して GPU 再計算を防ぎつつ、くっきり視認できてスッと消えるフェードアニメーション
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = startOpacity
        opacityAnim.toValue = endOpacity
        opacityAnim.duration = duration

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = endScale
        scaleAnim.duration = duration

        let group = CAAnimationGroup()
        group.animations = [opacityAnim, scaleAnim]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.82, 1.0)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak containerLayer] in
            MainActor.assumeIsolated {
                guard let self, let containerLayer else { return }
                self.removeAfterimageLayer(containerLayer)
            }
        }
        containerLayer.add(group, forKey: "transAmAfterimageFade")
        CATransaction.commit()
    }

    private func removeAfterimageLayer(_ layer: CALayer) {
        layer.removeAllAnimations()
        if let sublayers = layer.sublayers {
            for sub in sublayers {
                sub.contents = nil
                sub.removeFromSuperlayer()
            }
        }
        layer.contents = nil
        layer.removeFromSuperlayer()

        if let index = activeLayers.firstIndex(where: { $0 === layer }) {
            activeLayers.remove(at: index)
        }
        settings.activeAfterimageCount = activeLayers.count
        hideOverlayIfIdle()
    }

    func clearAllEffects() {
        clearAllAfterimages()
        if let sublayers = rootLayer?.sublayers {
            for layer in sublayers {
                layer.removeAllAnimations()
                layer.contents = nil
                layer.removeFromSuperlayer()
            }
        }
        overlayWindow?.orderOut(nil)
        lastOrderedTargetWindowNumber = nil
    }

    private func clearAllAfterimages() {
        let layersToRemove = activeLayers
        activeLayers.removeAll()
        for layer in layersToRemove {
            layer.removeAllAnimations()
            layer.sublayers?.forEach {
                $0.contents = nil
                $0.removeFromSuperlayer()
            }
            layer.contents = nil
            layer.removeFromSuperlayer()
        }
        settings.activeAfterimageCount = 0
    }

    private func resolvedWindowCornerRadius(for window: NSWindow) -> CGFloat {
        if let themeRadius = window.contentView?.superview?.layer?.cornerRadius, themeRadius > 0 {
            return themeRadius
        }
        return 12.0
    }
}
