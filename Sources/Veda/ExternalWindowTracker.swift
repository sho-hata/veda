import AppKit
import CoreGraphics
import QuartzCore
import ScreenCaptureKit

/// 他アプリのウィンドウ移動を監視し、ScreenCaptureKit（権限未許可時はシルエットフォールバック）で
/// トランザム残像を OverlayManager へ供給するトラッカー。
@MainActor
final class ExternalWindowTracker {
    private struct TrackedWindowState {
        var lastBounds: CGRect
        var lastSpawnBounds: CGRect
        var lastSpawnTime: CFTimeInterval
        var lastSeenTime: CFTimeInterval
        var ownerPID: pid_t
    }

    private struct CachedExternalSnapshot {
        var cgImage: CGImage
        var size: CGSize
        var scale: CGFloat
        var glowIntensity: Double
        var capturedAt: CFTimeInterval
    }

    private let settings: TransAmSettings
    private let snapshotRenderer: SnapshotRenderer
    private let borderManager: ExternalWindowBorderManager
    private weak var overlayManager: OverlayManager?

    private var pollTimer: Timer?
    private var trackedWindows: [CGWindowID: TrackedWindowState] = [:]
    private var snapshotCache: [CGWindowID: CachedExternalSnapshot] = [:]
    private var capturingWindowIDs: Set<CGWindowID> = []

    /// 現在マウスドラッグ中のウィンドウ（仮想デスクトップ切替等の非ドラッグ移動と区別するため）
    private var activeDraggedWindowID: CGWindowID?
    private var lastMouseLocation: CGPoint?
    private var lastMouseMoveTime: CFTimeInterval = 0
    private var suppressUntil: CFTimeInterval = 0
    private var borderSuppressUntil: CFTimeInterval = 0
    private var nonDraggedBorderSettleUntil: [CGWindowID: CFTimeInterval] = [:]

    /// SCShareableContent のウィンドウ一覧キャッシュ（頻繁な再列挙を避ける）
    private var scWindowMap: [CGWindowID: SCWindow] = [:]
    private var lastSCMapRefresh: CFTimeInterval = 0
    private var isRefreshingSCMap: Bool = false
    private var lastPrewarmTime: CFTimeInterval = 0

    private let myPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private let snapshotCacheTTL: CFTimeInterval = 0.40
    private let prewarmCacheTTL: CFTimeInterval = 2.00
    private let scMapTTL: CFTimeInterval = 1.50
    private let spaceSwitchSuppressionDuration: CFTimeInterval = 0.45
    private let recentMouseMoveWindow: CFTimeInterval = 0.20
    private let ignoredSystemOwners: Set<String> = [
        "Window Server",
        "Dock",
        "WindowManager",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "SystemUIServer",
        "Wallpaper"
    ]

    init(
        settings: TransAmSettings,
        snapshotRenderer: SnapshotRenderer,
        overlayManager: OverlayManager
    ) {
        self.settings = settings
        self.snapshotRenderer = snapshotRenderer
        self.borderManager = ExternalWindowBorderManager(settings: settings)
        self.overlayManager = overlayManager
    }

