import SwiftUI

/// ガンダム00 コックピットのバイザー型ディスプレイの輪郭（下部中央に台形ノッチあり・周囲の灰色フレームなし）
struct VisorScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x0 = rect.minX
        let y0 = rect.minY

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: x0 + w * nx, y: y0 + h * ny)
        }

        var path = Path()
        path.move(to: pt(0.085, 0.020))
        path.addLine(to: pt(0.915, 0.020))
        path.addLine(to: pt(0.992, 0.280))
        path.addLine(to: pt(0.875, 0.980))
        path.addLine(to: pt(0.625, 0.980))
        path.addLine(to: pt(0.578, 0.775))
        path.addLine(to: pt(0.422, 0.775))
        path.addLine(to: pt(0.375, 0.980))
        path.addLine(to: pt(0.125, 0.980))
        path.addLine(to: pt(0.008, 0.280))
        path.closeSubpath()
        return path
    }
}

/// ガンダム00 トランザム バイザーディスプレイ
/// - スタンバイ（起動前）: 深緑背景＋緑/黄の同心円弧＋中央の緑色逆Aレティクル＆台形ラダー＋右端ミントアクア六角セル
/// - 起動遷移（約 2.2 秒）: 蛇腹・回転なしで全体がその場でシームレスに色相転換＆同時発光。
///   中央の逆Aレティクルが青色へ変色しながらフェードアウトし、六角セルがアクア→深紫→マゼンタ紫へ変化、
///   緑の外周弧がシアンへ変わりつつマゼンタのリング＆左右ウィングが一斉に浮かび上がり、「TRANS-AM / 99」が点灯する。
/// - アクティブ（稼働中）: マゼンタ×シアン弧の TRANS-AM コンソール表示を維持（クリックでスタンバイへ復帰）
struct TransAmConsoleView: View {
    let phase: TransAmSettings.ModePhase
    let onToggle: () -> Void
    let onComplete: () -> Void

    static let activationDuration: Double = 0.90

    @State private var isHovering: Bool = false
    @State private var isPressed: Bool = false
    @State private var didPushHandCursor: Bool = false
    @State private var completedStartTime: Date?

    private var isActivating: Bool {
        if case .activating = phase { return true }
        return false
    }

    private var isActive: Bool {
        phase == .active
    }

    var body: some View {
        let interval = isActivating ? (1.0 / 60.0) : (1.0 / 30.0)

        TimelineView(.animation(minimumInterval: interval)) { context in
            let now = context.date
            let visualState = computeVisualState(now: now)

            consoleBody(state: visualState)
                .onChange(of: visualState.didComplete) { _, finished in
                    guard finished, case let .activating(startedAt) = phase else { return }
                    if completedStartTime != startedAt {
                        completedStartTime = startedAt
                        onComplete()
                    }
                }
        }
    }

    // MARK: - Visual State Calculation

    private struct ConsoleVisualState {
        /// 0.0 = 深緑スタンバイ背景, 1.0 = 深紫トランザム背景
        let bgTransAmMix: Double
        /// 起動前ゲージ弧（緑・黄）の残存不透明度（1.0 -> 0.0）
        let standbyArcsOpacity: Double
        /// 中央逆Aレティクル＆台形ラダーの残存不透明度（1.0 -> 0.0）
        let reticleOpacity: Double
        /// 中央逆Aレティクルの色相転換（0.0 = ネオングリーン, 1.0 = 青紫）
        let reticleBlueShift: Double
        /// 外周弧の色相転換（0.0 = 緑, 1.0 = シアンティール）
        let outerCyanShift: Double
        /// マゼンタリングの一斉発光フェードイン（0.0 -> 1.0）
        let magentaBloomOpacity: Double
        /// 同時展開時のわずかな放射スケール（0.94 -> 1.00）
        let magentaRadialScale: CGFloat
        /// 左右の三角ウィングが中心付近から横へ「シュッ」と一息に広がる展開進捗（0.0 -> 1.0）
        let wingSweep: Double
        /// 展開中のスイープ発光ブースト
        let wingSweepGlow: Double
        /// 4本対角レイの輝きピーク（遷移中間で強く光る）
        let diagonalRayGlow: Double
        /// 右端3連六角セルの遷移（0.0 = ミントアクア, 0.5 = 濃ロイヤルパープル, 1.0 = マゼンタ紫）
        let hexPhase: Double
        /// 中央「TRANS-AM / 99」の点灯不透明度・発光ブースト
        let titleOpacity: Double
        let titleGlowBoost: Double
        /// 控えめな全体グロー脈動（白飛びしない光学フレア）
        let softSurgeAlpha: Double
        /// 連続脈動用の経過時間（秒）
        let ambientTime: Double
        /// カウンター数値（00 〜 99）
        let counterValue: Int
        let didComplete: Bool
    }

    private func computeVisualState(now: Date) -> ConsoleVisualState {
        let ambient = now.timeIntervalSinceReferenceDate

        switch phase {
        case .standby:
            return ConsoleVisualState(
                bgTransAmMix: 0.0,
                standbyArcsOpacity: 1.0,
                reticleOpacity: 1.0,
                reticleBlueShift: 0.0,
                outerCyanShift: 0.0,
                magentaBloomOpacity: 0.0,
                magentaRadialScale: 1.0,
                wingSweep: 0.0,
                wingSweepGlow: 0.0,
                diagonalRayGlow: 0.0,
                hexPhase: 0.0,
                titleOpacity: 0.0,
                titleGlowBoost: 0.0,
                softSurgeAlpha: 0.0,
                ambientTime: ambient,
                counterValue: 0,
                didComplete: false
            )

        case let .activating(startedAt):
            let elapsed = max(0.0, now.timeIntervalSince(startedAt))
            let t = min(elapsed, Self.activationDuration)

            // 0.00 - 0.16s: 背景が深緑 → 深紫バイオレットへキレよく即時切替
            let bgTransAmMix = easeOutQuart(clamp(t / 0.16))

            // 0.00 - 0.44s: 逆Aレティクルはその場で即座に緑 → 青へ切り替わり、0.28s〜0.44sでスパッと消える
            let reticleBlueShift = easeOutQuart(clamp(t / 0.14))
            let reticleOpacity = 1.0 - easeOutCubic(clamp((t - 0.28) / 0.16))

            // 0.08 - 0.42s: 起動前の緑・黄弧がキビキビ退き、外周の緑が素早くシアンへ切替
            let standbyArcsOpacity = 1.0 - easeOutCubic(clamp((t - 0.08) / 0.30))
            let outerCyanShift = easeOutQuart(clamp((t - 0.16) / 0.30))

            // 0.04 - 0.34s: マゼンタリングが全体一斉にキレよく立ち上がる
            let magentaBloomOpacity = easeOutQuart(clamp((t - 0.04) / 0.28))
            let magentaRadialScale = 0.93 + 0.07 * CGFloat(easeOutQuart(clamp((t - 0.04) / 0.26)))

            // 0.20 - 0.44s: 左右の三角ウィングが中心付近から両端へ「シュッ！」とキレよく一息に広がる（0.24s）
            let rawSweep = clamp((t - 0.20) / 0.24)
            let wingSweep = easeOutQuart(rawSweep)
            let wingSweepGlow = rawSweep > 0.01 ? sin(rawSweep * .pi) * 0.45 : 0.0

            // 0.06 - 0.56s: 4本の対角ピンクホワイト光条が鋭く走る
            let diagonalRayGlow = sin(clamp((t - 0.06) / 0.52) * .pi)

            // 右端3連角形: 0.0(アクア) → 0.5(濃パープル @ 0.20s) → 1.0(マゼンタ紫 @ 0.58s)
            let hexPhase = easeOutCubic(clamp(t / 0.58))

            // 0.40 - 0.56s: 逆Aの消滅と同時に「MODE/TASYS-05 / TRANS-AM」がスパッと点灯＆カウンター00→99高速上昇
            let titleOpacity = easeOutQuart(clamp((t - 0.40) / 0.16))
            let titleGlowBoost = exp(-pow((t - 0.52) / 0.11, 2)) * 0.55
            let counterP = easeOutCubic(clamp((t - 0.40) / 0.30))
            let counterValue = Int((counterP * 99.0).rounded())

            // 0.48s 付近の短い光学キレ感サージ
            let softSurgeAlpha = exp(-pow((t - 0.48) / 0.08, 2)) * 0.22

            return ConsoleVisualState(
                bgTransAmMix: bgTransAmMix,
                standbyArcsOpacity: standbyArcsOpacity,
                reticleOpacity: reticleOpacity,
                reticleBlueShift: reticleBlueShift,
                outerCyanShift: outerCyanShift,
                magentaBloomOpacity: magentaBloomOpacity,
                magentaRadialScale: magentaRadialScale,
                wingSweep: wingSweep,
                wingSweepGlow: wingSweepGlow,
                diagonalRayGlow: diagonalRayGlow,
                hexPhase: hexPhase,
                titleOpacity: titleOpacity,
                titleGlowBoost: titleGlowBoost,
                softSurgeAlpha: softSurgeAlpha,
                ambientTime: ambient,
                counterValue: counterValue,
                didComplete: elapsed >= Self.activationDuration
            )

        case .active:
            return ConsoleVisualState(
                bgTransAmMix: 1.0,
                standbyArcsOpacity: 0.0,
                reticleOpacity: 0.0,
                reticleBlueShift: 1.0,
                outerCyanShift: 1.0,
                magentaBloomOpacity: 1.0,
                magentaRadialScale: 1.0,
                wingSweep: 1.0,
                wingSweepGlow: 0.0,
                diagonalRayGlow: 0.0,
                hexPhase: 1.0,
                titleOpacity: 1.0,
                titleGlowBoost: 0.0,
                softSurgeAlpha: 0.0,
                ambientTime: ambient,
                counterValue: 99,
                didComplete: false
            )
        }
    }

