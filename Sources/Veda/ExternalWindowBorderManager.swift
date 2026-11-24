import AppKit
import CoreGraphics
import QuartzCore

/// トランザム稼働中、他アプリのウィンドウ外周にほのかな赤色リム＆グローを表示するマネージャー。
/// 各ウィンドウの直上（`.above`）にクリック透過の軽量オーバーレイを配置することで、
/// ウィンドウ同士の重なり順（Zオーダー）を保ったまま自然な発光枠を描画する。
@MainActor
final class ExternalWindowBorderManager {
    struct TargetWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let appKitFrame: CGRect
        let isFrontmost: Bool
    }

    private final class BorderWindowEntry {
        let window: NSWindow
        let rootLayer: CALayer
        let glowLayer: CAShapeLayer
        let softBandLayer: CAShapeLayer
        let rimLayer: CAShapeLayer

        var currentTargetFrame: CGRect = .zero
        var currentCornerRadius: CGFloat = -1
        var currentIsFrontmost: Bool = false
        var currentGlowIntensity: Double = -1
        var currentScale: CGFloat = 0
        var isVisible: Bool = false
        var fadeStartTime: CFTimeInterval = 0

        init(
            window: NSWindow,
            rootLayer: CALayer,
            glowLayer: CAShapeLayer,
            softBandLayer: CAShapeLayer,
            rimLayer: CAShapeLayer
        ) {
            self.window = window
            self.rootLayer = rootLayer
            self.glowLayer = glowLayer
            self.softBandLayer = softBandLayer
            self.rimLayer = rimLayer
        }
    }

    private let settings: TransAmSettings
    private var activeEntries: [CGWindowID: BorderWindowEntry] = [:]
    private var recycledEntries: [BorderWindowEntry] = []
    private var lastOrderedWindowIDs: [CGWindowID] = []

    /// 広く淡いグローがクリップされないためのウィンドウ外側余白（pt）
    private let glowPadding: CGFloat = 32.0
    /// 同時に枠を表示する最大ウィンドウ数
    private let maxBorderedWindows: Int = 16
    /// 切替後・新規表示時の穏やかなフェードイン時間（秒）
    private let fadeInDuration: CFTimeInterval = 0.22

    init(settings: TransAmSettings) {
        self.settings = settings
    }

    func update(windows: [TargetWindow], isSuppressed: Bool, now: CFTimeInterval) {
        guard !isSuppressed, settings.isEnabled, settings.includeOtherApps else {
            hideAll()
            return
        }

        let eligible = Array(windows.prefix(maxBorderedWindows))
        let eligibleIDs = Set(eligible.map(\.windowID))

        // 対象外になったウィンドウの枠を即座に非表示にしてプールへ戻す
        if !activeEntries.isEmpty {
            let staleIDs = activeEntries.keys.filter { !eligibleIDs.contains($0) }
            for wid in staleIDs {
                if let entry = activeEntries.removeValue(forKey: wid) {
                    recycle(entry)
                }
            }
        }

        let orderedIDs = eligible.map(\.windowID)
        var needsReorder = (orderedIDs != lastOrderedWindowIDs)
        let glowIntensity = max(0.2, min(1.5, settings.glowIntensity))

        for target in eligible {
            let entry: BorderWindowEntry
            if let existing = activeEntries[target.windowID] {
                entry = existing
            } else {
                entry = acquireEntry()
                activeEntries[target.windowID] = entry
                needsReorder = true
            }

            let targetScreen = screenContaining(rect: target.appKitFrame)
            let scale = max(1.0, targetScreen?.backingScaleFactor ?? 2.0)
            let cornerRadius = resolvedCornerRadius(for: target.appKitFrame, screen: targetScreen)

            let frameChanged = !framesApproximatelyEqual(entry.currentTargetFrame, target.appKitFrame)
            let styleChanged = abs(entry.currentCornerRadius - cornerRadius) > 0.1
                || entry.currentIsFrontmost != target.isFrontmost
                || abs(entry.currentGlowIntensity - glowIntensity) > 0.01
                || abs(entry.currentScale - scale) > 0.01

            if frameChanged {
                let paddedFrame = target.appKitFrame.insetBy(dx: -glowPadding, dy: -glowPadding)
                entry.window.setFrame(paddedFrame, display: false)
                entry.currentTargetFrame = target.appKitFrame
            }

            if frameChanged || styleChanged {
                applyAppearance(
                    to: entry,
                    targetSize: target.appKitFrame.size,
                    cornerRadius: cornerRadius,
                    isFrontmost: target.isFrontmost,
                    glowIntensity: glowIntensity,
                    scale: scale
                )
            }

            if !entry.isVisible {
                entry.isVisible = true
                entry.fadeStartTime = now
                entry.window.alphaValue = 0.0
                needsReorder = true
            } else if entry.window.alphaValue < 1.0 {
                let elapsed = max(0.0, now - entry.fadeStartTime)
                let progress = min(1.0, elapsed / fadeInDuration)
                let eased = 1.0 - pow(1.0 - progress, 3.0)
                entry.window.alphaValue = CGFloat(eased)
            }
        }

        if needsReorder {
            // 背面から前面の順に `.above` 配置することで、各ウィンドウ間の Z オーダーを厳密に保つ
            for target in eligible.reversed() {
                guard let entry = activeEntries[target.windowID] else { continue }
                if entry.window.level != .normal {
                    entry.window.level = .normal
                }
                entry.window.order(.above, relativeTo: Int(target.windowID))
            }
            lastOrderedWindowIDs = orderedIDs
        }
    }

    func hideAll() {
        guard !activeEntries.isEmpty || !lastOrderedWindowIDs.isEmpty else { return }
        for entry in activeEntries.values {
            recycle(entry)
        }
        activeEntries.removeAll()
        lastOrderedWindowIDs.removeAll()
    }

    func stop() {
        hideAll()
        for entry in recycledEntries {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        recycledEntries.removeAll()
    }

    // MARK: - Window Pool & Rendering

    private func acquireEntry() -> BorderWindowEntry {
        if let recycled = recycledEntries.popLast() {
            recycled.currentTargetFrame = .zero
            recycled.currentCornerRadius = -1
            recycled.currentGlowIntensity = -1
            recycled.currentScale = 0
            recycled.isVisible = false
            recycled.window.alphaValue = 0.0
            return recycled
        }
        return createBorderWindowEntry()
    }

    private func recycle(_ entry: BorderWindowEntry) {
        entry.isVisible = false
        entry.window.alphaValue = 0.0
        entry.window.orderOut(nil)
        if recycledEntries.count < maxBorderedWindows {
            recycledEntries.append(entry)
        } else {
            entry.window.close()
        }
    }

    private func createBorderWindowEntry() -> BorderWindowEntry {
        let initialFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        // 全デスクトップ常駐(.canJoinAllSpaces)は避け、Spaces切替時の残存・チカチカを防ぐ
        window.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0.0

        let hostView = NSView(frame: CGRect(origin: .zero, size: initialFrame.size))
        hostView.autoresizingMask = [.width, .height]

        let rootLayer = CALayer()
        rootLayer.frame = hostView.bounds
        rootLayer.backgroundColor = NSColor.clear.cgColor
        rootLayer.masksToBounds = false

        let glowLayer = CAShapeLayer()
        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.masksToBounds = false
        glowLayer.shadowOffset = .zero

        let softBandLayer = CAShapeLayer()
        softBandLayer.fillColor = NSColor.clear.cgColor
        softBandLayer.masksToBounds = false
        softBandLayer.shadowOffset = .zero

        let rimLayer = CAShapeLayer()
        rimLayer.fillColor = NSColor.clear.cgColor
        rimLayer.masksToBounds = false

        rootLayer.addSublayer(glowLayer)
        rootLayer.addSublayer(softBandLayer)
        rootLayer.addSublayer(rimLayer)

        hostView.layer = rootLayer
        hostView.wantsLayer = true
        window.contentView = hostView

        return BorderWindowEntry(
            window: window,
            rootLayer: rootLayer,
            glowLayer: glowLayer,
            softBandLayer: softBandLayer,
            rimLayer: rimLayer
        )
    }

    private func applyAppearance(
        to entry: BorderWindowEntry,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        isFrontmost: Bool,
        glowIntensity: Double,
        scale: CGFloat
    ) {
        let fullBounds = CGRect(
            x: 0,
            y: 0,
            width: targetSize.width + glowPadding * 2,
            height: targetSize.height + glowPadding * 2
        )
        let borderRect = CGRect(
            x: glowPadding,
            y: glowPadding,
            width: targetSize.width,
            height: targetSize.height
        )
        let softBandInset: CGFloat = isFrontmost ? 2.5 : 2.0
        let softBandRect = borderRect.insetBy(dx: softBandInset, dy: softBandInset)
        let rimRect = borderRect.insetBy(dx: 0.8, dy: 0.8)

        let clampedRadius = min(cornerRadius, min(borderRect.width, borderRect.height) * 0.5)
        let softBandRadius = max(0, clampedRadius - softBandInset)
        let rimRadius = max(0, clampedRadius - 0.8)

        let outerPath = CGPath(
            roundedRect: borderRect,
            cornerWidth: clampedRadius,
            cornerHeight: clampedRadius,
            transform: nil
        )
        let softBandPath = CGPath(
            roundedRect: softBandRect,
            cornerWidth: softBandRadius,
            cornerHeight: softBandRadius,
            transform: nil
        )
        let rimPath = CGPath(
            roundedRect: rimRect,
            cornerWidth: rimRadius,
            cornerHeight: rimRadius,
            transform: nil
        )

        // 太くて淡く滲むトランザム赤オーラ（くっきりした線ではなく、ふわっと太く包み込む質感）
        let normalized = (glowIntensity - 0.2) / 1.3 // 0.0 ... 1.0
        let glowStrokeAlpha: CGFloat = isFrontmost
            ? CGFloat(0.20 + normalized * 0.14)
            : CGFloat(0.11 + normalized * 0.09)
        let softBandAlpha: CGFloat = isFrontmost
            ? CGFloat(0.18 + normalized * 0.13)
            : CGFloat(0.10 + normalized * 0.08)
        let rimStrokeAlpha: CGFloat = isFrontmost
            ? CGFloat(0.26 + normalized * 0.16)
            : CGFloat(0.14 + normalized * 0.10)
        let outerShadowRadius: CGFloat = isFrontmost
            ? CGFloat(16.0 + normalized * 10.0)
            : CGFloat(11.0 + normalized * 7.0)
        let outerShadowOpacity: Float = isFrontmost
            ? Float(min(0.88, 0.62 + normalized * 0.24))
            : Float(min(0.58, 0.36 + normalized * 0.20))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        entry.rootLayer.frame = fullBounds
        entry.rootLayer.contentsScale = scale

        // 1. 外周へ広く滲み出る淡い赤オーラ
        entry.glowLayer.frame = fullBounds
        entry.glowLayer.contentsScale = scale
        entry.glowLayer.path = outerPath
        entry.glowLayer.lineWidth = isFrontmost ? 9.5 : 6.5
        entry.glowLayer.strokeColor = NSColor(
            calibratedRed: 1.0,
            green: 0.14,
            blue: 0.34,
            alpha: glowStrokeAlpha
        ).cgColor
        entry.glowLayer.shadowColor = NSColor(
            calibratedRed: 1.0,
            green: 0.08,
            blue: 0.28,
            alpha: 1.0
        ).cgColor
        entry.glowLayer.shadowRadius = outerShadowRadius
        entry.glowLayer.shadowOpacity = outerShadowOpacity

        // 2. ウィンドウ縁を太く柔らかく包む半透明の淡紅バンド
        entry.softBandLayer.frame = fullBounds
        entry.softBandLayer.contentsScale = scale
        entry.softBandLayer.path = softBandPath
        entry.softBandLayer.lineWidth = isFrontmost ? 6.0 : 4.2
        entry.softBandLayer.strokeColor = NSColor(
            calibratedRed: 1.0,
            green: 0.24,
            blue: 0.44,
            alpha: softBandAlpha
        ).cgColor
        entry.softBandLayer.shadowColor = NSColor(
            calibratedRed: 1.0,
            green: 0.16,
            blue: 0.36,
            alpha: 1.0
        ).cgColor
        entry.softBandLayer.shadowRadius = isFrontmost ? 7.5 : 5.0
        entry.softBandLayer.shadowOpacity = isFrontmost ? 0.48 : 0.28

        // 3. 輪郭をうっすら整える繊細なピンクレッドの縁取り
        entry.rimLayer.frame = fullBounds
        entry.rimLayer.contentsScale = scale
        entry.rimLayer.path = rimPath
        entry.rimLayer.lineWidth = isFrontmost ? 1.4 : 1.0
        entry.rimLayer.strokeColor = NSColor(
            calibratedRed: 1.0,
            green: 0.44,
            blue: 0.60,
            alpha: rimStrokeAlpha
        ).cgColor

        CATransaction.commit()

        entry.currentCornerRadius = cornerRadius
        entry.currentIsFrontmost = isFrontmost
        entry.currentGlowIntensity = glowIntensity
        entry.currentScale = scale
    }

    private func resolvedCornerRadius(for frame: CGRect, screen: NSScreen?) -> CGFloat {
        if let screen {
            let fillsScreen = abs(frame.width - screen.frame.width) <= 2.0
                && abs(frame.height - screen.frame.height) <= 2.0
            if fillsScreen {
                return 0.0
            }
        }
        return 11.0
    }

    private func screenContaining(rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        return NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.25
            && abs(a.origin.y - b.origin.y) < 0.25
            && abs(a.size.width - b.size.width) < 0.25
            && abs(a.size.height - b.size.height) < 0.25
    }
}