    func syncRunningState() {
        if settings.isEnabled && settings.includeOtherApps {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard pollTimer == nil else { return }
        settings.refreshScreenCapturePermission()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        activeDraggedWindowID = nil
        lastMouseLocation = NSEvent.mouseLocation
        lastMouseMoveTime = 0
        suppressUntil = 0
        borderSuppressUntil = 0
        nonDraggedBorderSettleUntil.removeAll()

        // 初回スナップショットとして既存ウィンドウ位置だけ記録（開始直後の誤爆を防ぐ）
        seedCurrentWindows()

        // 60Hz で軽量に CGWindowListCopyWindowInfo を監視（実測 <0.3ms）
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        pollTimer?.invalidate()
        pollTimer = nil
        borderManager.stop()
        trackedWindows.removeAll()
        snapshotCache.removeAll()
        capturingWindowIDs.removeAll()
        scWindowMap.removeAll()
        lastSCMapRefresh = 0
        activeDraggedWindowID = nil
        lastMouseLocation = nil
        lastMouseMoveTime = 0
        suppressUntil = 0
        borderSuppressUntil = 0
        nonDraggedBorderSettleUntil.removeAll()
    }

    func invalidateSnapshotCache() {
        snapshotCache.removeAll()
    }

    @objc private func handleActiveSpaceDidChange(_ notification: Notification) {
        let now = CACurrentMediaTime()
        suppressUntil = now + spaceSwitchSuppressionDuration
        borderSuppressUntil = max(borderSuppressUntil, now + 0.30)
        activeDraggedWindowID = nil
        nonDraggedBorderSettleUntil.removeAll()
        borderManager.hideAll()
        scWindowMap.removeAll()
        lastSCMapRefresh = 0
        seedCurrentWindows()
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        let now = CACurrentMediaTime()
        suppressUntil = max(suppressUntil, now + 0.30)
        borderSuppressUntil = max(borderSuppressUntil, now + 0.30)
        activeDraggedWindowID = nil
        nonDraggedBorderSettleUntil.removeAll()
        borderManager.hideAll()
        scWindowMap.removeAll()
        lastSCMapRefresh = 0
        seedCurrentWindows()
    }

    // MARK: - Window Polling

    private func seedCurrentWindows() {
        let now = CACurrentMediaTime()
        trackedWindows.removeAll()
        for info in fetchExternalWindows() {
            trackedWindows[info.windowID] = TrackedWindowState(
                lastBounds: info.appKitFrame,
                lastSpawnBounds: info.appKitFrame,
                lastSpawnTime: 0,
                lastSeenTime: now,
                ownerPID: info.ownerPID
            )
        }
    }

    private func pollWindows() {
        guard settings.isEnabled, settings.includeOtherApps else {
            stop()
            return
        }
        guard let overlayManager else { return }

        let now = CACurrentMediaTime()
        let mouseLocation = NSEvent.mouseLocation
        if let prevMouse = lastMouseLocation {
            if hypot(mouseLocation.x - prevMouse.x, mouseLocation.y - prevMouse.y) >= 1.0 {
                lastMouseMoveTime = now
                lastMouseLocation = mouseLocation
            }
        } else {
            lastMouseLocation = mouseLocation
        }

        let isMouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        if !isMouseDown {
            activeDraggedWindowID = nil
        }

        let currentWindows = fetchExternalWindows()
        var seenIDs = Set<CGWindowID>()

        // 複数アプリが同時移動・同時リサイズしている場合（仮想デスクトップ切替 / Mission Control / Stage Manager 等）を検出
        var changingPIDs = Set<pid_t>()
        var movingCandidateIDs = Set<CGWindowID>()
        for info in currentWindows {
            guard let state = trackedWindows[info.windowID] else { continue }
            let sizeDeltaW = abs(info.appKitFrame.width - state.lastBounds.width)
            let sizeDeltaH = abs(info.appKitFrame.height - state.lastBounds.height)
            let sizeUnchanged = sizeDeltaW < 1.0 && sizeDeltaH < 1.0

            let frameDelta = hypot(
                info.appKitFrame.origin.x - state.lastBounds.origin.x,
                info.appKitFrame.origin.y - state.lastBounds.origin.y
            )
            let spawnDelta = hypot(
                info.appKitFrame.origin.x - state.lastSpawnBounds.origin.x,
                info.appKitFrame.origin.y - state.lastSpawnBounds.origin.y
            )
            if frameDelta >= 2.0 || sizeDeltaW >= 2.0 || sizeDeltaH >= 2.0 {
                changingPIDs.insert(info.ownerPID)
                if sizeUnchanged && !isMouseDown && frameDelta >= 4.0 {
                    // 非ドラッグ中の移動（Spaces スライド等）は静止するまで枠を一時非表示にする
                    nonDraggedBorderSettleUntil[info.windowID] = now + 0.22
                }
            }
            if sizeUnchanged && spawnDelta >= 1.0 {
                movingCandidateIDs.insert(info.windowID)
            }
        }

        let isSystemWideTransition = changingPIDs.count > 1
        if isSystemWideTransition {
            activeDraggedWindowID = nil
            borderSuppressUntil = max(borderSuppressUntil, now + 0.22)
        }

        let canSpawnAfterimage = !isSystemWideTransition
            && now >= suppressUntil
            && isMouseDown
            && (now - lastMouseMoveTime) <= recentMouseMoveWindow

        // ドラッグ開始時、マウスカーソル直下の最前面ウィンドウをドラッグ対象としてロック
        if canSpawnAfterimage, activeDraggedWindowID == nil {
            for info in currentWindows where movingCandidateIDs.contains(info.windowID) {
                guard let state = trackedWindows[info.windowID] else { continue }
                let expandedPrev = state.lastBounds.insetBy(dx: -80, dy: -80)
                let expandedCurr = info.appKitFrame.insetBy(dx: -80, dy: -80)
                if expandedPrev.contains(mouseLocation) || expandedCurr.contains(mouseLocation) {
                    activeDraggedWindowID = info.windowID
                    break
                }
            }
        }

        for info in currentWindows {
            let wid = info.windowID
            seenIDs.insert(wid)

            guard var state = trackedWindows[wid] else {
                // 新規に出現したウィンドウは初回位置を記録するだけ
                trackedWindows[wid] = TrackedWindowState(
                    lastBounds: info.appKitFrame,
                    lastSpawnBounds: info.appKitFrame,
                    lastSpawnTime: 0,
                    lastSeenTime: now,
                    ownerPID: info.ownerPID
                )
                continue
            }

            state.lastSeenTime = now
            state.ownerPID = info.ownerPID

            let sizeUnchanged = abs(info.appKitFrame.width - state.lastBounds.width) < 1.0
                && abs(info.appKitFrame.height - state.lastBounds.height) < 1.0

            let distance = hypot(
                info.appKitFrame.origin.x - state.lastSpawnBounds.origin.x,
                info.appKitFrame.origin.y - state.lastSpawnBounds.origin.y
            )

            let isCursorNearWindow = state.lastBounds.insetBy(dx: -160, dy: -160).contains(mouseLocation)
                || info.appKitFrame.insetBy(dx: -160, dy: -160).contains(mouseLocation)
            let isActiveDraggedWindow = canSpawnAfterimage
                && activeDraggedWindowID == wid
                && isCursorNearWindow

            let dw = state.lastSpawnBounds.width - info.appKitFrame.width
            let dh = state.lastSpawnBounds.height - info.appKitFrame.height
            let areaShrank = (info.appKitFrame.width * info.appKitFrame.height)
                < (state.lastSpawnBounds.width * state.lastSpawnBounds.height)
            let shrinkDelta = max(max(0, dw), max(0, dh))

            if isActiveDraggedWindow
                && sizeUnchanged
                && distance >= settings.externalMinimumMoveDistance
                && (now - state.lastSpawnTime) >= settings.externalSpawnIntervalSeconds {

                let targetScreen = screenContaining(rect: state.lastSpawnBounds)
                let scale = max(1.0, targetScreen?.backingScaleFactor ?? 2.0)

                // キャッシュ済みの実画面キャプチャがあれば即座に使い、なければシルエットで即時描画しつつ裏で非同期取得
                let cachedImage = usableCachedImage(
                    for: wid,
                    expectedSize: state.lastSpawnBounds.size,
                    scale: scale,
                    now: now
                )

                if cachedImage == nil {
                    requestAsyncCaptureIfAllowed(
                        windowID: wid,
                        size: info.appKitFrame.size,
                        scale: scale,
                        glowIntensity: settings.glowIntensity
                    )
                }

                overlayManager.spawnExternalAfterimage(
                    screenRect: state.lastSpawnBounds,
                    targetWindowNumber: Int(wid),
                    snapshotImage: cachedImage,
                    scale: scale
                )

                state.lastSpawnBounds = info.appKitFrame
                state.lastSpawnTime = now
            } else if !sizeUnchanged {
                if activeDraggedWindowID == wid {
                    activeDraggedWindowID = nil
                }

                if !isSystemWideTransition
                    && now >= suppressUntil
                    && areaShrank
                    && shrinkDelta >= settings.externalMinimumShrinkDelta {
                    let targetScreen = screenContaining(rect: state.lastSpawnBounds)
                    let scale = max(1.0, targetScreen?.backingScaleFactor ?? 2.0)

                    if isMouseDown && isCursorNearWindow {
                        // ライブ縮小中は既存キャッシュをそのまま再利用し、SCScreenshotManager 連打によるカクつきを防ぐ
                        let cachedImage = snapshotCache[wid]?.cgImage
                        if cachedImage == nil {
                            requestAsyncCaptureIfAllowed(
                                windowID: wid,
                                size: info.appKitFrame.size,
                                scale: scale,
                                glowIntensity: settings.glowIntensity
                            )
                        }
                        if (now - state.lastSpawnTime) >= settings.externalSpawnIntervalSeconds {
                            overlayManager.spawnExternalAfterimage(
                                screenRect: state.lastSpawnBounds,
                                targetWindowNumber: Int(wid),
                                snapshotImage: cachedImage,
                                scale: scale
                            )
                            state.lastSpawnBounds = info.appKitFrame
                            state.lastSpawnTime = now
                        }
                    } else if shrinkDelta >= 44.0 {
                        // ウィンドウの一括縮小（拡大解除・タイル縮小等）は段階的な縮小残像を発生させる
                        let cachedImage = usableCachedImage(
                            for: wid,
                            expectedSize: state.lastSpawnBounds.size,
                            scale: scale,
                            now: now,
                            allowSizeMismatch: true
                        )
                        overlayManager.spawnShrinkBurstAfterimages(
                            fromRect: state.lastSpawnBounds,
                            toRect: info.appKitFrame,
                            targetWindowNumber: Int(wid),
                            snapshotImage: cachedImage,
                            scale: scale,
                            cornerRadius: 11.0,
                            steps: 4
                        )
                        state.lastSpawnBounds = info.appKitFrame
                        state.lastSpawnTime = now
                    }
                } else if !areaShrank {
                    // 拡大時は基準サイズを同期して次の縮小に備える（ドラッグ完了後に pre-warm でキャッシュ更新）
                    state.lastSpawnBounds = info.appKitFrame
                }
            } else if !isActiveDraggedWindow {
                // ドラッグ中でない移動（仮想デスクトップ切替等）は基準位置のみ同期して誤発光を防ぐ
                let mayStartDrag = canSpawnAfterimage
                    && activeDraggedWindowID == nil
                    && isCursorNearWindow
                if !mayStartDrag {
                    state.lastSpawnBounds = info.appKitFrame
                }
            }

            state.lastBounds = info.appKitFrame
            trackedWindows[wid] = state
        }

        // 画面から消えたウィンドウの最小化検出とクリーンアップ
        if let activeID = activeDraggedWindowID, !seenIDs.contains(activeID) {
            activeDraggedWindowID = nil
        }
        if trackedWindows.count != seenIDs.count {
            let disappearedIDs = trackedWindows.keys.filter { !seenIDs.contains($0) }

            // 単一ウィンドウが最小化（Dock へ縮小）された場合に残像バーストを発生させる
            if disappearedIDs.count == 1,
               !isSystemWideTransition,
               now >= suppressUntil,
               let wid = disappearedIDs.first,
               let state = trackedWindows[wid],
               nonDraggedBorderSettleUntil[wid] == nil,
               isWindowMinimized(windowID: wid, ownerPID: state.ownerPID) {
                let targetScreen = screenContaining(rect: state.lastBounds)
                let screenFrame = targetScreen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                let scale = max(1.0, targetScreen?.backingScaleFactor ?? 2.0)
                let targetWidth = max(64, state.lastBounds.width * 0.28)
                let targetHeight = max(44, state.lastBounds.height * 0.28)
                let targetX = min(
                    max(screenFrame.minX + 16, state.lastBounds.midX - targetWidth * 0.5),
                    screenFrame.maxX - targetWidth - 16
                )
                let toRect = CGRect(
                    x: targetX,
                    y: screenFrame.minY + 12,
                    width: targetWidth,
                    height: targetHeight
                )
                let cachedImage = snapshotCache[wid]?.cgImage

                overlayManager.spawnShrinkBurstAfterimages(
                    fromRect: state.lastBounds,
                    toRect: toRect,
                    targetWindowNumber: nil,
                    snapshotImage: cachedImage,
                    scale: scale,
                    cornerRadius: 11.0,
                    steps: 5
                )
            }

            for wid in disappearedIDs {
                trackedWindows.removeValue(forKey: wid)
                snapshotCache.removeValue(forKey: wid)
                nonDraggedBorderSettleUntil.removeValue(forKey: wid)
            }
        }

        // 他アプリのウィンドウ枠をほのかに赤く発光させつつ、ドラッグ中でない時に最前面ウィンドウの実画面キャッシュを事前ウォーム
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if !isMouseDown,
           settings.hasScreenCapturePermission,
           let frontmostPID,
           (now - lastPrewarmTime) >= 0.50,
           let frontmostWindow = currentWindows.first(where: { $0.ownerPID == frontmostPID }) {
            let needsPrewarm: Bool
            if let cached = snapshotCache[frontmostWindow.windowID] {
                let sizeMatches = abs(cached.size.width - frontmostWindow.appKitFrame.width) < 4.0
                    && abs(cached.size.height - frontmostWindow.appKitFrame.height) < 4.0
                needsPrewarm = !sizeMatches || (now - cached.capturedAt) >= prewarmCacheTTL
            } else {
                needsPrewarm = true
            }
            if needsPrewarm {
                let targetScreen = screenContaining(rect: frontmostWindow.appKitFrame)
                let scale = max(1.0, targetScreen?.backingScaleFactor ?? 2.0)
                lastPrewarmTime = now
                requestAsyncCaptureIfAllowed(
                    windowID: frontmostWindow.windowID,
                    size: frontmostWindow.appKitFrame.size,
                    scale: scale,
                    glowIntensity: settings.glowIntensity
                )
            }
        }

        let isBorderSuppressed = isSystemWideTransition || now < suppressUntil || now < borderSuppressUntil
        if isBorderSuppressed {
            borderManager.hideAll()
        } else {
            let screens = NSScreen.screens
            var assignedFrontmost = false
            var borderTargets: [ExternalWindowBorderManager.TargetWindow] = []
            borderTargets.reserveCapacity(currentWindows.count)

            for info in currentWindows {
                if let settleUntil = nonDraggedBorderSettleUntil[info.windowID] {
                    if now < settleUntil {
                        continue
                    } else {
                        nonDraggedBorderSettleUntil.removeValue(forKey: info.windowID)
                    }
                }
                guard screens.contains(where: { $0.frame.intersects(info.appKitFrame) }) else {
                    continue
                }

                let isFrontmost = !assignedFrontmost && (frontmostPID != nil) && (info.ownerPID == frontmostPID)
                if isFrontmost {
                    assignedFrontmost = true
                }
                borderTargets.append(
                    ExternalWindowBorderManager.TargetWindow(
                        windowID: info.windowID,
                        ownerPID: info.ownerPID,
                        appKitFrame: info.appKitFrame,
                        isFrontmost: isFrontmost
                    )
                )
            }

            borderManager.update(windows: borderTargets, isSuppressed: false, now: now)
        }
    }

    private func isWindowMinimized(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: ownerPID),
              !app.isTerminated,
              !app.isHidden else {
            return false
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first else {
            return false
        }
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
            return false
        }
        let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
        return !isOnscreen
    }

