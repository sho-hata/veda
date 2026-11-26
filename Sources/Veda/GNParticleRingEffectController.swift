import AppKit
import CoreGraphics
import QuartzCore

/// アプリケーションフォルダへの移動・インストール完了時に、
/// ガンダム00 の GN 粒子の光の輪っか 2 つが時間差で広がりながら消える
/// クリック透過オーバーレイエフェクトを再生するコントローラ。
@MainActor
final class GNParticleRingEffectController {
    private static var activeControllers: [GNParticleRingEffectController] = []

    private var panel: NSPanel?
    private var canvasView: GNParticleRingCanvasView?
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var onComplete: (@MainActor () -> Void)?

    private let panelSize: CGFloat = 540
    private let totalDuration: CFTimeInterval = 1.15

    /// 指定したスクリーン座標を中心に、GN 粒子の輪っか 2 つの展開エフェクトを再生する。
    @discardableResult
    static func play(
        at screenCenter: NSPoint,
        onComplete: (@MainActor () -> Void)? = nil
    ) -> GNParticleRingEffectController {
        let controller = GNParticleRingEffectController()
        activeControllers.append(controller)
        controller.start(at: screenCenter, onComplete: onComplete)
        return controller
    }

    /// 指定ウィンドウの中心（取得できない場合はメインスクリーン中央）からエフェクトを再生する。
    @discardableResult
    static func play(
        centeredOn window: NSWindow?,
        onComplete: (@MainActor () -> Void)? = nil
    ) -> GNParticleRingEffectController {
        let center: NSPoint
        if let window, window.isVisible {
            center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            center = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        } else {
            center = NSPoint(x: 720, y: 450)
        }
        return play(at: center, onComplete: onComplete)
    }

    private func start(at screenCenter: NSPoint, onComplete: (@MainActor () -> Void)?) {
        self.onComplete = onComplete

        let origin = NSPoint(
            x: round(screenCenter.x - panelSize * 0.5),
            y: round(screenCenter.y - panelSize * 0.5)
        )
        let rect = NSRect(origin: origin, size: NSSize(width: panelSize, height: panelSize))

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
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let view = GNParticleRingCanvasView(frame: NSRect(origin: .zero, size: rect.size))
        panel.contentView = view
        panel.orderFrontRegardless()

        self.panel = panel
        self.canvasView = view
        self.startTime = CACurrentMediaTime()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        tick()
    }

    private func tick() {
        let elapsed = max(0, CACurrentMediaTime() - startTime)
        if elapsed >= totalDuration {
            finish()
            return
        }
        canvasView?.elapsed = elapsed
        canvasView?.needsDisplay = true
    }

    private func finish() {
        timer?.invalidate()
        timer = nil

        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        canvasView = nil

        let callback = onComplete
        onComplete = nil

        Self.activeControllers.removeAll { $0 === self }
        callback?()
    }
}

// MARK: - GN Particle Double Ring Canvas View

@MainActor
private final class GNParticleRingCanvasView: NSView {
    struct GNParticle {
        let ringIndex: Int
        let baseAngle: CGFloat
        let angularDrift: CGFloat
        let radialLag: CGFloat
        let radialSpread: CGFloat
        let size: CGFloat
        let twinkleSpeed: CGFloat
        let twinklePhase: CGFloat
        let buoyancy: CGFloat
        let brightness: CGFloat
    }

    var elapsed: CFTimeInterval = 0

    private let particles: [GNParticle]

