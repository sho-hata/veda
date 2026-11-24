import Foundation

enum CliSpriteKind: String {
    case gundam = "GUNDAM-00"
    case window = "VEDA-WIN"
}

enum CliTransAmPhase {
    case standby
    case activating(elapsed: Double)
    case active
}

struct AsciiAfterimage {
    let x: Double
    let y: Double
    let sprite: CliSpriteKind
    var age: Double
    let duration: Double

    var progress: Double {
        min(1.0, max(0.0, age / max(0.05, duration)))
    }

    var isExpired: Bool {
        age >= duration
    }
}

struct AsciiGnParticle {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var age: Double
    let lifetime: Double
    let glyph: Character

    var isExpired: Bool {
        age >= lifetime
    }
}

final class TransAmSimulation {
    static let activationDuration: Double = 2.45

    var phase: CliTransAmPhase = .standby
    var spriteKind: CliSpriteKind = .gundam
    var autoPilot: Bool = true
    var fadeDuration: Double = 0.55
    var spawnInterval: Double = 0.032

    // ユニット現在位置（0.0〜1.0 の正規化座標ではなく、キャンバス文字座標で保持）
    var unitX: Double = 44
    var unitY: Double = 14
    private var vx: Double = 0
    private var vy: Double = 0

    private var simTime: Double = 0
    private var lastSpawnTime: Double = -10
    private var lastSpawnX: Double = -999
    private var lastSpawnY: Double = -999
    private var rngState: UInt64 = 0x5EED_0001_CAFE_BEEF

    private(set) var afterimages: [AsciiAfterimage] = []
    private(set) var particles: [AsciiGnParticle] = []
    private var shockwaveAge: Double? = nil

    private let maxAfterimages = 48
    private let maxParticles = 96

    var isTransAmActive: Bool {
        if case .active = phase { return true }
        return false
    }

    func startActivation() {
        phase = .activating(elapsed: 0)
        shockwaveAge = nil
        afterimages.removeAll()
    }

    func deactivate() {
        phase = .standby
    }

    func toggleTransAm() {
        switch phase {
        case .standby:
            startActivation()
        case .activating:
            phase = .active
        case .active:
            deactivate()
        }
    }

    func toggleSprite() {
        spriteKind = (spriteKind == .gundam) ? .window : .gundam
    }

    func adjustFadeDuration(delta: Double) {
        fadeDuration = max(0.20, min(1.20, (fadeDuration + delta).rounded(toPlaces: 2)))
    }

    func handleInput(_ key: KeyEvent, canvasWidth: Int, canvasHeight: Int) {
        let stepX = 5.0
        let stepY = 2.5

        switch key {
        case .up:
            autoPilot = false
            vy -= stepY * 3.5
            unitY -= stepY
        case .down:
            autoPilot = false
            vy += stepY * 3.5
            unitY += stepY
        case .left:
            autoPilot = false
            vx -= stepX * 3.5
            unitX -= stepX
        case .right:
            autoPilot = false
            vx += stepX * 3.5
            unitX += stepX
        case .space:
            toggleTransAm()
        case .toggleAuto:
            autoPilot.toggle()
        case .toggleSprite:
            toggleSprite()
        case .increaseFade:
            adjustFadeDuration(delta: 0.10)
        case .decreaseFade:
            adjustFadeDuration(delta: -0.10)
        case .quit:
            break
        }

        clampUnit(width: canvasWidth, height: canvasHeight)
    }