    private struct ExternalWindowInfo {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let appKitFrame: CGRect
    }

    private func fetchExternalWindows() -> [ExternalWindowInfo] {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        // Quartz 座標（主ディスプレイ左上原点・Y下向き）-> AppKit 座標（主ディスプレイ左下原点・Y上向き）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard primaryHeight > 0 else { return [] }

        var results: [ExternalWindowInfo] = []
        results.reserveCapacity(rawList.count)

        for entry in rawList {
            // 通常のアプリウィンドウ（layer == 0）のみ対象
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID != myPID else {
                continue
            }
            if let ownerName = entry[kCGWindowOwnerName as String] as? String,
               ignoredSystemOwners.contains(ownerName) {
                continue
            }
            guard let windowNumber = entry[kCGWindowNumber as String] as? UInt32 else {
                continue
            }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.05 {
                continue
            }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            // 小さすぎるツールチップや透明オーバーレイを除外
            guard cgRect.width >= 100, cgRect.height >= 70 else {
                continue
            }

            let appKitY = primaryHeight - (cgRect.origin.y + cgRect.size.height)
            let appKitFrame = CGRect(
                x: cgRect.origin.x,
                y: appKitY,
                width: cgRect.size.width,
                height: cgRect.size.height
            )

            results.append(ExternalWindowInfo(windowID: windowNumber, ownerPID: ownerPID, appKitFrame: appKitFrame))
        }

        return results
    }