    // MARK: - Main Visor Display (No Gray Outer Frame, Full Responsive Scaling)

    @ViewBuilder
    private func consoleBody(state: ConsoleVisualState) -> some View {
        let glowTint = blendColor(
            from: (0.28, 0.96, 0.32),
            to: (1.00, 0.14, 0.70),
            progress: state.bgTransAmMix
        )

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let uiScale = max(0.70, min(w / 480.0, h / 225.0))

            visorDisplayLayer(state: state, uiScale: uiScale)
                .frame(width: w, height: h)
                .clipShape(VisorScreenShape())
                .overlay {
                    VisorScreenShape()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    glowTint.opacity(isHovering && !isActivating ? 0.72 : 0.40),
                                    glowTint.opacity(0.18 + state.bgTransAmMix * 0.22),
                                    glowTint.opacity(isHovering && !isActivating ? 0.68 : 0.34)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1.4, 2.0 * uiScale)
                        )
                }
                .shadow(
                    color: glowTint.opacity(0.24 + state.bgTransAmMix * 0.34 + state.softSurgeAlpha * 0.5),
                    radius: (14 + CGFloat(state.softSurgeAlpha) * 18) * uiScale
                )
                .contentShape(VisorScreenShape())
                .scaleEffect(isPressed ? 0.993 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .onHover { hovering in
                    isHovering = hovering
                    syncHandCursor()
                }
                .onChange(of: isActivating) { _, _ in
                    syncHandCursor()
                }
                .onDisappear {
                    if didPushHandCursor {
                        NSCursor.pop()
                        didPushHandCursor = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !isActivating else { return }
                            let dist = hypot(value.translation.width, value.translation.height)
                            isPressed = dist < 14
                        }
                        .onEnded { value in
                            let wasPressed = isPressed
                            isPressed = false
                            guard !isActivating, wasPressed else { return }
                            let dist = hypot(value.translation.width, value.translation.height)
                            if dist < 14 {
                                onToggle()
                            }
                        }
                )
        }
    }

    private func syncHandCursor() {
        let shouldShowHand = isHovering && !isActivating
        if shouldShowHand && !didPushHandCursor {
            NSCursor.pointingHand.push()
            didPushHandCursor = true
        } else if !shouldShowHand && didPushHandCursor {
            NSCursor.pop()
            didPushHandCursor = false
        }
    }

    // MARK: - Inner Visor HUD

    private func visorDisplayLayer(state: ConsoleVisualState, uiScale: CGFloat) -> some View {
        let bgMix = state.bgTransAmMix
        let breath = 0.5 + 0.5 * sin(state.ambientTime * (isActive ? 3.0 : 1.8))

        // トランザム側パレット
        let ringCoreColor = Color(red: 1.00, green: 0.12, blue: 0.68)
        let ringHotColor = Color(red: 1.00, green: 0.34, blue: 0.84)
        let ringHighlightColor = Color(red: 1.00, green: 0.78, blue: 0.96)
        // 外周弧：遷移中は緑が残り、次第にターコイズシアンへシフト
        let outerAccentColor = blendColor(
            from: (0.28, 0.94, 0.36),
            to: (0.14, 0.86, 0.84),
            progress: state.outerCyanShift
        )
        let outerVioletColor = blendColor(
            from: (0.42, 0.10, 0.84),
            to: (0.70, 0.12, 0.80),
            progress: state.hexPhase
        )

        // 背景色補間（起動前：深緑 -> 起動中/後：深紫ロイヤルインディゴ）
        let centerBgInner = blendColor(
            from: (0.03, 0.16, 0.045),
            to: (0.22, 0.09, 0.52),
            progress: bgMix
        )
        let centerBgOuter = blendColor(
            from: (0.01, 0.07, 0.02),
            to: (0.04, 0.015, 0.14),
            progress: bgMix
        )

        return ZStack {
            // 1. バイザー内部の60fps Canvas 描画
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let center = CGPoint(x: w * 0.50, y: h * 0.455)

                let outerRx = min(w * 0.320, h * 0.72)
                let outerRy = min(h * 0.388, w * 0.22)
                let innerRx = outerRx * 0.640
                let innerRy = outerRy * 0.610

                // 1a. モニター放射状背景（深緑 -> 深紫インディゴ）
                ctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(colors: [
                            centerBgInner.opacity(0.95 + breath * 0.05),
                            centerBgOuter,
                            blendColor(from: (0.005, 0.035, 0.01), to: (0.015, 0.008, 0.05), progress: bgMix)
                        ]),
                        center: center,
                        startRadius: 6 * uiScale,
                        endRadius: max(w, h) * 0.62
                    )
                )

                // 1b. 起動前の緑・黄同心円ゲージ弧（その場に留まりつつ穏やかに退く）
                if state.standbyArcsOpacity > 0.005 {
                    drawStandbyOuterArcs(
                        ctx: ctx,
                        center: center,
                        innerRx: innerRx,
                        innerRy: innerRy,
                        outerRx: outerRx,
                        outerRy: outerRy,
                        opacity: state.standbyArcsOpacity,
                        outerCyanShift: state.outerCyanShift,
                        breath: breath,
                        uiScale: uiScale
                    )
                }

                // 1c. トランザム側：外周シアン弧・パープル弧・左右ウィング・マゼンタリング（蛇腹なし・全体一斉発光）
                if state.magentaBloomOpacity > 0.005 {
                    let mAlpha = state.magentaBloomOpacity
                    let s = state.magentaRadialScale
                    let sInnerRx = innerRx * (0.97 + 0.03 * s)
                    let sInnerRy = innerRy * (0.97 + 0.03 * s)
                    let sOuterRx = outerRx * s
                    let sOuterRy = outerRy * s

                    // 外周のシアン弧（遷移途中の緑→シアン変化を再現）＆パープル装飾弧
                    drawOuterCyanAndVioletArcs(
                        ctx: ctx,
                        center: center,
                        outerRx: sOuterRx,
                        outerRy: sOuterRy,
                        accentColor: outerAccentColor,
                        violetColor: outerVioletColor,
                        alpha: mAlpha,
                        breath: breath,
                        uiScale: uiScale
                    )

                    // 左側面のバランス用アクセント
                    drawLeftTechAccents(
                        ctx: ctx,
                        size: size,
                        violetColor: outerVioletColor,
                        cyanColor: outerAccentColor,
                        alpha: mAlpha,
                        uiScale: uiScale
                    )

                    // 左右マゼンタ三角ウィング（中心付近から両端へ「シュッ」と一息に広がる連続展開）
                    drawSideWingFlares(
                        ctx: ctx,
                        size: size,
                        center: center,
                        innerRx: sInnerRx,
                        outerRx: sOuterRx,
                        outerRy: sOuterRy,
                        ringCore: ringCoreColor,
                        ringHot: ringHotColor,
                        ringHighlight: ringHighlightColor,
                        sweep: state.wingSweep,
                        sweepGlow: state.wingSweepGlow,
                        alpha: mAlpha,
                        breath: breath,
                        uiScale: uiScale
                    )

                    // メインの分割マゼンタ楕円リング（回転なし・蛇腹なし・全セグメント同時発光）
                    drawSegmentedEllipticalRing(
                        ctx: ctx,
                        center: center,
                        innerRx: sInnerRx,
                        innerRy: sInnerRy,
                        outerRx: sOuterRx,
                        outerRy: sOuterRy,
                        ringCore: ringCoreColor,
                        ringHot: ringHotColor,
                        ringHighlight: ringHighlightColor,
                        alpha: mAlpha,
                        breath: breath,
                        uiScale: uiScale
                    )

                    // 遷移中間〜稼働中の4本対角ピンクホワイト光条（参考画像2枚目の象徴的な斜め光芒）
                    if state.diagonalRayGlow > 0.01 {
                        drawDiagonalEnergyRays(
                            ctx: ctx,
                            center: center,
                            innerRx: sInnerRx,
                            innerRy: sInnerRy,
                            outerRx: sOuterRx,
                            outerRy: sOuterRy,
                            ringHot: ringHotColor,
                            ringHighlight: ringHighlightColor,
                            intensity: state.diagonalRayGlow,
                            uiScale: uiScale
                        )
                    }

                    // 中央オーバルの深紫コア＆内縁ソフトグロー
                    let ovalRect = CGRect(
                        x: center.x - innerRx,
                        y: center.y - innerRy,
                        width: innerRx * 2,
                        height: innerRy * 2
                    )
                    let ovalPath = Path(ellipseIn: ovalRect)
                    ctx.fill(
                        ovalPath,
                        with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 0.22, green: 0.09, blue: 0.52).opacity(0.92 * mAlpha),
                                Color(red: 0.06, green: 0.02, blue: 0.22).opacity(0.95 * mAlpha)
                            ]),
                            center: center,
                            startRadius: 4 * uiScale,
                            endRadius: innerRx * 1.15
                        )
                    )

                    ctx.drawLayer { layerCtx in
                        layerCtx.addFilter(.blur(radius: 4.5 * uiScale))
                        layerCtx.stroke(ovalPath, with: .color(ringHotColor.opacity(0.82 * mAlpha)), lineWidth: 2.0 * uiScale)
                    }
                    ctx.stroke(ovalPath, with: .color(ringHighlightColor.opacity(0.60 * mAlpha)), lineWidth: 0.9 * uiScale)
                }

                // 1d. 中央の逆Aレティクル＆台形ラダー（その場に留まったまま緑 → 青へ変色してフェードアウト）
                if state.reticleOpacity > 0.005 {
                    drawCenterStandbyReticle(
                        ctx: ctx,
                        center: center,
                        innerRx: innerRx,
                        innerRy: innerRy,
                        outerRy: outerRy,
                        opacity: state.reticleOpacity,
                        blueShift: state.reticleBlueShift,
                        breath: breath,
                        uiScale: uiScale
                    )
                }

                // 1e. 右側面の3連六角モジュール（アクア → 濃ロイヤルパープル → マゼンタ紫へ連続変化）
                drawRightHexModules(
                    ctx: ctx,
                    size: size,
                    hexPhase: state.hexPhase,
                    breath: breath,
                    uiScale: uiScale
                )

                // 1f. 繊細な水平走査線
                let scanStep = max(2.5, 3.0 * uiScale)
                var scanlines = Path()
                var y: CGFloat = 0
                while y < h {
                    scanlines.move(to: CGPoint(x: 0, y: y))
                    scanlines.addLine(to: CGPoint(x: w, y: y))
                    y += scanStep
                }
                ctx.stroke(scanlines, with: .color(Color.black.opacity(0.14)), lineWidth: 0.8 * min(1.5, uiScale))

                // 1g. ガラス上部の淡いリフレクション
                var gloss = Path()
                gloss.move(to: CGPoint(x: w * 0.08, y: 0))
                gloss.addLine(to: CGPoint(x: w * 0.92, y: 0))
                gloss.addLine(to: CGPoint(x: w * 0.80, y: h * 0.22))
                gloss.addLine(to: CGPoint(x: w * 0.16, y: h * 0.14))
                gloss.closeSubpath()
                ctx.fill(
                    gloss,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.065),
                            Color.white.opacity(0.0)
                        ]),
                        startPoint: CGPoint(x: w * 0.5, y: 0),
                        endPoint: CGPoint(x: w * 0.5, y: h * 0.22)
                    )
                )
            }

            // 2. 中央オーバルの「MODE/TASYS-05 / TRANS-AM / 99」シャープなメカニック角形タイポグラフィ
            if state.titleOpacity > 0.01 {
                GeometryReader { geo in
                    let centerX = geo.size.width * 0.50
                    let centerY = geo.size.height * 0.458

                    VStack(spacing: 4.5 * uiScale) {
                        Text("MODE/TASYS-05")
                            .font(.system(size: 6.6 * uiScale, weight: .semibold, design: .monospaced))
                            .tracking(1.4 * uiScale)
                            .foregroundStyle(ringHighlightColor.opacity(0.76))

                        // 公式ロゴ準拠のワイド＆太縦線・細横線の「TRANS-AM」ベクターロゴ
                        TransAmLogoText(
                            charWidth: 20.6 * uiScale,
                            charHeight: 14.0 * uiScale,
                            spacing: 1.9 * uiScale,
                            coreColor: ringHotColor,
                            highlightColor: ringHighlightColor,
                            glowColor: ringCoreColor,
                            glowRadius: (6.5 + CGFloat(breath) * 2.2 + CGFloat(state.titleGlowBoost) * 5.5) * uiScale,
                            rimWidth: max(0.5, 0.65 * uiScale)
                        )

                        bottomTransAmReadout(
                            state: state,
                            ringHighlight: ringHighlightColor,
                            ringHot: ringHotColor,
                            ringCore: ringCoreColor,
                            breath: breath,
                            uiScale: uiScale
                        )
                    }
                    .opacity(state.titleOpacity)
                    .position(x: centerX, y: centerY)
                }
                .allowsHitTesting(false)
            }

            // 3. スタンバイ時にホバーしたときだけの控えめな起動ガイド
            if phase == .standby && isHovering {
                GeometryReader { geo in
                    Text("▶ CLICK TO ACTIVATE TRANS-AM")
                        .font(.system(size: 8.5 * uiScale, weight: .bold, design: .monospaced))
                        .tracking(1.6 * uiScale)
                        .foregroundStyle(Color(red: 0.85, green: 1.0, blue: 0.72))
                        .padding(.horizontal, 10 * uiScale)
                        .padding(.vertical, 3.5 * uiScale)
                        .background(
                            Color(red: 0.02, green: 0.14, blue: 0.04).opacity(0.86),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color(red: 0.55, green: 1.0, blue: 0.38).opacity(0.75), lineWidth: 1.0 * uiScale)
                        )
                        .shadow(color: Color(red: 0.30, green: 1.0, blue: 0.32).opacity(0.55), radius: 8 * uiScale)
                        .position(x: geo.size.width * 0.50, y: geo.size.height * 0.705)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // 4. ホバー時の微かな光学ハイライト
            if isHovering && !isActivating {
                Color.white
                    .opacity(0.025)
                    .allowsHitTesting(false)
            }

            // 5. 柔らかなマゼンタ光学サージ（過度な白飛びなし）
            if state.softSurgeAlpha > 0.005 {
                Color(red: 1.0, green: 0.36, blue: 0.82)
                    .opacity(state.softSurgeAlpha)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func bottomTransAmReadout(
        state: ConsoleVisualState,
        ringHighlight: Color,
        ringHot: Color,
        ringCore: Color,
        breath: Double,
        uiScale: CGFloat
    ) -> some View {
        if phase == .active && isHovering {
            Text("CLICK TO STANDBY")
                .font(.system(size: 8.2 * uiScale, weight: .bold, design: .monospaced))
                .tracking(1.5 * uiScale)
                .foregroundStyle(ringHighlight.opacity(0.92))
                .padding(.top, 1.5 * uiScale)
        } else {
            HStack(spacing: 8 * uiScale) {
                Rectangle()
                    .fill(ringHot.opacity(0.38))
                    .frame(width: 28 * uiScale, height: max(1.0, 1.1 * uiScale))
                MechaVectorText(
                    text: String(format: "%02d", state.counterValue),
                    charWidth: 7.4 * uiScale,
                    charHeight: 10.2 * uiScale,
                    spacing: 3.2 * uiScale,
                    strokeWidth: 1.55 * uiScale,
                    coreColor: ringHot,
                    highlightColor: ringHighlight,
                    glowColor: ringCore,
                    glowRadius: (4.5 + CGFloat(breath) * 1.5) * uiScale
                )
                Rectangle()
                    .fill(ringHot.opacity(0.38))
                    .frame(width: 28 * uiScale, height: max(1.0, 1.1 * uiScale))
            }
            .padding(.top, 1.0 * uiScale)
        }
    }

    // MARK: - Standby Outer Arcs (Green / Yellow / Upper-Right Aqua)

    private func drawStandbyOuterArcs(
        ctx: GraphicsContext,
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        opacity: Double,
        outerCyanShift: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        let limeGreen = Color(red: 0.24, green: 0.96, blue: 0.22)
        let brightGreen = Color(red: 0.44, green: 1.00, blue: 0.36)
        let lemonYellow = Color(red: 0.96, green: 0.98, blue: 0.22)
        let aquaToPurple = blendColor(
            from: (0.38, 0.98, 0.86),
            to: (0.48, 0.14, 0.86),
            progress: outerCyanShift
        )
        let darkGreenLine = Color(red: 0.03, green: 0.20, blue: 0.05)
        let pulse = 0.93 + 0.07 * breath

        let topBand = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 0.80,
            innerRy: outerRy * 0.80,
            outerRx: outerRx * 0.99,
            outerRy: outerRy * 0.99,
            startDeg: -132,
            endDeg: -48
        )
        let leftMainUpper = ellipticalAnnulusSegment(
            center: center,
            innerRx: innerRx * 1.02,
            innerRy: innerRy * 1.02,
            outerRx: outerRx * 1.15,
            outerRy: outerRy * 1.15,
            startDeg: 152,
            endDeg: 222
        )
        let leftMainLower = ellipticalAnnulusSegment(
            center: center,
            innerRx: innerRx * 1.02,
            innerRy: innerRy * 1.02,
            outerRx: outerRx * 1.15,
            outerRy: outerRy * 1.15,
            startDeg: 108,
            endDeg: 152
        )
        let rightMainUpper = ellipticalAnnulusSegment(
            center: center,
            innerRx: innerRx * 1.02,
            innerRy: innerRy * 1.02,
            outerRx: outerRx * 1.15,
            outerRy: outerRy * 1.15,
            startDeg: -42,
            endDeg: 28
        )
        let rightMainLower = ellipticalAnnulusSegment(
            center: center,
            innerRx: innerRx * 1.02,
            innerRy: innerRy * 1.02,
            outerRx: outerRx * 1.15,
            outerRy: outerRy * 1.15,
            startDeg: 28,
            endDeg: 72
        )

        let rightOuterGreen = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.17,
            innerRy: outerRy * 1.17,
            outerRx: outerRx * 1.29,
            outerRy: outerRy * 1.29,
            startDeg: -22,
            endDeg: 58
        )
        let rightOuterYellow = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.17,
            innerRy: outerRy * 1.17,
            outerRx: outerRx * 1.29,
            outerRy: outerRy * 1.29,
            startDeg: -48,
            endDeg: -22
        )
        let leftOuterGreen = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.17,
            innerRy: outerRy * 1.17,
            outerRx: outerRx * 1.29,
            outerRy: outerRy * 1.29,
            startDeg: 122,
            endDeg: 202
        )
        let leftOuterYellow = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.17,
            innerRy: outerRy * 1.17,
            outerRx: outerRx * 1.29,
            outerRy: outerRy * 1.29,
            startDeg: 202,
            endDeg: 228
        )

        let upperRightAquaBlock = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.33,
            innerRy: outerRy * 1.33,
            outerRx: outerRx * 1.48,
            outerRy: outerRy * 1.48,
            startDeg: -44,
            endDeg: -10
        )
        let upperLeftAquaAccent = ellipticalAnnulusSegment(
            center: center,
            innerRx: outerRx * 1.33,
            innerRy: outerRy * 1.33,
            outerRx: outerRx * 1.43,
            outerRy: outerRy * 1.43,
            startDeg: 192,
            endDeg: 222
        )

        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 9.0 * uiScale))
            layerCtx.fill(topBand, with: .color(lemonYellow.opacity(0.50 * opacity * pulse)))
            layerCtx.fill(leftMainUpper, with: .color(limeGreen.opacity(0.60 * opacity * pulse)))
            layerCtx.fill(rightMainUpper, with: .color(limeGreen.opacity(0.60 * opacity * pulse)))
            layerCtx.fill(leftMainLower, with: .color(lemonYellow.opacity(0.54 * opacity * pulse)))
            layerCtx.fill(rightMainLower, with: .color(lemonYellow.opacity(0.54 * opacity * pulse)))
            layerCtx.fill(upperRightAquaBlock, with: .color(aquaToPurple.opacity(0.50 * opacity)))
        }

        ctx.fill(
            topBand,
            with: .linearGradient(
                Gradient(colors: [
                    lemonYellow.opacity(0.94 * opacity),
                    brightGreen.opacity(0.94 * opacity),
                    lemonYellow.opacity(0.94 * opacity)
                ]),
                startPoint: CGPoint(x: center.x - outerRx * 0.72, y: center.y - outerRy),
                endPoint: CGPoint(x: center.x + outerRx * 0.72, y: center.y - outerRy)
            )
        )

        ctx.fill(
            leftMainUpper,
            with: .linearGradient(
                Gradient(colors: [
                    limeGreen.opacity(0.92 * opacity),
                    brightGreen.opacity(0.88 * opacity)
                ]),
                startPoint: CGPoint(x: center.x - outerRx, y: center.y - outerRy * 0.5),
                endPoint: CGPoint(x: center.x - innerRx, y: center.y + outerRy * 0.3)
            )
        )
        ctx.fill(
            leftMainLower,
            with: .linearGradient(
                Gradient(colors: [
                    brightGreen.opacity(0.90 * opacity),
                    lemonYellow.opacity(0.95 * opacity)
                ]),
                startPoint: CGPoint(x: center.x - outerRx * 0.9, y: center.y + outerRy * 0.2),
                endPoint: CGPoint(x: center.x - innerRx * 0.4, y: center.y + outerRy * 0.95)
            )
        )
        ctx.fill(
            rightMainUpper,
            with: .linearGradient(
                Gradient(colors: [
                    brightGreen.opacity(0.88 * opacity),
                    limeGreen.opacity(0.92 * opacity)
                ]),
                startPoint: CGPoint(x: center.x + innerRx, y: center.y - outerRy * 0.5),
                endPoint: CGPoint(x: center.x + outerRx, y: center.y + outerRy * 0.3)
            )
        )
        ctx.fill(
            rightMainLower,
            with: .linearGradient(
                Gradient(colors: [
                    brightGreen.opacity(0.90 * opacity),
                    lemonYellow.opacity(0.95 * opacity)
                ]),
                startPoint: CGPoint(x: center.x + outerRx * 0.9, y: center.y + outerRy * 0.2),
                endPoint: CGPoint(x: center.x + innerRx * 0.4, y: center.y + outerRy * 0.95)
            )
        )

        ctx.fill(rightOuterGreen, with: .color(limeGreen.opacity(0.86 * opacity)))
        ctx.fill(rightOuterYellow, with: .color(lemonYellow.opacity(0.92 * opacity)))
        ctx.fill(leftOuterGreen, with: .color(limeGreen.opacity(0.86 * opacity)))
        ctx.fill(leftOuterYellow, with: .color(lemonYellow.opacity(0.92 * opacity)))

        ctx.fill(upperRightAquaBlock, with: .color(aquaToPurple.opacity(0.92 * opacity)))
        ctx.fill(upperLeftAquaAccent, with: .color(aquaToPurple.opacity(0.42 * opacity)))

        var dividerLines = Path()
        for deg in [-132.0, -48.0, 28.0, 152.0] {
            let rad = deg * .pi / 180.0
            dividerLines.move(to: ellipsePoint(center: center, rx: innerRx * 0.95, ry: innerRy * 0.95, angle: rad))
            dividerLines.addLine(to: ellipsePoint(center: center, rx: outerRx * 1.48, ry: outerRy * 1.48, angle: rad))
        }
        ctx.stroke(dividerLines, with: .color(lemonYellow.opacity(0.75 * opacity)), lineWidth: 1.4 * uiScale)

        let hy = center.y + innerRy * 0.10
        var horizonLine = Path()
        horizonLine.move(to: CGPoint(x: center.x - outerRx * 1.45, y: hy))
        horizonLine.addLine(to: CGPoint(x: center.x - innerRx * 0.96, y: hy))
        horizonLine.move(to: CGPoint(x: center.x + innerRx * 0.96, y: hy))
        horizonLine.addLine(to: CGPoint(x: center.x + outerRx * 1.45, y: hy))
        ctx.stroke(horizonLine, with: .color(darkGreenLine.opacity(0.88 * opacity)), lineWidth: 1.6 * uiScale)

        var yellowTicks = Path()
        for dir in [-1.0, 1.0] as [CGFloat] {
            let tx = center.x + dir * (innerRx * 0.96)
            yellowTicks.addRect(CGRect(x: tx - 3.5 * uiScale, y: hy - 1.8 * uiScale, width: 7 * uiScale, height: 3.6 * uiScale))
            let innerTx = center.x + dir * (innerRx * 0.72)
            yellowTicks.addRect(CGRect(x: innerTx - 4.0 * uiScale, y: center.y - 2.2 * uiScale, width: 8 * uiScale, height: 4.4 * uiScale))
        }
        ctx.fill(yellowTicks, with: .color(lemonYellow.opacity(0.92 * opacity)))

        let micro99 = Text("99")
            .font(.system(size: 8.5 * uiScale, weight: .bold, design: .monospaced))
            .foregroundColor(darkGreenLine.opacity(0.85 * opacity))
        ctx.draw(micro99, at: CGPoint(x: center.x + outerRx * 0.92, y: hy - 6.5 * uiScale), anchor: .center)
    }

    /// 中央の逆Aレティクル＋下部台形＆ラダー（起動開始時にその場で緑 → 青へ色相変化しながら消える）
    private func drawCenterStandbyReticle(
        ctx: GraphicsContext,
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRy: CGFloat,
        opacity: Double,
        blueShift: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        let pulse = 0.93 + 0.07 * breath

        // 起動前はネオングリーン、起動途中は参考画像2枚目の鮮やかなエレクトリックブルーへ変化
        let mainColor = blendColor(
            from: (0.28, 0.98, 0.26),
            to: (0.18, 0.56, 1.00),
            progress: blueShift
        )
        let coreColor = blendColor(
            from: (0.74, 1.00, 0.64),
            to: (0.48, 0.80, 1.00),
            progress: blueShift
        )
        let circleColor = blendColor(
            from: (0.40, 1.00, 0.36),
            to: (0.24, 0.52, 0.96),
            progress: blueShift
        )

        let ring1Rect = CGRect(
            x: center.x - innerRx * 0.98,
            y: center.y - innerRy * 0.98,
            width: innerRx * 1.96,
            height: innerRy * 1.96
        )
        let ring2Rect = CGRect(
            x: center.x - innerRx * 0.76,
            y: center.y - innerRy * 0.76,
            width: innerRx * 1.52,
            height: innerRy * 1.52
        )
        ctx.stroke(Path(ellipseIn: ring1Rect), with: .color(circleColor.opacity(0.50 * opacity)), lineWidth: 1.3 * uiScale)
        ctx.stroke(Path(ellipseIn: ring2Rect), with: .color(circleColor.opacity(0.40 * opacity)), lineWidth: 1.1 * uiScale)

        var topTick = Path()
        topTick.move(to: CGPoint(x: center.x, y: center.y - outerRy * 0.99))
        topTick.addLine(to: CGPoint(x: center.x, y: center.y - innerRy * 0.76))
        ctx.stroke(topTick, with: .color(circleColor.opacity(0.70 * opacity)), lineWidth: 1.6 * uiScale)

        let rx = innerRx
        let ry = innerRy

        var invertedA = Path()
        invertedA.move(to: CGPoint(x: center.x - rx * 0.34, y: center.y - ry * 0.56))
        invertedA.addLine(to: CGPoint(x: center.x - rx * 0.14, y: center.y + ry * 0.18))
        invertedA.addLine(to: CGPoint(x: center.x + rx * 0.14, y: center.y + ry * 0.18))
        invertedA.addLine(to: CGPoint(x: center.x + rx * 0.34, y: center.y - ry * 0.56))
        invertedA.move(to: CGPoint(x: center.x - rx * 0.30, y: center.y - ry * 0.24))
        invertedA.addLine(to: CGPoint(x: center.x + rx * 0.30, y: center.y - ry * 0.24))

        var lowerTrap = Path()
        lowerTrap.move(to: CGPoint(x: center.x - rx * 0.15, y: center.y + ry * 0.34))
        lowerTrap.addLine(to: CGPoint(x: center.x + rx * 0.15, y: center.y + ry * 0.34))
        lowerTrap.addLine(to: CGPoint(x: center.x + rx * 0.26, y: center.y + ry * 0.72))
        lowerTrap.addLine(to: CGPoint(x: center.x - rx * 0.26, y: center.y + ry * 0.72))
        lowerTrap.closeSubpath()

        var ladder = Path()
        ladder.move(to: CGPoint(x: center.x - rx * 0.26, y: center.y + ry * 0.72))
        ladder.addLine(to: CGPoint(x: center.x - rx * 0.38, y: center.y + ry * 1.18))
        ladder.move(to: CGPoint(x: center.x + rx * 0.26, y: center.y + ry * 0.72))
        ladder.addLine(to: CGPoint(x: center.x + rx * 0.38, y: center.y + ry * 1.18))
        for step in 1...3 {
            let f = CGFloat(step) / 3.5
            let ly = center.y + ry * (0.72 + f * 0.44)
            let halfW = rx * (0.26 + f * 0.11)
            ladder.move(to: CGPoint(x: center.x - halfW, y: ly))
            ladder.addLine(to: CGPoint(x: center.x + halfW, y: ly))
        }

        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 5.0 * uiScale))
            layerCtx.stroke(
                invertedA,
                with: .color(mainColor.opacity(0.90 * opacity * pulse)),
                style: StrokeStyle(lineWidth: 4.2 * uiScale, lineCap: .square, lineJoin: .miter)
            )
            layerCtx.fill(lowerTrap, with: .color(mainColor.opacity(0.80 * opacity * pulse)))
            layerCtx.stroke(ladder, with: .color(mainColor.opacity(0.70 * opacity)), lineWidth: 1.8 * uiScale)
        }

        ctx.stroke(
            invertedA,
            with: .color(coreColor.opacity(0.95 * opacity)),
            style: StrokeStyle(lineWidth: 2.8 * uiScale, lineCap: .square, lineJoin: .miter)
        )
        ctx.fill(lowerTrap, with: .color(mainColor.opacity(0.88 * opacity)))
        ctx.stroke(ladder, with: .color(coreColor.opacity(0.82 * opacity)), lineWidth: 1.3 * uiScale)
    }

    // MARK: - Trans-Am Active / Transitioning Drawing Subroutines (Simultaneous Bloom, No Accordion)

    private func drawSegmentedEllipticalRing(
        ctx: GraphicsContext,
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        ringCore: Color,
        ringHot: Color,
        ringHighlight: Color,
        alpha: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        let segments: [(Double, Double)] = [
            (-106, -74),
            (-70, -44),
            (-40, -18),
            (-14, 14),
            (18, 44),
            (48, 74),
            (78, 102),
            (106, 132),
            (136, 162),
            (166, 194),
            (198, 220),
            (224, 250)
        ]

        let pulseBoost: Double = isActive ? (0.94 + 0.06 * breath) : 1.0

        // 全体一斉のネオングロー層
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 14.0 * uiScale))
            for seg in segments {
                let path = ellipticalAnnulusSegment(
                    center: center,
                    innerRx: innerRx,
                    innerRy: innerRy,
                    outerRx: outerRx,
                    outerRy: outerRy,
                    startDeg: seg.0,
                    endDeg: seg.1
                )
                layerCtx.fill(path, with: .color(ringCore.opacity(0.80 * alpha * pulseBoost)))
            }
        }

        // 全12セグメント同時描画
        let midRx = innerRx + (outerRx - innerRx) * 0.16
        let midRy = innerRy + (outerRy - innerRy) * 0.16

        for seg in segments {
            let segPath = ellipticalAnnulusSegment(
                center: center,
                innerRx: innerRx,
                innerRy: innerRy,
                outerRx: outerRx,
                outerRy: outerRy,
                startDeg: seg.0,
                endDeg: seg.1
            )

            ctx.fill(
                segPath,
                with: .radialGradient(
                    Gradient(colors: [
                        ringHot.opacity(0.96 * alpha),
                        ringCore.opacity(0.94 * alpha),
                        ringCore.opacity(0.86 * alpha)
                    ]),
                    center: center,
                    startRadius: innerRy * 0.95,
                    endRadius: outerRx * 1.05
                )
            )

            let innerBevel = ellipticalAnnulusSegment(
                center: center,
                innerRx: innerRx,
                innerRy: innerRy,
                outerRx: midRx,
                outerRy: midRy,
                startDeg: seg.0 + 1.0,
                endDeg: seg.1 - 1.0
            )
            ctx.fill(innerBevel, with: .color(ringHighlight.opacity(0.38 * alpha)))

            ctx.stroke(
                segPath,
                with: .color(Color(red: 0.16, green: 0.02, blue: 0.24).opacity(0.62 * alpha)),
                lineWidth: 1.0 * uiScale
            )

            let midAngle = ((seg.0 + seg.1) * 0.5) * .pi / 180.0
            var notch = Path()
            notch.move(to: ellipsePoint(center: center, rx: outerRx * 0.91, ry: outerRy * 0.91, angle: midAngle))
            notch.addLine(to: ellipsePoint(center: center, rx: outerRx * 1.01, ry: outerRy * 1.01, angle: midAngle))
            ctx.stroke(
                notch,
                with: .color(Color(red: 0.14, green: 0.02, blue: 0.22).opacity(0.72 * alpha)),
                lineWidth: 1.3 * uiScale
            )
        }
    }

    /// 左右の三角ウィング（中心付近から左右両端へ段差なしで「シュッ」と一息に広がる連続展開）
    private func drawSideWingFlares(
        ctx: GraphicsContext,
        size: CGSize,
        center: CGPoint,
        innerRx: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        ringCore: Color,
        ringHot: Color,
        ringHighlight: Color,
        sweep: Double,
        sweepGlow: Double,
        alpha: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        guard sweep > 0.005 else { return }

        let w = size.width
        let h = size.height
        let p = CGFloat(sweep)
        let finalAlpha = alpha * min(1.0, sweep * 2.2) * (isActive ? (0.94 + 0.06 * breath) : 1.0)

        // リング外周の付け根から両端へ一気に伸びる（中央オーバルやリング内側へ線が入り込まない）
        let anchorDist = outerRx * 0.92
        let fullSpan = max(w * 0.52, outerRx * 1.56)
        let currentEdgeDist = anchorDist + (fullSpan - anchorDist) * p

        // 縦方向の開き：リング左右付け根から外側へ向かうにつれ直線的に扇状（台形状）に広がる
        let anchorTop = center.y - outerRy * 0.40
        let anchorBot = center.y + outerRy * 0.44
        let fullTop = h * 0.22
        let fullBot = h * 0.78

        let curTop = anchorTop + (fullTop - anchorTop) * p
        let curBot = anchorBot + (fullBot - anchorBot) * p

        func makeWing(isRight: Bool) -> Path {
            let dir: CGFloat = isRight ? 1.0 : -1.0
            let ix = center.x + dir * anchorDist
            let ox = center.x + dir * currentEdgeDist

            var path = Path()
            path.move(to: CGPoint(x: ix, y: anchorTop))
            path.addLine(to: CGPoint(x: ox, y: curTop))
            path.addLine(to: CGPoint(x: ox, y: curBot))
            path.addLine(to: CGPoint(x: ix, y: anchorBot))
            path.closeSubpath()
            return path
        }

        let leftWing = makeWing(isRight: false)
        let rightWing = makeWing(isRight: true)

        // 1. 柔らかなネオングロー
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 10.0 * uiScale))
            for wing in [leftWing, rightWing] {
                layerCtx.fill(wing, with: .color(ringCore.opacity(0.62 * finalAlpha)))
            }
        }

        // 2. 段差ゼロの滑らかな一枚ウィング本体
        ctx.fill(
            leftWing,
            with: .linearGradient(
                Gradient(colors: [
                    ringCore.opacity(0.70 * finalAlpha),
                    ringHot.opacity(0.92 * finalAlpha),
                    ringHighlight.opacity(0.84 * finalAlpha)
                ]),
                startPoint: CGPoint(x: center.x - currentEdgeDist, y: center.y),
                endPoint: CGPoint(x: center.x - anchorDist, y: center.y)
            )
        )
        ctx.fill(
            rightWing,
            with: .linearGradient(
                Gradient(colors: [
                    ringHighlight.opacity(0.84 * finalAlpha),
                    ringHot.opacity(0.92 * finalAlpha),
                    ringCore.opacity(0.70 * finalAlpha)
                ]),
                startPoint: CGPoint(x: center.x + anchorDist, y: center.y),
                endPoint: CGPoint(x: center.x + currentEdgeDist, y: center.y)
            )
        )

        // 3. 展開中の疾走ハイライト（シュッと広がる瞬間の淡いピンク白グロー）
        if sweepGlow > 0.01 {
            for wing in [leftWing, rightWing] {
                ctx.fill(wing, with: .color(ringHighlight.opacity(sweepGlow * finalAlpha)))
            }
        }

        // 4. 展開後の左右ディテールライン（画像左右のシャープな斜めパネル線）
        if sweep > 0.45 {
            let cutAlpha = min(1.0, (sweep - 0.45) / 0.45) * finalAlpha
            var wingCuts = Path()
            for dir in [-1.0, 1.0] as [CGFloat] {
                let cx1 = center.x + dir * outerRx * 1.02
                let cx2 = center.x + dir * (outerRx * 1.24)
                wingCuts.move(to: CGPoint(x: cx1, y: center.y - outerRy * 0.44))
                wingCuts.addLine(to: CGPoint(x: cx2, y: center.y - outerRy * 0.14))
                wingCuts.move(to: CGPoint(x: cx1, y: center.y + outerRy * 0.46))
                wingCuts.addLine(to: CGPoint(x: cx2, y: center.y + outerRy * 0.16))
            }
            ctx.stroke(
                wingCuts,
                with: .color(Color(red: 0.14, green: 0.02, blue: 0.22).opacity(0.66 * cutAlpha)),
                lineWidth: 1.4 * uiScale
            )
        }
    }

    /// 4本の対角放射ピンクホワイト光線（起動前ディバイダーと同じ角度でトランザム切替時に走る光芒）
    private func drawDiagonalEnergyRays(
        ctx: GraphicsContext,
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        ringHot: Color,
        ringHighlight: Color,
        intensity: Double,
        uiScale: CGFloat
    ) {
        var rays = Path()
        for deg in [-132.0, -48.0, 28.0, 152.0] {
            let rad = deg * .pi / 180.0
            rays.move(to: ellipsePoint(center: center, rx: outerRx * 0.98, ry: outerRy * 0.98, angle: rad))
            rays.addLine(to: ellipsePoint(center: center, rx: outerRx * 1.55, ry: outerRy * 1.55, angle: rad))
        }

        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 4.5 * uiScale))
            layerCtx.stroke(rays, with: .color(ringHot.opacity(0.85 * intensity)), lineWidth: 3.6 * uiScale)
        }
        ctx.stroke(rays, with: .color(ringHighlight.opacity(0.90 * intensity)), lineWidth: 1.5 * uiScale)
    }

    private func drawOuterCyanAndVioletArcs(
        ctx: GraphicsContext,
        center: CGPoint,
        outerRx: CGFloat,
        outerRy: CGFloat,
        accentColor: Color,
        violetColor: Color,
        alpha: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        let pulse = 0.88 + 0.12 * breath

        let cyanArcs: [(Double, Double, CGFloat, CGFloat)] = [
            (26, 70, 1.04, 1.18),
            (110, 154, 1.04, 1.18),
            (32, 62, 1.21, 1.27),
            (118, 148, 1.21, 1.27),
            (-56, -24, 1.05, 1.13),
            (-156, -124, 1.05, 1.13)
        ]

        func fullArc(_ arc: (Double, Double, CGFloat, CGFloat)) -> Path {
            ellipticalAnnulusSegment(
                center: center,
                innerRx: outerRx * arc.2,
                innerRy: outerRy * arc.2,
                outerRx: outerRx * arc.3,
                outerRy: outerRy * arc.3,
                startDeg: arc.0,
                endDeg: arc.1
            )
        }

        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 5.5 * uiScale))
            for arc in cyanArcs {
                layerCtx.fill(fullArc(arc), with: .color(accentColor.opacity(0.65 * alpha * pulse)))
            }
        }

        for arc in cyanArcs {
            ctx.fill(fullArc(arc), with: .color(accentColor.opacity(0.86 * alpha)))
        }

        let violetArcs: [(Double, Double, CGFloat, CGFloat)] = [
            (-48, -14, 1.22, 1.38),
            (-166, -132, 1.22, 1.38)
        ]
        for arc in violetArcs {
            ctx.fill(fullArc(arc), with: .color(violetColor.opacity(0.84 * alpha)))
        }
    }

    /// 右側面の3連インターロック角形モジュール（原作通りの非対称3ブロック：上＝幅広6角、中＝斜め長6角、下＝底辺沿い台形6角）
    /// 色相遷移：0.0(ミントアクア) → 0.5(濃ロイヤルパープル) → 1.0(原作の鮮やかなマゼンタ紫)
    private func drawRightHexModules(
        ctx: GraphicsContext,
        size: CGSize,
        hexPhase: Double,
        breath: Double,
        uiScale: CGFloat
    ) {
        let w = size.width
        let h = size.height

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: w * nx, y: h * ny)
        }

        // 1. 上段：右頬に収まる幅広の6角プレート（下辺が中段上辺と平行な「／」スリット）
        let topPoly = quadPath([
            pt(0.905, 0.365),
            pt(0.953, 0.440),
            pt(0.931, 0.558),
            pt(0.882, 0.618),
            pt(0.842, 0.568),
            pt(0.854, 0.445)
        ])

        // 2. 中段：バイザー右壁に沿って斜めに伸びる細長い6角プレート（左下辺が下段と平行な「＼」スリット）
        let midPoly = quadPath([
            pt(0.927, 0.580),
            pt(0.882, 0.848),
            pt(0.854, 0.878),
            pt(0.835, 0.798),
            pt(0.884, 0.638)
        ])

        // 3. 下段：バイザー底辺に沿って左へ広がる面取り6角プレート
        let botPoly = quadPath([
            pt(0.822, 0.808),
            pt(0.840, 0.886),
            pt(0.816, 0.946),
            pt(0.708, 0.946),
            pt(0.702, 0.902),
            pt(0.768, 0.808)
        ])

        let polys: [(Path, CGPoint)] = [
            (topPoly, pt(0.896, 0.495)),
            (midPoly, pt(0.880, 0.735)),
            (botPoly, pt(0.774, 0.885))
        ]

        // 2段階の色相変化：アクアミント → 濃ロイヤルパープル（遷移中間） → 原作の濃いマゼンタ紫（アクティブ）
        let fillTop: Color
        let fillBot: Color
        let rimGlow: Color
        if hexPhase < 0.5 {
            let p = hexPhase / 0.5
            fillTop = blendColor(from: (0.44, 1.00, 0.88), to: (0.42, 0.10, 0.80), progress: p)
            fillBot = blendColor(from: (0.30, 0.92, 0.80), to: (0.28, 0.05, 0.62), progress: p)
            rimGlow = blendColor(from: (0.65, 1.00, 0.94), to: (0.58, 0.22, 0.96), progress: p)
        } else {
            let p = (hexPhase - 0.5) / 0.5
            fillTop = blendColor(from: (0.42, 0.10, 0.80), to: (0.76, 0.10, 0.72), progress: p)
            fillBot = blendColor(from: (0.28, 0.05, 0.62), to: (0.56, 0.06, 0.58), progress: p)
            rimGlow = blendColor(from: (0.58, 0.22, 0.96), to: (0.98, 0.28, 0.86), progress: p)
        }

        // 背面のソフト発光（隙間からわずかに滲む原作の質感）
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 5.5 * uiScale))
            for (poly, _) in polys {
                layerCtx.fill(poly, with: .color(rimGlow.opacity(0.32 + 0.14 * (1.0 - hexPhase))))
            }
        }

        // 各ポリゴン本体＋暗色セパレーション輪郭＋微細テレメトリ線
        for (i, (poly, center)) in polys.enumerated() {
            let cellPulse = 0.92 + 0.08 * sin(breath * .pi + Double(i) * 0.9)

            ctx.fill(
                poly,
                with: .linearGradient(
                    Gradient(colors: [
                        fillTop.opacity(0.95 * cellPulse),
                        fillBot.opacity(0.92 * cellPulse)
                    ]),
                    startPoint: CGPoint(x: center.x - w * 0.04, y: center.y - h * 0.08),
                    endPoint: CGPoint(x: center.x + w * 0.04, y: center.y + h * 0.08)
                )
            )

            // わずかな内側ハイライト＆シャープな暗色ギャップエッジ
            ctx.stroke(
                poly,
                with: .color(Color(red: 0.04, green: 0.01, blue: 0.08).opacity(0.55)),
                lineWidth: 1.0 * uiScale
            )

            // セル内の微細なテレメトリ表記線（起動前は暗緑、起動後は暗紫でうっすら残る）
            let microColor = blendColor(
                from: (0.04, 0.30, 0.24),
                to: (0.26, 0.02, 0.28),
                progress: hexPhase
            )
            let spanX = w * 0.024
            let spanY = h * 0.022
            var micro = Path()
            micro.move(to: CGPoint(x: center.x - spanX * 0.8, y: center.y - spanY * 0.5))
            micro.addLine(to: CGPoint(x: center.x + spanX * 0.4, y: center.y - spanY * 0.5))
            micro.move(to: CGPoint(x: center.x - spanX * 0.3, y: center.y + spanY * 0.6))
            micro.addLine(to: CGPoint(x: center.x + spanX * 0.9, y: center.y + spanY * 0.6))
            ctx.stroke(
                micro,
                with: .color(microColor.opacity(0.42)),
                lineWidth: 1.1 * uiScale
            )
        }
    }

    private func drawLeftTechAccents(
        ctx: GraphicsContext,
        size: CGSize,
        violetColor: Color,
        cyanColor: Color,
        alpha: Double,
        uiScale: CGFloat
    ) {
        let w = size.width
        let h = size.height

        var bars = Path()
        for i in 0..<4 {
            let y = h * (0.62 + CGFloat(i) * 0.070)
            let xStart = w * (0.068 + CGFloat(i) * 0.018)
            let barW = w * (0.068 - CGFloat(i) * 0.008)
            bars.addRoundedRect(
                in: CGRect(x: xStart, y: y, width: barW, height: max(2.2, 3.0 * uiScale)),
                cornerSize: CGSize(width: 1.5 * uiScale, height: 1.5 * uiScale)
            )
        }
        ctx.fill(bars, with: .color(cyanColor.opacity(0.70 * alpha)))

        let leftCell = quadPath([
            CGPoint(x: w * 0.055, y: h * 0.16),
            CGPoint(x: w * 0.125, y: h * 0.12),
            CGPoint(x: w * 0.145, y: h * 0.21),
            CGPoint(x: w * 0.072, y: h * 0.25)
        ])
        ctx.fill(leftCell, with: .color(violetColor.opacity(0.48 * alpha)))
        ctx.stroke(leftCell, with: .color(violetColor.opacity(0.65 * alpha)), lineWidth: 1.0 * uiScale)
    }

    // MARK: - Geometry & Easing Helpers

    private func ellipsePoint(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(cos(angle)) * rx,
            y: center.y + CGFloat(sin(angle)) * ry
        )
    }

    private func ellipticalAnnulusSegment(
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        startDeg: Double,
        endDeg: Double,
        steps: Int = 20
    ) -> Path {
        let startRad = startDeg * .pi / 180.0
        let endRad = endDeg * .pi / 180.0
        var path = Path()

        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let a = startRad + (endRad - startRad) * frac
            let p = ellipsePoint(center: center, rx: outerRx, ry: outerRy, angle: a)
            if i == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        for i in (0...steps).reversed() {
            let frac = Double(i) / Double(steps)
            let a = startRad + (endRad - startRad) * frac
            let p = ellipsePoint(center: center, rx: innerRx, ry: innerRy, angle: a)
            path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    private func quadPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() {
            path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private func easeOutCubic(_ x: Double) -> Double {
        1.0 - pow(1.0 - x, 3)
    }

    private func easeOutQuart(_ x: Double) -> Double {
        1.0 - pow(1.0 - x, 4)
    }

    private func blendColor(
        from a: (Double, Double, Double),
        to b: (Double, Double, Double),
        progress p: Double
    ) -> Color {
        Color(
            red: a.0 + (b.0 - a.0) * p,
            green: a.1 + (b.1 - a.1) * p,
            blue: a.2 + (b.2 - a.2) * p
        )
    }
}

/// ガンダム00 公式ロゴ準拠のワイド＆高コントラスト（極太縦画×シャープ横画）の「TRANS-AM」ベクターロゴ
private struct TransAmLogoText: View {
    let charWidth: CGFloat
    let charHeight: CGFloat
    let spacing: CGFloat
    let coreColor: Color
    let highlightColor: Color
    let glowColor: Color
    let glowRadius: CGFloat
    let rimWidth: CGFloat

    private let characters: [Character] = Array("TRANS-AM")

    private var totalWidth: CGFloat {
        var sum: CGFloat = 0
        for (idx, ch) in characters.enumerated() {
            sum += widthFactor(for: ch) * charWidth
            if idx + 1 < characters.count {
                sum += spacing
            }
        }
        return max(1, sum)
    }

    var body: some View {
        let pad = glowRadius * 1.5 + rimWidth + 2
        let w = totalWidth
        let h = charHeight

        Canvas { ctx, _ in
            var fullPath = Path()
            var cursorX = pad
            let originY = pad

            for (idx, ch) in characters.enumerated() {
                let cw = widthFactor(for: ch) * charWidth
                addFilledGlyph(ch, in: CGRect(x: cursorX, y: originY, width: cw, height: h), to: &fullPath)
                cursorX += cw
                if idx + 1 < characters.count {
                    cursorX += spacing
                }
            }

            let fillStyle = FillStyle(eoFill: true)

            // 1. マゼンタネオングロー
            ctx.drawLayer { layerCtx in
                layerCtx.addFilter(.blur(radius: glowRadius))
                layerCtx.fill(fullPath, with: .color(glowColor.opacity(0.90)), style: fillStyle)
            }

            // 2. 本体グラデーション塗り
            ctx.fill(
                fullPath,
                with: .linearGradient(
                    Gradient(colors: [highlightColor, coreColor, glowColor]),
                    startPoint: CGPoint(x: pad, y: originY),
                    endPoint: CGPoint(x: pad, y: originY + h)
                ),
                style: fillStyle
            )

            // 3. エッジのシャープな極細ハイライトリム
            ctx.stroke(
                fullPath,
                with: .color(highlightColor.opacity(0.55)),
                style: StrokeStyle(lineWidth: rimWidth, lineJoin: .miter, miterLimit: 2.2)
            )
        }
        .frame(width: w + pad * 2, height: h + pad * 2)
        .padding(-pad)
    }

    private func widthFactor(for ch: Character) -> CGFloat {
        switch ch {
        case "T": return 0.96
        case "R": return 1.02
        case "A": return 1.04
        case "N": return 1.02
        case "S": return 1.00
        case "-": return 0.50
        case "M": return 1.16
        default: return 1.0
        }
    }

    private func addFilledGlyph(_ ch: Character, in rect: CGRect, to path: inout Path) {
        func p(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * nx, y: rect.minY + rect.height * ny)
        }

        func addPoly(_ pts: [(CGFloat, CGFloat)]) {
            guard let first = pts.first else { return }
            path.move(to: p(first.0, first.1))
            for pt in pts.dropFirst() {
                path.addLine(to: p(pt.0, pt.1))
            }
            path.closeSubpath()
        }

        switch ch {
        case "T":
            // 細い横バー＋極太の中央縦柱
            addPoly([
                (0.00, 0.00), (1.00, 0.00), (1.00, 0.155),
                (0.635, 0.155), (0.635, 1.00), (0.365, 1.00),
                (0.365, 0.155), (0.00, 0.155)
            ])

        case "R":
            // 極太左柱＋丸みを帯びたワイド上部ボウル＋浅いくびれから垂直に落ちる極太右脚
            path.move(to: p(0.00, 1.00))
            path.addLine(to: p(0.00, 0.00))
            path.addLine(to: p(0.75, 0.00))
            path.addCurve(to: p(0.985, 0.25), control1: p(0.92, 0.00), control2: p(0.985, 0.08))
            path.addLine(to: p(0.985, 0.30))
            path.addCurve(to: p(0.895, 0.495), control1: p(0.985, 0.42), control2: p(0.95, 0.47))
            path.addCurve(to: p(1.00, 0.68), control1: p(0.97, 0.525), control2: p(1.00, 0.58))
            path.addLine(to: p(1.00, 1.00))
            path.addLine(to: p(0.73, 1.00))
            path.addLine(to: p(0.73, 0.67))
            path.addCurve(to: p(0.64, 0.58), control1: p(0.73, 0.61), control2: p(0.70, 0.58))
            path.addLine(to: p(0.265, 0.58))
            path.addLine(to: p(0.265, 1.00))
            path.closeSubpath()

            // ボウル内側のカウンター（eoFill で抜く）
            path.move(to: p(0.265, 0.155))
            path.addLine(to: p(0.645, 0.155))
            path.addCurve(to: p(0.725, 0.25), control1: p(0.70, 0.155), control2: p(0.725, 0.19))
            path.addLine(to: p(0.725, 0.335))
            path.addCurve(to: p(0.645, 0.43), control1: p(0.725, 0.395), control2: p(0.70, 0.43))
            path.addLine(to: p(0.265, 0.43))
            path.closeSubpath()

        case "A":
            // 上に向かってわずかに絞られたアーチ肩のワイド A（極太脚＋低めの細横バー）
            path.move(to: p(0.00, 1.00))
            path.addLine(to: p(0.055, 0.30))
            path.addCurve(to: p(0.29, 0.00), control1: p(0.075, 0.08), control2: p(0.14, 0.00))
            path.addLine(to: p(0.71, 0.00))
            path.addCurve(to: p(0.945, 0.30), control1: p(0.86, 0.00), control2: p(0.925, 0.08))
            path.addLine(to: p(1.00, 1.00))
            path.addLine(to: p(0.735, 1.00))
            path.addLine(to: p(0.715, 0.685))
            path.addLine(to: p(0.285, 0.685))
            path.addLine(to: p(0.265, 1.00))
            path.closeSubpath()

            // 上部内側の抜きウィンドウ
            path.move(to: p(0.295, 0.535))
            path.addLine(to: p(0.31, 0.25))
            path.addCurve(to: p(0.39, 0.155), control1: p(0.315, 0.19), control2: p(0.34, 0.155))
            path.addLine(to: p(0.61, 0.155))
            path.addCurve(to: p(0.69, 0.25), control1: p(0.66, 0.155), control2: p(0.685, 0.19))
            path.addLine(to: p(0.705, 0.535))
            path.closeSubpath()

        case "N":
            // 極太の左右垂直柱＋力強い対角ストローク
            addPoly([
                (0.00, 1.00), (0.00, 0.00), (0.31, 0.00),
                (0.755, 0.72), (0.755, 0.00), (1.00, 0.00),
                (1.00, 1.00), (0.69, 1.00), (0.245, 0.28),
                (0.245, 1.00)
            ])

        case "S":
            // ワイドな角丸スクエア S（端をわずかに丸く落とし込んだ流線フォルム）
            path.move(to: p(0.77, 0.21))
            path.addCurve(to: p(0.69, 0.155), control1: p(0.76, 0.17), control2: p(0.73, 0.155))
            path.addLine(to: p(0.32, 0.155))
            path.addCurve(to: p(0.255, 0.23), control1: p(0.275, 0.155), control2: p(0.255, 0.18))
            path.addLine(to: p(0.255, 0.35))
            path.addCurve(to: p(0.32, 0.425), control1: p(0.255, 0.40), control2: p(0.275, 0.425))
            path.addLine(to: p(0.74, 0.425))
            path.addCurve(to: p(1.00, 0.68), control1: p(0.92, 0.425), control2: p(1.00, 0.50))
            path.addLine(to: p(1.00, 0.74))
            path.addCurve(to: p(0.74, 1.00), control1: p(1.00, 0.92), control2: p(0.92, 1.00))
            path.addLine(to: p(0.25, 1.00))
            path.addCurve(to: p(0.01, 0.79), control1: p(0.07, 1.00), control2: p(0.01, 0.93))
            path.addLine(to: p(0.23, 0.79))
            path.addCurve(to: p(0.31, 0.845), control1: p(0.24, 0.83), control2: p(0.27, 0.845))
            path.addLine(to: p(0.68, 0.845))
            path.addCurve(to: p(0.745, 0.77), control1: p(0.725, 0.845), control2: p(0.745, 0.82))
            path.addLine(to: p(0.745, 0.65))
            path.addCurve(to: p(0.68, 0.575), control1: p(0.745, 0.60), control2: p(0.725, 0.575))
            path.addLine(to: p(0.26, 0.575))
            path.addCurve(to: p(0.00, 0.32), control1: p(0.08, 0.575), control2: p(0.00, 0.50))
            path.addLine(to: p(0.00, 0.26))
            path.addCurve(to: p(0.26, 0.00), control1: p(0.00, 0.08), control2: p(0.08, 0.00))
            path.addLine(to: p(0.75, 0.00))
            path.addCurve(to: p(0.99, 0.21), control1: p(0.93, 0.00), control2: p(0.99, 0.07))
            path.closeSubpath()

        case "-":
            addPoly([
                (0.06, 0.445), (0.94, 0.445),
                (0.94, 0.595), (0.06, 0.595)
            ])

        case "M":
            // ワイドな極太左右脚＋底辺まで力強く落ちる中央 V
            addPoly([
                (0.00, 1.00), (0.00, 0.00), (0.255, 0.00),
                (0.50, 0.60), (0.745, 0.00), (1.00, 0.00),
                (1.00, 1.00), (0.775, 1.00), (0.775, 0.26),
                (0.555, 1.00), (0.445, 1.00), (0.225, 0.26),
                (0.225, 1.00)
            ])

        default:
            break
        }
    }
}

/// ガンダム00 コックピット表示準拠の角張ったシャープなベクター文字描画ビュー（00〜99 用）
private struct MechaVectorText: View {
    let text: String
    let charWidth: CGFloat
    let charHeight: CGFloat
    let spacing: CGFloat
    let strokeWidth: CGFloat
    let coreColor: Color
    let highlightColor: Color
    let glowColor: Color
    let glowRadius: CGFloat

    private var characters: [Character] { Array(text) }

    private var totalWidth: CGFloat {
        var sum: CGFloat = 0
        for (idx, ch) in characters.enumerated() {
            sum += widthFactor(for: ch) * charWidth
            if idx + 1 < characters.count {
                sum += spacing
            }
        }
        return max(1, sum)
    }

    var body: some View {
        let pad = glowRadius * 1.4 + strokeWidth
        let w = totalWidth
        let h = charHeight

        Canvas { ctx, _ in
            var fullPath = Path()
            var cursorX = pad
            let originY = pad

            for (idx, ch) in characters.enumerated() {
                let cw = widthFactor(for: ch) * charWidth
                addGlyph(ch, in: CGRect(x: cursorX, y: originY, width: cw, height: h), to: &fullPath)
                cursorX += cw
                if idx + 1 < characters.count {
                    cursorX += spacing
                }
            }

            let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 2.4)

            // 1. 鮮やかなマゼンタネオングロー
            ctx.drawLayer { layerCtx in
                layerCtx.addFilter(.blur(radius: glowRadius))
                layerCtx.stroke(fullPath, with: .color(glowColor.opacity(0.95)), style: StrokeStyle(
                    lineWidth: strokeWidth * 1.65,
                    lineCap: .butt,
                    lineJoin: .miter,
                    miterLimit: 2.4
                ))
            }

            // 2. 本体ピンクマゼンタストローク
            ctx.stroke(
                fullPath,
                with: .linearGradient(
                    Gradient(colors: [highlightColor, coreColor, glowColor]),
                    startPoint: CGPoint(x: pad, y: originY),
                    endPoint: CGPoint(x: pad, y: originY + h)
                ),
                style: style
            )

            // 3. 芯のシャープな極細ハイライト
            ctx.stroke(
                fullPath,
                with: .color(highlightColor.opacity(0.60)),
                style: StrokeStyle(lineWidth: max(0.7, strokeWidth * 0.36), lineCap: .butt, lineJoin: .miter, miterLimit: 2.4)
            )
        }
        .frame(width: w + pad * 2, height: h + pad * 2)
        .padding(-pad)
    }

    private func widthFactor(for ch: Character) -> CGFloat {
        switch ch {
        case "-": return 0.62
        case "1": return 0.65
        case "M": return 1.12
        default: return 1.0
        }
    }

    private func addGlyph(_ ch: Character, in rect: CGRect, to path: inout Path) {
        func p(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * nx, y: rect.minY + rect.height * ny)
        }

        func seg(_ pts: [(CGFloat, CGFloat)]) {
            guard let first = pts.first else { return }
            path.move(to: p(first.0, first.1))
            for pt in pts.dropFirst() {
                path.addLine(to: p(pt.0, pt.1))
            }
        }

        switch ch {
        case "T":
            seg([(0.0, 0.04), (1.0, 0.04)])
            seg([(0.50, 0.04), (0.50, 1.0)])

        case "R":
            seg([(0.06, 1.0), (0.06, 0.04), (0.78, 0.04), (0.94, 0.18), (0.94, 0.40), (0.78, 0.54), (0.06, 0.54)])
            seg([(0.58, 0.54), (0.94, 1.0)])

        case "A":
            seg([(0.04, 1.0), (0.38, 0.04), (0.62, 0.04), (0.96, 1.0)])
            seg([(0.19, 0.66), (0.81, 0.66)])

        case "N":
            seg([(0.06, 1.0), (0.06, 0.04), (0.14, 0.04), (0.86, 0.96), (0.94, 0.96), (0.94, 0.0)])

        case "S":
            seg([
                (0.94, 0.16), (0.80, 0.04), (0.18, 0.04), (0.06, 0.16),
                (0.06, 0.37), (0.18, 0.49), (0.82, 0.49), (0.94, 0.61),
                (0.94, 0.85), (0.80, 0.97), (0.18, 0.97), (0.06, 0.85)
            ])

        case "-":
            seg([(0.08, 0.52), (0.92, 0.52)])

        case "M":
            seg([(0.05, 1.0), (0.05, 0.04), (0.13, 0.04), (0.50, 0.72), (0.87, 0.04), (0.95, 0.04), (0.95, 1.0)])

        case "0":
            seg([
                (0.18, 0.04), (0.82, 0.04), (0.94, 0.16), (0.94, 0.85),
                (0.82, 0.97), (0.18, 0.97), (0.06, 0.85), (0.06, 0.16), (0.18, 0.04)
            ])

        case "1":
            seg([(0.24, 0.16), (0.56, 0.04), (0.56, 0.98)])
            seg([(0.18, 0.97), (0.90, 0.97)])

        case "2":
            seg([
                (0.06, 0.18), (0.18, 0.04), (0.82, 0.04), (0.94, 0.16),
                (0.94, 0.40), (0.82, 0.50), (0.18, 0.50), (0.06, 0.62),
                (0.06, 0.97), (0.96, 0.97)
            ])

        case "3":
            seg([
                (0.08, 0.04), (0.82, 0.04), (0.94, 0.16), (0.94, 0.38),
                (0.82, 0.49), (0.28, 0.49)
            ])
            seg([
                (0.82, 0.49), (0.94, 0.61), (0.94, 0.85), (0.82, 0.97), (0.08, 0.97)
            ])

        case "4":
            seg([(0.10, 0.04), (0.10, 0.54), (0.94, 0.54)])
            seg([(0.78, 0.04), (0.78, 1.0)])

        case "5":
            seg([
                (0.94, 0.04), (0.08, 0.04), (0.08, 0.48), (0.82, 0.48),
                (0.94, 0.60), (0.94, 0.85), (0.82, 0.97), (0.08, 0.97)
            ])

        case "6":
            seg([
                (0.92, 0.04), (0.18, 0.04), (0.06, 0.16), (0.06, 0.85),
                (0.18, 0.97), (0.82, 0.97), (0.94, 0.85), (0.94, 0.60),
                (0.82, 0.49), (0.06, 0.49)
            ])

        case "7":
            seg([(0.06, 0.04), (0.94, 0.04), (0.46, 1.0)])

        case "8":
            seg([
                (0.18, 0.04), (0.82, 0.04), (0.94, 0.16), (0.94, 0.38),
                (0.82, 0.49), (0.18, 0.49), (0.06, 0.38), (0.06, 0.16), (0.18, 0.04)
            ])
            seg([
                (0.18, 0.49), (0.06, 0.61), (0.06, 0.85), (0.18, 0.97),
                (0.82, 0.97), (0.94, 0.85), (0.94, 0.61), (0.82, 0.49)
            ])

        case "9":
            seg([
                (0.94, 0.49), (0.18, 0.49), (0.06, 0.38), (0.06, 0.16),
                (0.18, 0.04), (0.82, 0.04), (0.94, 0.16), (0.94, 0.85),
                (0.82, 0.97), (0.12, 0.97)
            ])

        default:
            break
        }
    }
}