    override init(frame frameRect: NSRect) {
        self.particles = Self.makeParticles()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [r, g, b, max(0, min(1, a))])!
        }

        // 1. 発生直後の GN ドライブ点灯フラッシュ（中心の柔らかな緑白光）
        if elapsed < 0.34 {
            let p = CGFloat(elapsed / 0.34)
            let eased = easeOutCubic(p)
            let flashAlpha = (1.0 - eased) * (1.0 - eased) * 0.56
            let flashRadius: CGFloat = 18 + 74 * eased

            if flashAlpha > 0.005,
               let flashGrad = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    rgba(0.90, 1.00, 0.94, flashAlpha),
                    rgba(0.22, 1.00, 0.56, flashAlpha * 0.65),
                    rgba(0.08, 0.92, 0.44, 0.0)
                ] as CFArray,
                locations: [0.0, 0.42, 1.0]
               ) {
                ctx.drawRadialGradient(
                    flashGrad,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: flashRadius,
                    options: []
                )
            }
        }

        // 2. GN 粒子の輪っか 2 つ（時間差で外周へ広がり、光が薄れて消える）
        struct RingSpec {
            let index: Int
            let delay: CFTimeInterval
            let duration: CFTimeInterval
            let startRadius: CGFloat
            let endRadius: CGFloat
            let maxLineWidth: CGFloat
            let auraColor: (CGFloat, CGFloat, CGFloat)
            let bodyColor: (CGFloat, CGFloat, CGFloat)
            let coreColor: (CGFloat, CGFloat, CGFloat)
        }

        let rings: [RingSpec] = [
            // 第1波：力強く外へ広がるメイン GN 粒子リング（エメラルドグリーン）
            RingSpec(
                index: 0,
                delay: 0.00,
                duration: 0.92,
                startRadius: 20,
                endRadius: 214,
                maxLineWidth: 6.2,
                auraColor: (0.10, 0.96, 0.44),
                bodyColor: (0.28, 1.00, 0.58),
                coreColor: (0.88, 1.00, 0.93)
            ),
            // 第2波：わずかに遅れて追従するセカンド GN 粒子リング（ミントエメラルド）
            RingSpec(
                index: 1,
                delay: 0.17,
                duration: 0.94,
                startRadius: 16,
                endRadius: 174,
                maxLineWidth: 5.2,
                auraColor: (0.12, 0.96, 0.62),
                bodyColor: (0.34, 1.00, 0.72),
                coreColor: (0.90, 1.00, 0.96)
            )
        ]

        var ringStates: [Int: (radius: CGFloat, alpha: CGFloat, progress: CGFloat)] = [:]

        for ring in rings {
            let localTime = elapsed - ring.delay
            guard localTime >= 0, localTime <= ring.duration else { continue }

            let p = CGFloat(localTime / ring.duration)
            let easedRadius = easeOutQuart(p)
            let radius = ring.startRadius + (ring.endRadius - ring.startRadius) * easedRadius

            // 立ち上がりは瞬時に輝き、中盤〜終盤にかけて滑らかに消滅
            let fadeIn = smoothstep(0.0, 0.09, p)
            let fadeOut = pow(max(0, 1.0 - max(0, (p - 0.18) / 0.82)), 1.65)
            let alpha = fadeIn * fadeOut
            guard alpha > 0.004 else { continue }

            ringStates[ring.index] = (radius: radius, alpha: alpha, progress: p)

            let thicknessScale = 1.0 - 0.72 * easedRadius
            let bodyWidth = max(1.1, ring.maxLineWidth * thicknessScale)
            let auraWidth = max(4.0, bodyWidth * 2.8)
            let coreWidth = max(0.7, bodyWidth * 0.34)

            let circleRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            // (a) 外周の幅広い GN 粒子オーラ
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 16 * (1.0 - 0.35 * p),
                color: rgba(ring.auraColor.0, ring.auraColor.1, ring.auraColor.2, alpha * 0.85)
            )
            ctx.setLineWidth(auraWidth)
            ctx.setStrokeColor(rgba(ring.auraColor.0, ring.auraColor.1, ring.auraColor.2, alpha * 0.34))
            ctx.strokeEllipse(in: circleRect)
            ctx.restoreGState()

            // (b) 中間の鮮やかなエメラルドグリーン発光リング
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 7,
                color: rgba(ring.bodyColor.0, ring.bodyColor.1, ring.bodyColor.2, alpha * 0.90)
            )
            ctx.setLineWidth(bodyWidth)
            ctx.setStrokeColor(rgba(ring.bodyColor.0, ring.bodyColor.1, ring.bodyColor.2, alpha * 0.88))
            ctx.strokeEllipse(in: circleRect)
            ctx.restoreGState()

            // (c) 内側のシャープな白緑コアライン
            ctx.saveGState()
            ctx.setLineWidth(coreWidth)
            ctx.setStrokeColor(rgba(ring.coreColor.0, ring.coreColor.1, ring.coreColor.2, alpha * 0.96))
            ctx.strokeEllipse(in: circleRect)
            ctx.restoreGState()

            // (d) 輪っかのすぐ内側を走る繊細な粒子エネルギーの微細アーク（GN ドライブの光学質感）
            let shimmerRadius = radius * 0.955
            if shimmerRadius > 14 {
                let rot = (ring.index == 0 ? 1.0 : -1.0) * p * 0.42
                ctx.saveGState()
                ctx.setLineCap(.round)
                ctx.setLineWidth(max(0.8, bodyWidth * 0.24))
                ctx.setStrokeColor(rgba(ring.coreColor.0, ring.coreColor.1, ring.coreColor.2, alpha * 0.42))
                for seg in 0..<4 {
                    let startAngle = CGFloat(seg) * (.pi * 0.5) + rot + 0.18
                    let endAngle = startAngle + 0.58
                    ctx.addArc(
                        center: center,
                        radius: shimmerRadius,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: false
                    )
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
        }

        // 3. 2 つの輪っかに沿って舞い散るキラキラした GN 粒子の光の粒
        for particle in particles {
            guard let state = ringStates[particle.ringIndex] else { continue }
            let p = state.progress
            let angle = particle.baseAngle + particle.angularDrift * p
            let radialOffset = particle.radialLag * (0.35 + 0.65 * p) + particle.radialSpread * sin(p * .pi)
            let r = max(4, state.radius + radialOffset)

            let px = center.x + cos(angle) * r
            let py = center.y + sin(angle) * r + particle.buoyancy * p

            let twinkle = 0.58 + 0.42 * sin(p * particle.twinkleSpeed + particle.twinklePhase)
            let pAlpha = state.alpha * particle.brightness * twinkle
            guard pAlpha > 0.02 else { continue }

            let dotRadius = particle.size * (1.0 - 0.35 * p)
            let haloRadius = dotRadius * 2.8

            // 外側グリーン発光ハロー
            let haloRect = CGRect(
                x: px - haloRadius,
                y: py - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )
            ctx.setFillColor(rgba(0.18, 1.00, 0.52, pAlpha * 0.32))
            ctx.fillEllipse(in: haloRect)

            // 中心の白緑スパーク粒
            let dotRect = CGRect(
                x: px - dotRadius,
                y: py - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            ctx.setFillColor(rgba(0.88, 1.00, 0.94, pAlpha * 0.96))
            ctx.fillEllipse(in: dotRect)
        }
    }

    // MARK: - Deterministic Particle Seed

    private static func makeParticles() -> [GNParticle] {
        var result: [GNParticle] = []
        var seed: UInt64 = 0x00_6E_70_61_72_74_69_63

        func nextUnit() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = Double((seed >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
            return CGFloat(v)
        }

        let counts = [28, 22]
        for (ringIndex, count) in counts.enumerated() {
            for i in 0..<count {
                let evenAngle = (CGFloat(i) / CGFloat(count)) * (.pi * 2.0)
                let jitterAngle = (nextUnit() - 0.5) * 0.24
                let particle = GNParticle(
                    ringIndex: ringIndex,
                    baseAngle: evenAngle + jitterAngle,
                    angularDrift: (nextUnit() - 0.5) * 0.28,
                    radialLag: -16.0 + nextUnit() * 24.0,
                    radialSpread: (nextUnit() - 0.5) * 14.0,
                    size: 1.35 + nextUnit() * 2.15,
                    twinkleSpeed: 10.0 + nextUnit() * 14.0,
                    twinklePhase: nextUnit() * (.pi * 2.0),
                    buoyancy: 4.0 + nextUnit() * 16.0,
                    brightness: 0.65 + nextUnit() * 0.35
                )
                result.append(particle)
            }
        }
        return result
    }

    // MARK: - Easing

    private func easeOutCubic(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        let inv = 1.0 - t
        return 1.0 - inv * inv * inv
    }

    private func easeOutQuart(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        let inv = 1.0 - t
        return 1.0 - inv * inv * inv * inv
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3.0 - 2.0 * t)
    }
}
