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
        /// 右端3連六角セルの遷移（0.0 = ミントアクア, 0.5 = 濃ロイヤルパープル, 1.0 = マゼンタ紫）
        let hexPhase: Double
        /// 中央「TRANS-AM / 99」の点灯不透明度・発光ブースト
        let titleOpacity: Double
        let titleGlowBoost: Double
        /// 上部「MODE/TASYS-05」の左→右スイープ表示進捗（0.0 -> 1.0）
        let modeRevealProgress: Double
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
                hexPhase: 0.0,
                titleOpacity: 0.0,
                titleGlowBoost: 0.0,
                modeRevealProgress: 0.0,
                ambientTime: ambient,
                counterValue: 0,
                didComplete: false
            )

        case let .activating(startedAt):
            let elapsed = max(0.0, now.timeIntervalSince(startedAt))
            let t = min(elapsed, Self.activationDuration)

            // 0.00 - 0.16s: 背景が深緑 → 深紫バイオレットへキレよく即時切替
            let bgTransAmMix = easeOutQuart(clamp(t / 0.16))

            // 0.00 - 0.30s: 逆Aレティクルはその場で即座に緑 → 青へ切り替わり、0.16s〜0.30sでスパッと消える
            let reticleBlueShift = easeOutQuart(clamp(t / 0.12))
            let reticleOpacity = 1.0 - easeOutCubic(clamp((t - 0.16) / 0.14))

            // 0.08 - 0.42s: 起動前の緑・黄弧がキビキビ退き、外周の緑が素早くシアンへ切替
            let standbyArcsOpacity = 1.0 - easeOutCubic(clamp((t - 0.08) / 0.30))
            let outerCyanShift = easeOutQuart(clamp((t - 0.16) / 0.30))

            // 0.04 - 0.34s: マゼンタリングが全体一斉にキレよく立ち上がる
            let magentaBloomOpacity = easeOutQuart(clamp((t - 0.04) / 0.28))
            let magentaRadialScale = 0.93 + 0.07 * CGFloat(easeOutQuart(clamp((t - 0.04) / 0.26)))

            // 0.18 - 0.44s: 左右の2連台形ウィングが中央から外側へスライドしつつ上下に広がる（0.26s）
            let rawSweep = clamp((t - 0.18) / 0.26)
            let wingSweep = easeOutQuart(rawSweep)
            let wingSweepGlow = 0.0

            // 右端3連角形: 0.0(アクア) → 0.5(濃パープル @ 0.20s) → 1.0(マゼンタ紫 @ 0.58s)
            let hexPhase = easeOutCubic(clamp(t / 0.58))

            // 0.22 - 0.36s: 逆Aの消滅と同時に「TRANS-AM」がスパッと点灯
            // 0.22 - 0.52s: カウンター00→99高速上昇と同期して「MODE/TASYS-05」が左から順にシュッと表示
            let titleOpacity = easeOutQuart(clamp((t - 0.22) / 0.14))
            let titleGlowBoost = exp(-pow((t - 0.34) / 0.11, 2)) * 0.55
            let counterP = easeOutCubic(clamp((t - 0.22) / 0.30))
            let counterValue = Int((counterP * 99.0).rounded())
            let modeRevealProgress = counterP

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
                hexPhase: hexPhase,
                titleOpacity: titleOpacity,
                titleGlowBoost: titleGlowBoost,
                modeRevealProgress: modeRevealProgress,
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
                hexPhase: 1.0,
                titleOpacity: 1.0,
                titleGlowBoost: 0.0,
                modeRevealProgress: 1.0,
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
            from: (0.24, 0.84, 0.30),
            to: (0.76, 0.12, 0.52),
            progress: state.bgTransAmMix
        )

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let uiScale = max(0.70, min(w / 480.0, h / 225.0))

            visorDisplayLayer(state: state, uiScale: uiScale)
                .frame(width: w, height: h)
                .clipShape(VisorScreenShape())
                .shadow(
                    color: glowTint.opacity(0.18 + state.bgTransAmMix * 0.24),
                    radius: 14 * uiScale
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

        // トランザム側パレット（白飛びせず、ほどよい発光感と深みを両立したトーン）
        let ringCoreColor = Color(red: 0.90, green: 0.16, blue: 0.62)
        let ringHotColor = Color(red: 0.96, green: 0.30, blue: 0.75)
        let ringHighlightColor = Color(red: 0.98, green: 0.46, blue: 0.82)
        let textPinkColor = Color(red: 0.94, green: 0.27, blue: 0.68)
        let textDeepColor = Color(red: 0.76, green: 0.15, blue: 0.54)
        // 外周弧：遷移中は緑が残り、次第に落ち着いたターコイズシアンへシフト
        let outerAccentColor = blendColor(
            from: (0.26, 0.90, 0.34),
            to: (0.13, 0.68, 0.70),
            progress: state.outerCyanShift
        )
        let outerVioletColor = blendColor(
            from: (0.38, 0.09, 0.76),
            to: (0.58, 0.11, 0.68),
            progress: state.hexPhase
        )

        // 背景色補間（起動前：深緑 -> 起動中/後：深紫ロイヤルインディゴ）
        let centerBgInner = blendColor(
            from: (0.028, 0.145, 0.042),
            to: (0.18, 0.075, 0.44),
            progress: bgMix
        )
        let centerBgOuter = blendColor(
            from: (0.009, 0.062, 0.018),
            to: (0.032, 0.013, 0.12),
            progress: bgMix
        )

        return ZStack {
            // 1. バイザー内部の60fps Canvas 描画
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let center = CGPoint(x: w * 0.50, y: h * 0.502)

                let outerRx = min(w * 0.320, h * 0.73)
                let outerRy = min(h * 0.432, w * 0.248)
                let innerRx = outerRx * 0.645
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

                    // 中央多角形モニターコア（上5・下2の内縁と、中心へ一段はみ出す左右ウィング内縁に沿う多角形）
                    let corePoly = centerCorePolygon(
                        center: center,
                        innerRx: sInnerRx,
                        innerRy: sInnerRy,
                        wingProtrude: min(1.0, state.wingSweep * 2.5)
                    )
                    ctx.fill(
                        corePoly,
                        with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 0.20, green: 0.10, blue: 0.50).opacity(0.95 * mAlpha),
                                Color(red: 0.045, green: 0.016, blue: 0.19).opacity(0.96 * mAlpha)
                            ]),
                            center: center,
                            startRadius: 4 * uiScale,
                            endRadius: sInnerRx * 1.10
                        )
                    )

                    // 中央コア背後にうっすら走る青紫の対角ライン（原作コックピット表示の奥行き表現）
                    var innerDiag = Path()
                    for deg in [-126.0, -54.0, 56.0, 124.0] {
                        let rad = deg * .pi / 180.0
                        innerDiag.move(to: ellipsePoint(center: center, rx: sInnerRx * 0.22, ry: sInnerRy * 0.22, angle: rad))
                        innerDiag.addLine(to: ellipsePoint(center: center, rx: sInnerRx * 0.98, ry: sInnerRy * 0.98, angle: rad))
                    }
                    ctx.drawLayer { layerCtx in
                        layerCtx.clip(to: corePoly)
                        layerCtx.addFilter(.blur(radius: 2.2 * uiScale))
                        layerCtx.stroke(
                            innerDiag,
                            with: .color(Color(red: 0.21, green: 0.36, blue: 0.90).opacity(0.28 * mAlpha)),
                            lineWidth: 2.1 * uiScale
                        )
                    }

                    // 左右マゼンタ2連台形ウィング（中央コアの外側から左右へスライドしつつ上下に広がる）
                    drawSideWingFlares(
                        ctx: ctx,
                        size: size,
                        center: center,
                        innerRx: sInnerRx,
                        innerRy: sInnerRy,
                        outerRx: sOuterRx,
                        outerRy: sOuterRy,
                        coreClipPoly: centerCorePolygon(
                            center: center,
                            innerRx: sInnerRx * 0.99,
                            innerRy: sInnerRy * 0.99,
                            wingProtrude: 1.0
                        ),
                        ringCore: ringCoreColor,
                        ringHot: ringHotColor,
                        ringHighlight: ringHighlightColor,
                        sweep: state.wingSweep,
                        sweepGlow: state.wingSweepGlow,
                        alpha: mAlpha,
                        breath: breath,
                        uiScale: uiScale
                    )

                    // メインの分割マゼンタ多角形リング（上5・下2の直線台形セグメント）
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

                    // 多角形内縁の控えめなソフトグロー（滑らかな楕円線ではなく、角張った内縁に沿ってわずかに滲む）
                    ctx.drawLayer { layerCtx in
                        layerCtx.addFilter(.blur(radius: 4.0 * uiScale))
                        layerCtx.stroke(corePoly, with: .color(ringHotColor.opacity(0.42 * mAlpha)), lineWidth: 1.5 * uiScale)
                    }
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
                ctx.stroke(scanlines, with: .color(Color.black.opacity(0.075)), lineWidth: 0.75 * min(1.5, uiScale))

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

            // 2. 中央多角形コアの「MODE/TASYS-05 / TRANS-AM / 99」シャープなメカニック角形タイポグラフィ（白抜きなし）
            if state.titleOpacity > 0.01 {
                GeometryReader { geo in
                    let centerX = geo.size.width * 0.50
                    let centerY = geo.size.height * 0.504

                    VStack(spacing: 3.5 * uiScale) {
                        Text("MODE/TASYS-05")
                            .font(.system(size: 6.6 * uiScale, weight: .semibold, design: .monospaced))
                            .tracking(1.4 * uiScale)
                            .foregroundStyle(textPinkColor.opacity(0.80))
                            .mask {
                                leftToRightRevealMask(progress: state.modeRevealProgress)
                            }

                        // 原作コックピット表示準拠の均等線幅ジオメトリックサンセリフ「TRANS-AM」ベクターロゴ
                        TransAmLogoText(
                            charWidth: 16.4 * uiScale,
                            charHeight: 20.2 * uiScale,
                            spacing: 2.4 * uiScale,
                            coreColor: textPinkColor,
                            highlightColor: textPinkColor,
                            glowColor: textDeepColor,
                            glowRadius: (4.8 + CGFloat(breath) * 1.4 + CGFloat(state.titleGlowBoost) * 4.0) * uiScale,
                            rimWidth: 0
                        )

                        bottomTransAmReadout(
                            state: state,
                            ringHighlight: textPinkColor,
                            ringHot: textPinkColor,
                            ringCore: textDeepColor,
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
        }
    }

    @ViewBuilder
    private func leftToRightRevealMask(progress: Double) -> some View {
        let p = clamp(progress)
        if p <= 0.001 {
            Color.clear
        } else if p >= 0.999 {
            Color.white
        } else {
            let feather = 0.12
            let head = p * (1.0 + feather)
            let tail = max(0.0, head - feather)
            let startAlpha = clamp(head / feather)
            let endAlpha = clamp((head - 1.0) / feather)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(startAlpha), location: 0.0),
                    .init(color: .white.opacity(startAlpha), location: tail),
                    .init(color: .white.opacity(endAlpha), location: min(1.0, head)),
                    .init(color: .white.opacity(endAlpha), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
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
                    charWidth: 6.8 * uiScale,
                    charHeight: 9.4 * uiScale,
                    spacing: 3.0 * uiScale,
                    strokeWidth: 1.45 * uiScale,
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

    private static let sideWingDiagDeg: Double = 26.5
    /// 左右ウィングが上下リング内縁（1.00）より中心側へはみ出す比率
    private static let sideWingInnerDiagScale: CGFloat = 0.845
    private static let sideWingInnerMidScale: CGFloat = 0.815

    /// 中心の多角形モニター窓（上5・下2の直線内縁と、左右ウィングの中心側へのはみ出し段差で構成）
    private func centerCorePolygon(
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        wingProtrude: Double
    ) -> Path {
        func ePt(_ deg: Double, rxScale: CGFloat = 1.0, ryScale: CGFloat = 1.0) -> CGPoint {
            ellipsePoint(center: center, rx: innerRx * rxScale, ry: innerRy * ryScale, angle: deg * .pi / 180.0)
        }
        let wp = CGFloat(clamp(wingProtrude))
        let diagScale: CGFloat = 1.0 + (Self.sideWingInnerDiagScale - 1.0) * wp
        let midScale: CGFloat = 1.0 + (Self.sideWingInnerMidScale - 1.0) * wp
        let d = Self.sideWingDiagDeg

        return quadPath([
            ePt(-150.5),
            ePt(-120.0),
            ePt(-104.5),
            ePt(-75.5),
            ePt(-60.0),
            ePt(-29.5),
            ePt(-d, rxScale: diagScale, ryScale: diagScale),
            ePt(0.0, rxScale: midScale),
            ePt(d, rxScale: diagScale, ryScale: diagScale),
            ePt(29.5),
            ePt(75.5),
            ePt(104.5),
            ePt(150.5),
            ePt(180.0 - d, rxScale: diagScale, ryScale: diagScale),
            ePt(180.0, rxScale: midScale),
            ePt(-180.0 + d, rxScale: diagScale, ryScale: diagScale)
        ])
    }

    /// 角度と厚み比 rFrac (0.0 = 内縁, 1.0 = 基準外縁, >1.0 = バリ突起) から座標を計算
    private func ringPoint(
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        deg: Double,
        rFrac: CGFloat
    ) -> CGPoint {
        let rx = innerRx + (outerRx - innerRx) * rFrac
        let ry = innerRy + (outerRy - innerRy) * rFrac
        return ellipsePoint(center: center, rx: rx, ry: ry, angle: deg * .pi / 180.0)
    }

    /// 内縁・外縁とも完全直線で構成された多角形パーツ（サイズ差・段差・バリ突起・内角面取り対応）
    private func facetedCustomPolygon(
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        vertices: [(deg: Double, rFrac: CGFloat)]
    ) -> Path {
        let pts = vertices.map {
            ringPoint(
                center: center,
                innerRx: innerRx,
                innerRy: innerRy,
                outerRx: outerRx,
                outerRy: outerRy,
                deg: $0.deg,
                rFrac: $0.rFrac
            )
        }
        return quadPath(pts)
    }

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
        // 原作準拠の不均一・直線多角形パーツ構成（外縁も円形ではなく直線＋段差＋バリ突起あり）：
        // 上 5 パーツ（1:左肩[低+左端バリ], 2:左中[細+左端長バリ], 3:中央上[幅広・最厚], 4:右中[細+右端長バリ], 5:右肩[低+右端バリ]）
        // 下 2 パーツ（6:左下[スリム直線+左端バリ], 7:右下[スリム直線+右端バリ]）
        let partSpecs: [(outer: [(deg: Double, rFrac: CGFloat)], bevelRange: (Double, Double))] = [
            // 1. 左肩（広め・やや低め・左台形境界側にシャープな細いバリ突起）
            (
                outer: [
                    (-150.5, 0.08),
                    (-150.5, 1.09), // 左端の細いバリ突起
                    (-148.2, 1.09),
                    (-148.2, 0.86), // 本体外縁へ一段落ちる
                    (-122.0, 0.91),
                    (-122.0, 0.08),
                    (-123.4, 0.00), // 内側角面取り
                    (-149.1, 0.00)
                ],
                bevelRange: (-149.1, -123.4)
            ),
            // 2. 左中（細め・左側外端にスッと伸びるシャープなバリ突起）
            (
                outer: [
                    (-119.5, 0.08),
                    (-119.5, 1.14), // 左側の細いバリ突起
                    (-117.1, 1.14),
                    (-117.1, 0.98), // 本体は中央上よりわずかに低い段差
                    (-107.0, 1.00),
                    (-107.0, 0.08),
                    (-108.0, 0.00),
                    (-118.5, 0.00)
                ],
                bevelRange: (-118.5, -108.0)
            ),
            // 3. 中央上（ワイド＆一番厚みのあるフラット水平トップ）
            (
                outer: [
                    (-104.5, 0.08),
                    (-104.5, 1.06),
                    (-75.5,  1.06),
                    (-75.5,  0.08),
                    (-77.0,  0.00),
                    (-103.0, 0.00)
                ],
                bevelRange: (-103.0, -77.0)
            ),
            // 4. 右中（2と左右対称・右側外端にスッと伸びるシャープなバリ突起）
            (
                outer: [
                    (-73.0,  0.08),
                    (-73.0,  1.00),
                    (-62.9,  0.98),
                    (-62.9,  1.14), // 右側の細いバリ突起
                    (-60.5,  1.14),
                    (-60.5,  0.08),
                    (-61.5,  0.00),
                    (-72.0,  0.00)
                ],
                bevelRange: (-72.0, -61.5)
            ),
            // 5. 右肩（1と左右対称・やや低め・右台形境界側にシャープな細いバリ突起）
            (
                outer: [
                    (-58.0,  0.08),
                    (-58.0,  0.91),
                    (-31.8,  0.86),
                    (-31.8,  1.09), // 右端の細いバリ突起
                    (-29.5,  1.09),
                    (-29.5,  0.08),
                    (-30.9,  0.00),
                    (-56.6,  0.00)
                ],
                bevelRange: (-56.6, -30.9)
            ),
            // 6. 右下（スリムな直線ポリゴン・右台形境界側に細いバリ突起）
            (
                outer: [
                    (29.5,   0.06),
                    (29.5,   0.95), // 右端の細いバリ突起
                    (31.8,   0.95),
                    (31.8,   0.67), // スリムな外縁へ一段落ちる
                    (54.0,   0.65),
                    (75.5,   0.61),
                    (75.5,   0.00),
                    (30.8,   0.00)
                ],
                bevelRange: (30.8, 75.0)
            ),
            // 7. 左下（6と左右対称・スリムな直線ポリゴン・左台形境界側に細いバリ突起）
            (
                outer: [
                    (104.5,  0.00),
                    (104.5,  0.61),
                    (126.0,  0.65),
                    (148.2,  0.67),
                    (148.2,  0.95), // 左端の細いバリ突起
                    (150.5,  0.95),
                    (150.5,  0.06),
                    (149.2,  0.00)
                ],
                bevelRange: (105.0, 149.2)
            )
        ]

        let pulseBoost: Double = isActive ? (0.94 + 0.06 * breath) : 1.0
        let builtPaths: [Path] = partSpecs.map { spec in
            facetedCustomPolygon(
                center: center,
                innerRx: innerRx,
                innerRy: innerRy,
                outerRx: outerRx,
                outerRy: outerRy,
                vertices: spec.outer
            )
        }

        // 全体一斉のネオングロー層（白飛びしない落ち着いた発光）
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 12.0 * uiScale))
            for path in builtPaths {
                layerCtx.fill(path, with: .color(ringCore.opacity(0.64 * alpha * pulseBoost)))
            }
        }

        // 全 7 パーツ同時描画（上部中央の縦棒ノッチなし・各パーツ固有の段差とバリを表現）
        for (idx, segPath) in builtPaths.enumerated() {
            let bevelRange = partSpecs[idx].bevelRange

            ctx.fill(
                segPath,
                with: .radialGradient(
                    Gradient(colors: [
                        ringHot.opacity(0.84 * alpha),
                        ringCore.opacity(0.78 * alpha),
                        ringHot.opacity(0.70 * alpha)
                    ]),
                    center: center,
                    startRadius: innerRy * 0.90,
                    endRadius: max(outerRx, outerRy) * 1.18
                )
            )

            // 内縁の控えめな直線ベベル帯
            let innerBevel = facetedCustomPolygon(
                center: center,
                innerRx: innerRx,
                innerRy: innerRy,
                outerRx: outerRx,
                outerRy: outerRy,
                vertices: [
                    (bevelRange.0, 0.12),
                    (bevelRange.1, 0.12),
                    (bevelRange.1, 0.00),
                    (bevelRange.0, 0.00)
                ]
            )
            ctx.fill(innerBevel, with: .color(ringHighlight.opacity(0.21 * alpha)))

            // 暗紫のシャープなパネル輪郭（段差とバリのエッジをくっきり見せる）
            ctx.stroke(
                segPath,
                with: .color(Color(red: 0.16, green: 0.02, blue: 0.26).opacity(0.68 * alpha)),
                lineWidth: 1.0 * uiScale
            )
        }
    }

    /// 左右の上下 2 連台形コンポーネント（中心コア際から外側へスライドしつつ上下に開く展開演出）
    private func drawSideWingFlares(
        ctx: GraphicsContext,
        size: CGSize,
        center: CGPoint,
        innerRx: CGFloat,
        innerRy: CGFloat,
        outerRx: CGFloat,
        outerRy: CGFloat,
        coreClipPoly: Path,
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
        let p = CGFloat(sweep)
        let finalAlpha = alpha * min(1.0, sweep * 3.0) * (isActive ? (0.94 + 0.06 * breath) : 1.0)

        // 中央のシャープな水平分割線で上下 2 つの台形に分離
        let splitHalfGap = max(1.0, 1.35 * uiScale)
        // 上 5 / 下 2 セグメントの端（±29.5°, ±150.5°）と均一ギャップで揃える斜め辺角度
        let diagRad = Self.sideWingDiagDeg * .pi / 180.0
        let cosDiag = CGFloat(cos(diagRad))
        let sinDiag = CGFloat(sin(diagRad))

        // 上下リング内縁（1.00）より中心側へ一段はみ出させ、原作同様の段差シルエットを作る
        let innerMidX = innerRx * Self.sideWingInnerMidScale
        let innerDiagX = cosDiag * innerRx * Self.sideWingInnerDiagScale
        let innerDiagY = sinDiag * innerRy * Self.sideWingInnerDiagScale

        // リング外周の肩（ピーク点）までは上5・下2セグメントと平行な放射角度で進み、
        // そこから画面両端へ向かって中央水平線側へキュッと狭まる（テーパーする）形状
        let peakX = cosDiag * outerRx * 0.98
        let peakY = sinDiag * outerRy * 0.94

        let fullSpanX = max(w * 0.55, outerRx * 1.68)
        let fullTipY = outerRy * 0.24

        // 内→外への水平スライド（dx が内側シフトから 0 へ戻る）＋ 上下への広がり（openScaleY: 0.56 -> 1.00）
        let slideDistance = outerRx * 0.92
        let slideInward = (1.0 - p) * slideDistance
        let openScaleY: CGFloat = 0.56 + 0.44 * p
        let curInnerDiagY = innerDiagY * openScaleY
        let curPeakY = peakY * openScaleY
        let curTipY = fullTipY * openScaleY

        func makeTrapezoid(isRight: Bool, isUpper: Bool) -> Path {
            let dir: CGFloat = isRight ? 1.0 : -1.0
            let ySign: CGFloat = isUpper ? -1.0 : 1.0
            // 最初は中心寄り（-dir * slideInward）に控えており、外側（dir方向）へスライドアウト
            let dx = -dir * slideInward

            return quadPath([
                CGPoint(x: center.x + dir * innerMidX + dx, y: center.y + ySign * splitHalfGap),
                CGPoint(x: center.x + dir * innerDiagX + dx, y: center.y + ySign * curInnerDiagY),
                CGPoint(x: center.x + dir * peakX + dx, y: center.y + ySign * curPeakY),
                CGPoint(x: center.x + dir * fullSpanX + dx, y: center.y + ySign * curTipY),
                CGPoint(x: center.x + dir * fullSpanX + dx, y: center.y + ySign * splitHalfGap)
            ])
        }

        func makeInnerBevel(isRight: Bool, isUpper: Bool) -> Path {
            let dir: CGFloat = isRight ? 1.0 : -1.0
            let ySign: CGFloat = isUpper ? -1.0 : 1.0
            let dx = -dir * slideInward
            let bevelFrac: CGFloat = 0.13
            let bMidX = innerMidX + (outerRx - innerMidX) * bevelFrac
            let bDiagX = innerDiagX + (cosDiag * outerRx - innerDiagX) * bevelFrac
            let bDiagY = (innerDiagY + (sinDiag * outerRy - innerDiagY) * bevelFrac) * openScaleY

            return quadPath([
                CGPoint(x: center.x + dir * innerMidX + dx, y: center.y + ySign * splitHalfGap),
                CGPoint(x: center.x + dir * innerDiagX + dx, y: center.y + ySign * curInnerDiagY),
                CGPoint(x: center.x + dir * bDiagX + dx, y: center.y + ySign * bDiagY),
                CGPoint(x: center.x + dir * bMidX + dx, y: center.y + ySign * splitHalfGap)
            ])
        }

        let leftUpper = makeTrapezoid(isRight: false, isUpper: true)
        let leftLower = makeTrapezoid(isRight: false, isUpper: false)
        let rightUpper = makeTrapezoid(isRight: true, isUpper: true)
        let rightLower = makeTrapezoid(isRight: true, isUpper: false)
        let allTrapezoids = [leftUpper, leftLower, rightUpper, rightLower]

        let leftGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                ringCore.opacity(0.68 * finalAlpha),
                ringHot.opacity(0.75 * finalAlpha),
                ringCore.opacity(0.84 * finalAlpha)
            ]),
            startPoint: CGPoint(x: center.x - fullSpanX + slideInward, y: center.y),
            endPoint: CGPoint(x: center.x - innerMidX + slideInward, y: center.y)
        )
        let rightGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                ringCore.opacity(0.84 * finalAlpha),
                ringHot.opacity(0.75 * finalAlpha),
                ringCore.opacity(0.64 * finalAlpha)
            ]),
            startPoint: CGPoint(x: center.x + innerMidX - slideInward, y: center.y),
            endPoint: CGPoint(x: center.x + fullSpanX - slideInward, y: center.y)
        )

        func drawWings(into targetCtx: GraphicsContext) {
            // 1. 柔らかなネオングロー
            targetCtx.drawLayer { layerCtx in
                layerCtx.addFilter(.blur(radius: 10.5 * uiScale))
                for trap in allTrapezoids {
                    layerCtx.fill(trap, with: .color(ringCore.opacity(0.58 * finalAlpha)))
                }
            }

            // 2. 左右それぞれ上下 2 連の台形本体塗り（スライド移動に追従する半透明マゼンタピンク）
            targetCtx.fill(leftUpper, with: leftGrad)
            targetCtx.fill(leftLower, with: leftGrad)
            targetCtx.fill(rightUpper, with: rightGrad)
            targetCtx.fill(rightLower, with: rightGrad)

            // 3. 中央オーバル際の内縁ベベル（上 5・下 2 セグメントとの一体感）
            for (isRight, isUpper) in [(false, true), (false, false), (true, true), (true, false)] {
                targetCtx.fill(
                    makeInnerBevel(isRight: isRight, isUpper: isUpper),
                    with: .color(ringHighlight.opacity(0.19 * finalAlpha))
                )
            }

            // 4. 展開中の疾走ハイライト
            if sweepGlow > 0.01 {
                for trap in allTrapezoids {
                    targetCtx.fill(trap, with: .color(ringHighlight.opacity(sweepGlow * finalAlpha)))
                }
            }

            // 5. 各台形のシャープな暗紫アウトライン（上下台形間の水平分割線を繊細かつ明瞭に保つ）
            for trap in allTrapezoids {
                targetCtx.stroke(
                    trap,
                    with: .color(Color(red: 0.22, green: 0.02, blue: 0.30).opacity(0.58 * finalAlpha)),
                    lineWidth: 0.95 * uiScale
                )
            }
        }

        // スライド中は中央コアの内側（TRANS-AM 領域）にはみ出さないよう外側のみにクリップ
        if p < 0.995 {
            var outerClip = Path(CGRect(origin: .zero, size: size))
            outerClip.addPath(coreClipPoly)
            ctx.drawLayer { clippedCtx in
                clippedCtx.clip(to: outerClip, style: FillStyle(eoFill: true))
                drawWings(into: clippedCtx)
            }
        } else {
            drawWings(into: ctx)
        }
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

        let deepRoyalBlue = Color(red: 0.04, green: 0.14, blue: 0.68)
        let midCerulean = Color(red: 0.06, green: 0.44, blue: 0.72)

        func lowerGradientShading(start: CGPoint, end: CGPoint, opacityScale: Double) -> GraphicsContext.Shading {
            .linearGradient(
                Gradient(stops: [
                    .init(color: deepRoyalBlue.opacity(0.92 * opacityScale), location: 0.00),
                    .init(color: deepRoyalBlue.opacity(0.88 * opacityScale), location: 0.16),
                    .init(color: midCerulean.opacity(0.88 * opacityScale), location: 0.42),
                    .init(color: accentColor.opacity(0.86 * opacityScale), location: 0.72),
                    .init(color: accentColor.opacity(0.88 * opacityScale), location: 1.00)
                ]),
                startPoint: start,
                endPoint: end
            )
        }

        // 1. 下部セット（内側弧は半透明ピンクの下部パーツ背面へ潜り込み、外端の濃青 → 中央ノッチ側のターコイズシアンへ控えめにグラデーション）
        let lowerRightPaths: [Path] = [
            fullArc((31, 74, 0.82, 0.98)),
            fullArc((31, 74, 1.02, 1.11)),
            fullArc((72, 74, 0.87, 1.11))
        ]
        let lowerLeftPaths: [Path] = [
            fullArc((106, 149, 0.82, 0.98)),
            fullArc((106, 149, 1.02, 1.11)),
            fullArc((106, 108, 0.87, 1.11))
        ]

        let rightGradStart = ellipsePoint(center: center, rx: outerRx * 1.12, ry: outerRy * 1.12, angle: 28.0 * .pi / 180.0)
        let rightGradEnd = ellipsePoint(center: center, rx: outerRx * 0.84, ry: outerRy * 0.84, angle: 72.0 * .pi / 180.0)
        let leftGradStart = ellipsePoint(center: center, rx: outerRx * 1.12, ry: outerRy * 1.12, angle: 152.0 * .pi / 180.0)
        let leftGradEnd = ellipsePoint(center: center, rx: outerRx * 0.84, ry: outerRy * 0.84, angle: 108.0 * .pi / 180.0)

        let lowerRightFill = lowerGradientShading(start: rightGradStart, end: rightGradEnd, opacityScale: 0.66 * alpha)
        let lowerLeftFill = lowerGradientShading(start: leftGradStart, end: leftGradEnd, opacityScale: 0.66 * alpha)
        let lowerRightGlow = lowerGradientShading(start: rightGradStart, end: rightGradEnd, opacityScale: 0.26 * alpha * pulse)
        let lowerLeftGlow = lowerGradientShading(start: leftGradStart, end: leftGradEnd, opacityScale: 0.26 * alpha * pulse)

        // 2. サイド側セット（下部弧と半径を揃えつつ斜め切れ目で分離し、全体を抑えめにしてピンクウィングを主役に保つ）
        let sideSpanY = outerRy * 0.62
        let sideArcShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: deepRoyalBlue.opacity(0.36 * alpha), location: 0.00),
                .init(color: midCerulean.opacity(0.24 * alpha), location: 0.28),
                .init(color: deepRoyalBlue.opacity(0.18 * alpha), location: 0.50),
                .init(color: midCerulean.opacity(0.38 * alpha), location: 0.74),
                .init(color: deepRoyalBlue.opacity(0.62 * alpha), location: 1.00)
            ]),
            startPoint: CGPoint(x: center.x, y: center.y - sideSpanY),
            endPoint: CGPoint(x: center.x, y: center.y + sideSpanY)
        )
        let sideArcGlowShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: deepRoyalBlue.opacity(0.14 * alpha * pulse), location: 0.00),
                .init(color: midCerulean.opacity(0.10 * alpha * pulse), location: 0.28),
                .init(color: deepRoyalBlue.opacity(0.08 * alpha * pulse), location: 0.50),
                .init(color: midCerulean.opacity(0.16 * alpha * pulse), location: 0.74),
                .init(color: deepRoyalBlue.opacity(0.24 * alpha * pulse), location: 1.00)
            ]),
            startPoint: CGPoint(x: center.x, y: center.y - sideSpanY),
            endPoint: CGPoint(x: center.x, y: center.y + sideSpanY)
        )

        let builtSideArcs: [Path] = [
            fullArc((-24, 27, 0.84, 0.98)),
            fullArc((-24, 27, 1.02, 1.11)),
            fullArc((153, 204, 0.84, 0.98)),
            fullArc((153, 204, 1.02, 1.11))
        ]

        // 3. 上部セット（下部よりスリム＆控えめな輝度で、上部ピンクパーツの背面からうっすら透けつつ外縁に細く添える）
        let upperRightPaths: [Path] = [
            fullArc((-68, -31, 0.85, 0.98)),
            fullArc((-56, -32, 1.01, 1.08))
        ]
        let upperLeftPaths: [Path] = [
            fullArc((-149, -112, 0.85, 0.98)),
            fullArc((-148, -124, 1.01, 1.08))
        ]

        let upperRightGradStart = ellipsePoint(center: center, rx: outerRx * 1.10, ry: outerRy * 1.10, angle: -28.0 * .pi / 180.0)
        let upperRightGradEnd = ellipsePoint(center: center, rx: outerRx * 0.85, ry: outerRy * 0.85, angle: -64.0 * .pi / 180.0)
        let upperLeftGradStart = ellipsePoint(center: center, rx: outerRx * 1.10, ry: outerRy * 1.10, angle: -152.0 * .pi / 180.0)
        let upperLeftGradEnd = ellipsePoint(center: center, rx: outerRx * 0.85, ry: outerRy * 0.85, angle: -116.0 * .pi / 180.0)

        let upperRightFill = lowerGradientShading(start: upperRightGradStart, end: upperRightGradEnd, opacityScale: 0.50 * alpha)
        let upperLeftFill = lowerGradientShading(start: upperLeftGradStart, end: upperLeftGradEnd, opacityScale: 0.50 * alpha)
        let upperRightGlow = lowerGradientShading(start: upperRightGradStart, end: upperRightGradEnd, opacityScale: 0.18 * alpha * pulse)
        let upperLeftGlow = lowerGradientShading(start: upperLeftGradStart, end: upperLeftGradEnd, opacityScale: 0.18 * alpha * pulse)

        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 4.5 * uiScale))
            for path in lowerRightPaths {
                layerCtx.fill(path, with: lowerRightGlow)
            }
            for path in lowerLeftPaths {
                layerCtx.fill(path, with: lowerLeftGlow)
            }
            for path in builtSideArcs {
                layerCtx.fill(path, with: sideArcGlowShading)
            }
            for path in upperRightPaths {
                layerCtx.fill(path, with: upperRightGlow)
            }
            for path in upperLeftPaths {
                layerCtx.fill(path, with: upperLeftGlow)
            }
        }

        for path in lowerRightPaths {
            ctx.fill(path, with: lowerRightFill)
        }
        for path in lowerLeftPaths {
            ctx.fill(path, with: lowerLeftFill)
        }
        for path in builtSideArcs {
            ctx.fill(path, with: sideArcShading)
        }
        for path in upperRightPaths {
            ctx.fill(path, with: upperRightFill)
        }
        for path in upperLeftPaths {
            ctx.fill(path, with: upperLeftFill)
        }

        // 右上・左上の半透明パープル外周ブロック弧（台形上辺より上へスッキリ収める）
        let violetArcs: [(Double, Double, CGFloat, CGFloat)] = [
            (-52, -25, 1.20, 1.38),
            (-155, -128, 1.20, 1.38)
        ]
        for arc in violetArcs {
            ctx.fill(fullArc(arc), with: .color(violetColor.opacity(0.56 * alpha)))
        }
    }

    /// 右側面の3連インターロック角形パネル（半透明ガラスのような透け感を持つ非対称3ブロック）
    /// 色相遷移：0.0(ミントアクア) → 0.5(濃ロイヤルパープル) → 1.0(原作の透け感あるマゼンタ紫)
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
            pt(0.892, 0.448),
            pt(0.944, 0.514),
            pt(0.924, 0.624),
            pt(0.874, 0.672),
            pt(0.830, 0.618),
            pt(0.844, 0.508)
        ])

        // 2. 中段：バイザー右壁に沿って斜めに伸びる細長い5角プレート（左下辺が下段と平行な「＼」スリット）
        let midPoly = quadPath([
            pt(0.920, 0.646),
            pt(0.880, 0.860),
            pt(0.850, 0.890),
            pt(0.822, 0.810),
            pt(0.874, 0.694)
        ])

        // 3. 下段：バイザー底辺に沿って左へ広がる面取り6角プレート
        let botPoly = quadPath([
            pt(0.808, 0.828),
            pt(0.836, 0.902),
            pt(0.810, 0.958),
            pt(0.706, 0.958),
            pt(0.696, 0.912),
            pt(0.758, 0.828)
        ])

        let polys: [(Path, CGPoint)] = [
            (topPoly, pt(0.894, 0.562)),
            (midPoly, pt(0.878, 0.774)),
            (botPoly, pt(0.768, 0.900))
        ]

        // 2段階の色相変化：アクアミント → 濃ロイヤルパープル（遷移中間） → 原作の透け感あるディープマゼンタ紫（アクティブ）
        let fillTop: Color
        let fillBot: Color
        let rimGlow: Color
        if hexPhase < 0.5 {
            let p = hexPhase / 0.5
            fillTop = blendColor(from: (0.42, 0.98, 0.86), to: (0.46, 0.12, 0.82), progress: p)
            fillBot = blendColor(from: (0.26, 0.88, 0.76), to: (0.28, 0.05, 0.60), progress: p)
            rimGlow = blendColor(from: (0.66, 1.00, 0.94), to: (0.64, 0.24, 0.96), progress: p)
        } else {
            let p = (hexPhase - 0.5) / 0.5
            fillTop = blendColor(from: (0.46, 0.12, 0.82), to: (0.66, 0.13, 0.68), progress: p)
            fillBot = blendColor(from: (0.28, 0.05, 0.60), to: (0.42, 0.06, 0.52), progress: p)
            rimGlow = blendColor(from: (0.64, 0.24, 0.96), to: (0.84, 0.26, 0.80), progress: p)
        }

        // トランザム時は背後の右台形や暗背景が透けるシアーな半透明（ベタ塗りせず、かつ紫の色味はしっかり残す）
        let topAlpha = 0.68 - 0.12 * hexPhase   // standby: 0.68 -> active: 0.56
        let botAlpha = 0.54 - 0.12 * hexPhase   // standby: 0.54 -> active: 0.42

        // 柔らかな背面グロー（ガラスパネルがわずかに発光して浮く表現）
        ctx.drawLayer { layerCtx in
            layerCtx.addFilter(.blur(radius: 6.0 * uiScale))
            for (poly, _) in polys {
                layerCtx.fill(poly, with: .color(rimGlow.opacity(0.24)))
            }
        }

        // 各パネルの半透明ガラス塗り＋淡いハイライトリム（黒ペン枠線なしで透け感を美しく見せる）
        for (i, (poly, center)) in polys.enumerated() {
            let cellPulse = 0.94 + 0.06 * sin(breath * .pi + Double(i) * 0.9)

            ctx.fill(
                poly,
                with: .linearGradient(
                    Gradient(colors: [
                        fillTop.opacity(topAlpha * cellPulse),
                        fillBot.opacity(botAlpha * cellPulse)
                    ]),
                    startPoint: CGPoint(x: center.x - w * 0.04, y: center.y - h * 0.08),
                    endPoint: CGPoint(x: center.x + w * 0.04, y: center.y + h * 0.08)
                )
            )

            // ガラスエッジの繊細な半透明リム光沢
            ctx.stroke(
                poly,
                with: .color(rimGlow.opacity(0.36 * cellPulse)),
                lineWidth: 1.0 * uiScale
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
        // 原作に合わせ左端の余計な装飾は置かず、左右2連台形と外周シアン/パープル弧でバランスを取る
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

/// ガンダム00 コックピット表示準拠の均等線幅ジオメトリックサンセリフ「TRANS-AM」ベクターロゴ
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

    private var strokeWidth: CGFloat {
        max(1.2, charHeight * 0.142)
    }

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
        let sw = strokeWidth
        let pad = glowRadius * 1.5 + sw + rimWidth + 2
        let w = totalWidth
        let h = charHeight

        Canvas { ctx, _ in
            var fullPath = Path()
            var cursorX = pad
            let originY = pad

            for (idx, ch) in characters.enumerated() {
                let cw = widthFactor(for: ch) * charWidth
                addStrokedGlyph(
                    ch,
                    in: CGRect(x: cursorX, y: originY, width: cw, height: h),
                    strokeWidth: sw,
                    to: &fullPath
                )
                cursorX += cw
                if idx + 1 < characters.count {
                    cursorX += spacing
                }
            }

            let clipRect = Path(CGRect(x: 0, y: originY, width: w + pad * 2, height: h))
            let strokeStyle = StrokeStyle(lineWidth: sw, lineCap: .butt, lineJoin: .miter, miterLimit: 2.2)
            let glowStyle = StrokeStyle(lineWidth: sw * 1.35, lineCap: .butt, lineJoin: .miter, miterLimit: 2.2)

            // 1. 控えめなマゼンタグロー
            ctx.drawLayer { layerCtx in
                layerCtx.addFilter(.blur(radius: glowRadius))
                layerCtx.drawLayer { clipped in
                    clipped.clip(to: clipRect)
                    clipped.stroke(fullPath, with: .color(glowColor.opacity(0.72)), style: glowStyle)
                }
            }

            // 2. 白抜きなしの落ち着いた均等線幅マゼンタピンク本体
            ctx.drawLayer { clipped in
                clipped.clip(to: clipRect)
                clipped.stroke(
                    fullPath,
                    with: .linearGradient(
                        Gradient(colors: [coreColor, glowColor]),
                        startPoint: CGPoint(x: pad, y: originY),
                        endPoint: CGPoint(x: pad, y: originY + h)
                    ),
                    style: strokeStyle
                )
            }

            // 3. リム幅が指定された場合のみハイライト芯線を描画
            if rimWidth > 0.01 {
                ctx.drawLayer { clipped in
                    clipped.clip(to: clipRect)
                    clipped.stroke(
                        fullPath,
                        with: .color(highlightColor.opacity(0.35)),
                        style: StrokeStyle(lineWidth: rimWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 2.2)
                    )
                }
            }
        }
        .frame(width: w + pad * 2, height: h + pad * 2)
        .padding(-pad)
    }

    private func widthFactor(for ch: Character) -> CGFloat {
        switch ch {
        case "T": return 0.92
        case "R": return 0.96
        case "A": return 1.02
        case "N": return 0.98
        case "S": return 0.92
        case "-": return 0.62
        case "M": return 1.16
        default: return 1.0
        }
    }

    private func addStrokedGlyph(_ ch: Character, in rect: CGRect, strokeWidth sw: CGFloat, to path: inout Path) {
        let hx = (sw * 0.5) / max(1, rect.width)
        let hy = (sw * 0.5) / max(1, rect.height)

        func p(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * nx, y: rect.minY + rect.height * ny)
        }

        switch ch {
        case "T":
            // 均等線幅のシャープな水平バー＋中央縦柱
            path.move(to: p(0.00, hy))
            path.addLine(to: p(1.00, hy))
            path.move(to: p(0.50, hy))
            path.addLine(to: p(0.50, 1.00))

        case "R":
            // 均等線幅の縦柱＋滑らかな上部ボウル＋右斜め下へ伸びる直線脚
            path.move(to: p(hx, 1.00))
            path.addLine(to: p(hx, hy))
            path.addLine(to: p(0.56, hy))
            path.addCurve(to: p(1.00 - hx, 0.30), control1: p(0.82, hy), control2: p(1.00 - hx, 0.14))
            path.addCurve(to: p(0.56, 0.53), control1: p(1.00 - hx, 0.45), control2: p(0.82, 0.53))
            path.addLine(to: p(hx, 0.53))

            path.move(to: p(0.55, 0.53))
            path.addLine(to: p(0.95, 1.06))

        case "A":
            // 鋭角な三角シルエットの均等線幅 A（フラット頂点＆直線脚＋横バー）
            path.move(to: p(0.04, 1.06))
            path.addLine(to: p(0.44, hy))
            path.addLine(to: p(0.56, hy))
            path.addLine(to: p(0.96, 1.06))

            path.move(to: p(0.19, 0.69))
            path.addLine(to: p(0.81, 0.69))

        case "N":
            // シャープな左右縦柱＋対角ストローク
            path.move(to: p(hx, 1.00))
            path.addLine(to: p(hx, hy))
            path.addLine(to: p(hx + 0.06, hy))
            path.addLine(to: p(1.00 - hx - 0.06, 1.00 - hy))
            path.addLine(to: p(1.00 - hx, 1.00 - hy))
            path.addLine(to: p(1.00 - hx, 0.00))

        case "S":
            // 滑らかな流線曲線のジオメトリックサンセリフ S
            path.move(to: p(0.90, 0.21))
            path.addCurve(to: p(0.50, hy), control1: p(0.86, 0.09), control2: p(0.71, hy))
            path.addCurve(to: p(hx + 0.02, 0.27), control1: p(0.24, hy), control2: p(hx + 0.02, 0.13))
            path.addCurve(to: p(0.52, 0.49), control1: p(hx + 0.02, 0.41), control2: p(0.22, 0.45))
            path.addCurve(to: p(1.00 - hx - 0.01, 0.74), control1: p(0.82, 0.53), control2: p(1.00 - hx - 0.01, 0.59))
            path.addCurve(to: p(0.49, 1.00 - hy), control1: p(1.00 - hx - 0.01, 0.90), control2: p(0.78, 1.00 - hy))
            path.addCurve(to: p(0.08, 0.79), control1: p(0.24, 1.00 - hy), control2: p(0.11, 0.91))

        case "-":
            path.move(to: p(0.10, 0.54))
            path.addLine(to: p(0.90, 0.54))

        case "M":
            // 均等線幅の左右縦柱＋底付近までシャープに落ちる中央 V
            path.move(to: p(hx, 1.00))
            path.addLine(to: p(hx, hy))
            path.addLine(to: p(hx + 0.08, hy))
            path.addLine(to: p(0.47, 0.87))
            path.addLine(to: p(0.53, 0.87))
            path.addLine(to: p(1.00 - hx - 0.08, hy))
            path.addLine(to: p(1.00 - hx, hy))
            path.addLine(to: p(1.00 - hx, 1.00))

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

            // 1. 控えめなマゼンタグロー
            ctx.drawLayer { layerCtx in
                layerCtx.addFilter(.blur(radius: glowRadius))
                layerCtx.stroke(fullPath, with: .color(glowColor.opacity(0.72)), style: StrokeStyle(
                    lineWidth: strokeWidth * 1.5,
                    lineCap: .butt,
                    lineJoin: .miter,
                    miterLimit: 2.4
                ))
            }

            // 2. 白抜きなしの落ち着いたピンクマゼンタストローク
            ctx.stroke(
                fullPath,
                with: .linearGradient(
                    Gradient(colors: [coreColor, glowColor]),
                    startPoint: CGPoint(x: pad, y: originY),
                    endPoint: CGPoint(x: pad, y: originY + h)
                ),
                style: style
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