    private func screenContaining(rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        return NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Async ScreenCaptureKit Snapshot Cache

    private func usableCachedImage(
        for windowID: CGWindowID,
        expectedSize: CGSize,
        scale: CGFloat,
        now: CFTimeInterval,
        allowSizeMismatch: Bool = false
    ) -> CGImage? {
        guard let cached = snapshotCache[windowID] else { return nil }

        let sizeMatches = abs(cached.size.width - expectedSize.width) < 2.0
            && abs(cached.size.height - expectedSize.height) < 2.0
        if !sizeMatches && !allowSizeMismatch {
            snapshotCache.removeValue(forKey: windowID)
            return nil
        }

        // TTL超過または発光強度変更時は、既存キャッシュを返しつつ裏でリフレッシュする
        let expired = (now - cached.capturedAt) >= snapshotCacheTTL
        let glowChanged = abs(cached.glowIntensity - settings.glowIntensity) > 0.05
        if expired || glowChanged || !sizeMatches {
            requestAsyncCaptureIfAllowed(
                windowID: windowID,
                size: expectedSize,
                scale: scale,
                glowIntensity: settings.glowIntensity
            )
        }

        return cached.cgImage
    }

    private func requestAsyncCaptureIfAllowed(
        windowID: CGWindowID,
        size: CGSize,
        scale: CGFloat,
        glowIntensity: Double
    ) {
        guard settings.hasScreenCapturePermission else { return }
        guard !capturingWindowIDs.contains(windowID) else { return }

        capturingWindowIDs.insert(windowID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.capturingWindowIDs.remove(windowID) }

            guard let scWindow = await self.resolveSCWindow(for: windowID) else {
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((size.width * scale).rounded()))
            config.height = max(1, Int((size.height * scale).rounded()))
            config.showsCursor = false
            config.scalesToFit = true
            config.ignoreShadowsSingleWindow = true

            do {
                let rawImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let tinted = await self.snapshotRenderer.renderTransAmImageAsync(
                    from: rawImage,
                    glowIntensity: glowIntensity
                ) ?? rawImage

                self.snapshotCache[windowID] = CachedExternalSnapshot(
                    cgImage: tinted,
                    size: size,
                    scale: scale,
                    glowIntensity: glowIntensity,
                    capturedAt: CACurrentMediaTime()
                )
            } catch {
                // 権限が取り消された場合などは静かにシルエットモードへフォールバック
                self.settings.refreshScreenCapturePermission()
            }
        }
    }

    private func resolveSCWindow(for windowID: CGWindowID) async -> SCWindow? {
        let now = CACurrentMediaTime()
        if let existing = scWindowMap[windowID], (now - lastSCMapRefresh) < scMapTTL {
            return existing
        }
        guard !isRefreshingSCMap else {
            return scWindowMap[windowID]
        }

        isRefreshingSCMap = true
        defer { isRefreshingSCMap = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            var updated: [CGWindowID: SCWindow] = [:]
            updated.reserveCapacity(content.windows.count)
            for win in content.windows {
                updated[win.windowID] = win
            }
            scWindowMap = updated
            lastSCMapRefresh = CACurrentMediaTime()
            return updated[windowID]
        } catch {
            settings.refreshScreenCapturePermission()
            return nil
        }
    }
}