    func step(dt: Double, width: Int, height: Int) {
        simTime += dt

        // 衝撃波リング更新
        if let age = shockwaveAge {
            let next = age + dt
            shockwaveAge = (next > 0.75) ? nil : next
        }

        // フェーズ進行
        switch phase {
        case .activating(let elapsed):
            let next = elapsed + dt
            if elapsed < 1.05 && next >= 1.05 {
                shockwaveAge = 0
                emitBurstParticles(x: Double(width) * 0.5, y: Double(height) * 0.5, count: 28)
            }
            if next >= Self.activationDuration {
                phase = .active
                unitX = Double(width) * 0.5
                unitY = Double(height) * 0.5
                lastSpawnX = unitX
                lastSpawnY = unitY
            } else {
                phase = .activating(elapsed: next)
            }

        case .standby, .active:
            let speedScale = isTransAmActive ? 1.85 : 0.75
            if autoPilot {
                // トランザムらしい高速 8 の字軌道（リサジュー曲線）
                let cx = Double(width) * 0.5
                let cy = Double(height) * 0.5
                let rx = max(10.0, Double(width) * 0.34)
                let ry = max(4.0, Double(height) * 0.28)
                let phaseAngle = simTime * 1.9 * speedScale
                unitX = cx + cos(phaseAngle) * rx
                unitY = cy + sin(phaseAngle * 2.0) * ry
            } else {
                unitX += vx * dt
                unitY += vy * dt
                let damping = pow(0.06, dt)
                vx *= damping
                vy *= damping
                clampUnit(width: width, height: height)
            }

            if isTransAmActive {
                maybeSpawnAfterimage()
            }
        }

        // 既存残像の年齢更新と確実な破棄
        for i in afterimages.indices {
            afterimages[i].age += dt
        }
        afterimages.removeAll { $0.isExpired }

        // GN パーティクル更新
        for i in particles.indices {
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].age += dt
        }
        particles.removeAll { $0.isExpired }
    }

    private func maybeSpawnAfterimage() {
        let dist = hypot(unitX - lastSpawnX, (unitY - lastSpawnY) * 2.0)
        guard dist >= 1.6 else { return }
        guard (simTime - lastSpawnTime) >= spawnInterval else { return }

        lastSpawnTime = simTime
        lastSpawnX = unitX
        lastSpawnY = unitY

        afterimages.append(AsciiAfterimage(
            x: unitX,
            y: unitY,
            sprite: spriteKind,
            age: 0,
            duration: fadeDuration
        ))
        if afterimages.count > maxAfterimages {
            afterimages.removeFirst(afterimages.count - maxAfterimages)
        }

        // 残像発生に合わせて GN 粒子を 2 粒散らす
        emitBurstParticles(x: unitX, y: unitY, count: 2)
    }

    private func emitBurstParticles(x: Double, y: Double, count: Int) {
        let glyphs: [Character] = ["✦", "*", "·", "°", "+"]
        for _ in 0..<count {
            let angle = nextRandom() * .pi * 2.0
            let speed = 5.0 + nextRandom() * 14.0
            let glyph = glyphs[Int(nextRandom() * Double(glyphs.count)) % glyphs.count]
            particles.append(AsciiGnParticle(
                x: x + (nextRandom() - 0.5) * 4.0,
                y: y + (nextRandom() - 0.5) * 2.0,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed * 0.48,
                age: 0,
                lifetime: 0.35 + nextRandom() * 0.45,
                glyph: glyph
            ))
        }
        if particles.count > maxParticles {
            particles.removeFirst(particles.count - maxParticles)
        }
    }

    private func clampUnit(width: Int, height: Int) {
        let marginX = 11.0
        let marginY = 5.0
        unitX = max(marginX, min(Double(width) - marginX, unitX))
        unitY = max(marginY, min(Double(height) - marginY, unitY))
    }

    private func nextRandom() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let shifted = (rngState >> 33) & 0x7FFF_FFFF
        return Double(shifted) / Double(0x7FFF_FFFF)
    }

    // MARK: - Rendering

    func render(into canvas: inout CanvasBuffer) {
        switch phase {
        case .activating(let elapsed):
            renderActivationSequence(into: &canvas, t: elapsed)
        case .standby, .active:
            renderFlightArena(into: &canvas)
        }
    }

    private func renderActivationSequence(into canvas: inout CanvasBuffer, t: Double) {
        let w = canvas.width
        let h = canvas.height
        let cx = w / 2
        let cy = h / 2

        let crimsonMix = clamp((t - 0.18) / 0.24)
        let primary = RGBColor.lerp(.gnEmerald, .transAmCrimson, t: crimsonMix)
        let flash1 = exp(-pow((t - 0.28) / 0.06, 2))
        let flash2 = exp(-pow((t - 1.05) / 0.08, 2))
        let flash = min(1.0, flash1 * 0.7 + flash2 * 0.85)

        let bgTint = RGBColor(
            r: UInt8(min(120, Int((14.0 + flash * 85.0) * crimsonMix))),
            g: UInt8(min(40, Int(6.0 + flash * 16.0))),
            b: UInt8(min(55, Int((12.0 + flash * 30.0) * crimsonMix)))
        )
        canvas.clear(bg: bgTint)

        // 背景スキャングリッド
        for y in 2..<(h - 2) where y % 3 == 0 {
            for x in 2..<(w - 2) where (x + y) % 8 == 0 {
                canvas.set(x: x, y: y, char: "·", fg: primary.scaled(by: 0.28))
            }
        }

        // 回転する同心円 HUD リング（ASCII楕円：端末文字の縦横比 2:1 補正）
        let ringExpand = easeOutCubic(clamp((t - 0.08) / 0.55))
        let rx = Double(min(w / 2 - 4, 34)) * (0.45 + 0.55 * ringExpand)
        let ry = Double(min(h / 2 - 2, 11)) * (0.45 + 0.55 * ringExpand)
        let tickCount = 32
        for i in 0..<tickCount {
            let a = (Double(i) / Double(tickCount)) * .pi * 2.0 + t * 1.1
            let px = Int((Double(cx) + cos(a) * rx).rounded())
            let py = Int((Double(cy) + sin(a) * ry).rounded())
            let ch: Character = (i % 4 == 0) ? "+" : "·"
            canvas.set(x: px, y: py, char: ch, fg: primary.scaled(by: 0.75 * ringExpand))
        }

        // GN パーティクル（放射状に拡散）
        for p in particles {
            let alpha = 1.0 - (p.age / p.lifetime)
            let col = RGBColor.lerp(.transAmDeep, .transAmHot, t: alpha)
            canvas.set(x: Int(p.x.rounded()), y: Int(p.y.rounded()), char: p.glyph, fg: col, bold: alpha > 0.6)
        }

        // ソレスタルビーイング エンブレム（中央から段階的にレーザー出現）
        if t >= 0.22 {
            let reveal = easeOutCubic(clamp((t - 0.22) / 0.68))
            let emblem = AsciiArtAssets.celestialBeingEmblem
            let startY = cy - emblem.count / 2
            let startX = cx - (emblem.first?.count ?? 0) / 2
            let emblemColor = RGBColor.lerp(primary, .white, t: min(0.65, flash * 0.7 + (t > 0.85 ? 0.25 : 0.0)))

            for (row, line) in emblem.enumerated() {
                let y = startY + row
                // 中央行から上下へ展開するスキャン出現
                let distFromMid = abs(Double(row) - Double(emblem.count) * 0.5) / (Double(emblem.count) * 0.5)
                guard distFromMid <= reveal else { continue }

                var col = 0
                for ch in line {
                    let x = startX + col
                    col += 1
                    if ch == " " { continue }
                    let isCore = (ch == "|" || ch == "V" || ch == "_" || ch == "=")
                    let fg = isCore ? RGBColor.lerp(.transAmHot, .white, t: 0.6) : emblemColor
                    canvas.set(x: x, y: y, char: ch, fg: fg, bold: true)
                }
            }
        }

        // 衝撃波リング（バナー背面に描画）
        if let sw = shockwaveAge {
            drawShockwave(into: &canvas, cx: Double(cx), cy: Double(cy), progress: sw / 0.75)
        }

        // 赤色光学スキャンライン走査（1.02s 〜 1.65s）
        if t >= 1.02 && t <= 1.65 {
            let beamP = clamp((t - 1.02) / 0.58)
            let beamY = 2 + Int(Double(h - 5) * beamP)
            canvas.drawHorizontalLine(y: beamY, from: 2, to: w - 3, char: "═", fg: .white, bold: true)
            if beamY - 1 >= 2 {
                canvas.drawHorizontalLine(y: beamY - 1, from: 2, to: w - 3, char: "─", fg: .transAmHot)
            }
            if beamY + 1 < h - 2 {
                canvas.drawHorizontalLine(y: beamY + 1, from: 2, to: w - 3, char: "─", fg: .transAmHot)
            }
        }

        // 「TRANS-AM」メインバナー（0.98s 〜 2.15s）
        if t >= 0.98 && t <= 2.25 {
            let bannerP = easeOutCubic(clamp((t - 0.98) / 0.25))
            let banner = AsciiArtAssets.transAmBanner
            let bannerStartY = cy - banner.count / 2
            let bannerW = banner.first?.count ?? 0
            let visibleHalf = Int(Double(bannerW / 2 + 1) * bannerP)
            let boxBg = RGBColor(r: 58, g: 4, b: 18)

            for (idx, line) in banner.enumerated() {
                let y = bannerStartY + idx
                let lineStartX = cx - bannerW / 2
                var c = 0
                for ch in line {
                    let x = lineStartX + c
                    c += 1
                    guard abs(x - cx) <= visibleHalf else { continue }
                    let isBorder = (idx == 0 || idx == banner.count - 1)
                    let fg: RGBColor = isBorder ? .transAmHot : (idx == 3 ? .transAmHot : .white)
                    canvas.set(x: x, y: y, char: ch, fg: fg, bg: boxBg, bold: !isBorder)
                }
            }
        }

        // フレーム＆Vedaテレメトリ
        let gnOutput = 100 + Int(easeOutCubic(clamp((t - 0.35) / 0.85)) * 200.0)
        let title = t < 0.35 ? "VEDA // SYSTEM OVERRIDE" : "CELESTIAL BEING // TRANS-AM"
        canvas.drawFrameBorder(fg: primary, title: title)

        let topRight = " GN OUTPUT: \(gnOutput)% "
        canvas.drawText(topRight, x: w - topRight.count - 2, y: 1, fg: .white, bg: primary.scaled(by: 0.45), bold: true)

        let bottomLeft = t < 0.98 ? "LIMITER: RELEASING..." : "PARTICLE DENSITY: 300% [MAX]"
        canvas.drawText(bottomLeft, x: 2, y: h - 2, fg: primary, bold: true)

        let bottomRight = "AEOLIA BLACKBOX"
        canvas.drawText(bottomRight, x: w - bottomRight.count - 2, y: h - 2, fg: .dimGray)
    }

    private func renderFlightArena(into canvas: inout CanvasBuffer) {
        let w = canvas.width
        let h = canvas.height
        let active = isTransAmActive
        let accent: RGBColor = active ? .transAmCrimson : .gnEmerald
        let bg: RGBColor = active ? RGBColor(r: 18, g: 3, b: 9) : RGBColor(r: 6, g: 12, b: 16)

        canvas.clear(bg: bg)

        // 背景にうっすらソレスタルビーイングエンブレム透かし
        let watermarkColor = active ? RGBColor(r: 58, g: 10, b: 24) : RGBColor(r: 16, g: 42, b: 36)
        canvas.drawSprite(
            AsciiArtAssets.celestialBeingEmblem,
            centerX: w / 2,
            centerY: h / 2,
            fg: watermarkColor,
            bold: false,
            skipSpaces: true,
            densityScale: 1.0
        )

        // GN パーティクル描画
        for p in particles {
            let lifeLeft = max(0.0, 1.0 - p.age / p.lifetime)
            let col = active
                ? RGBColor.lerp(.transAmEmber, .transAmHot, t: lifeLeft)
                : RGBColor.lerp(.gnDim, .gnEmerald, t: lifeLeft)
            canvas.set(x: Int(p.x.rounded()), y: Int(p.y.rounded()), char: p.glyph, fg: col, bold: lifeLeft > 0.65)
        }

        // トランザム残像描画（古い残像から順に描き、最新に近いほど明るく発光させる）
        for ghost in afterimages {
            let p = ghost.progress // 0.0 -> 1.0
            let brightness = 1.0 - p
            let color: RGBColor
            if p < 0.25 {
                color = RGBColor.lerp(.transAmHot, .transAmCrimson, t: p / 0.25)
            } else if p < 0.65 {
                color = RGBColor.lerp(.transAmCrimson, .transAmDeep, t: (p - 0.25) / 0.40)
            } else {
                color = RGBColor.lerp(.transAmDeep, .transAmEmber, t: (p - 0.65) / 0.35)
            }

            let lines = spriteLines(for: ghost.sprite, active: true)
            canvas.drawSprite(
                lines,
                centerX: Int(ghost.x.rounded()),
                centerY: Int(ghost.y.rounded()),
                fg: color,
                bold: p < 0.35,
                skipSpaces: true,
                densityScale: brightness
            )
        }

        // メインユニット本体（残像の前面に描画）
        let mainLines = spriteLines(for: spriteKind, active: active)
        let mainColor: RGBColor = active ? .white : .gnEmerald
        canvas.drawSprite(
            mainLines,
            centerX: Int(unitX.rounded()),
            centerY: Int(unitY.rounded()),
            fg: mainColor,
            bold: true,
            skipSpaces: spriteKind == .gundam,
            densityScale: 1.0
        )

        // 枠とステータスバー
        let title = active
            ? "VEDA CLI // TRANS-AM ACTIVE [GN 300%]"
            : "VEDA CLI // GN-DRIVE STANDBY [GN 100%]"
        canvas.drawFrameBorder(fg: accent, title: title)

        let stats = String(
            format: " UNIT:%@ | MODE:%@ | FADE:%.2fs | TRAILS:%02d ",
            spriteKind.rawValue,
            autoPilot ? "AUTO" : "MANUAL",
            fadeDuration,
            afterimages.count
        )
        canvas.drawText(stats, x: 2, y: 1, fg: active ? .transAmHot : .gnEmerald, bold: true)

        let controls = "[Space] Trans-Am  [Arrows/WASD] Move  [P] Auto  [M] Sprite  [+/-] Fade  [Q] Quit"
        let trimmedControls = controls.count > (w - 4) ? String(controls.prefix(w - 4)) : controls
        canvas.drawText(trimmedControls, x: 2, y: h - 2, fg: .dimGray)
    }

    private func drawShockwave(into canvas: inout CanvasBuffer, cx: Double, cy: Double, progress: Double) {
        let p = clamp(progress)
        let rx = 8.0 + p * Double(canvas.width) * 0.45
        let ry = 4.0 + p * Double(canvas.height) * 0.45
        let steps = 56
        let col = RGBColor.lerp(.white, .transAmCrimson, t: p).scaled(by: 1.0 - p * 0.8)
        for i in 0..<steps {
            let a = (Double(i) / Double(steps)) * .pi * 2.0
            let x = Int((cx + cos(a) * rx).rounded())
            let y = Int((cy + sin(a) * ry).rounded())
            canvas.set(x: x, y: y, char: p < 0.4 ? "○" : "·", fg: col, bold: p < 0.35)
        }
    }

    private func spriteLines(for kind: CliSpriteKind, active: Bool) -> [String] {
        switch kind {
        case .gundam:
            return AsciiArtAssets.gundamSprite
        case .window:
            return active ? AsciiArtAssets.windowSprite : AsciiArtAssets.standbyWindowSprite
        }
    }

    private func clamp(_ v: Double) -> Double {
        max(0.0, min(1.0, v))
    }

    private func easeOutCubic(_ x: Double) -> Double {
        1.0 - pow(1.0 - x, 3)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
