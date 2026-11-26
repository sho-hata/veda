#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - CLI Entrypoint

enum AssetGeneratorError: Error {
    case invalidArguments
    case graphicsContextFailed
    case pngEncodingFailed
    case iconutilFailed(Int32)
}

func run() throws {
    let args = CommandLine.arguments
    var iconOutputPath: String?
    var dmgBgOutputDir: String?

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--icon":
            guard i + 1 < args.count else { throw AssetGeneratorError.invalidArguments }
            iconOutputPath = args[i + 1]
            i += 2
        case "--dmg-bg":
            guard i + 1 < args.count else { throw AssetGeneratorError.invalidArguments }
            dmgBgOutputDir = args[i + 1]
            i += 2
        default:
            throw AssetGeneratorError.invalidArguments
        }
    }

    if iconOutputPath == nil && dmgBgOutputDir == nil {
        throw AssetGeneratorError.invalidArguments
    }

    if let iconOutputPath {
        try generateAppIconICNS(to: URL(fileURLWithPath: iconOutputPath))
        print("Generated app icon: \(iconOutputPath)")
    }

    if let dmgBgOutputDir {
        try generateDMGBackgrounds(to: URL(fileURLWithPath: dmgBgOutputDir, isDirectory: true))
        print("Generated DMG backgrounds in: \(dmgBgOutputDir)")
    }
}

// MARK: - PNG Helper

func renderPNG(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw AssetGeneratorError.graphicsContextFailed
    }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(true)

    draw(ctx, CGSize(width: width, height: height))

    guard let cgImage = ctx.makeImage() else {
        throw AssetGeneratorError.graphicsContextFailed
    }

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw AssetGeneratorError.pngEncodingFailed
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw AssetGeneratorError.pngEncodingFailed
    }
    return data as Data
}

// MARK: - Veda App Icon (.icns)

func generateAppIconICNS(to outputURL: URL) throws {
    let fm = FileManager.default
    // macOS 標準の PNG 格納 ICNS チャンク定義（Retina @2x 対応）
    let chunks: [(String, Int)] = [
        ("icp4", 16),
        ("ic11", 32),
        ("icp5", 32),
        ("ic12", 64),
        ("ic07", 128),
        ("ic13", 256),
        ("ic08", 256),
        ("ic14", 512),
        ("ic09", 512),
        ("ic10", 1024)
    ]

    var renderedCache: [Int: Data] = [:]
    var body = Data()

    for (fourCC, px) in chunks {
        let png: Data
        if let cached = renderedCache[px] {
            png = cached
        } else {
            png = try renderPNG(width: px, height: px) { ctx, size in
                drawVedaAppIcon(in: ctx, size: size)
            }
            renderedCache[px] = png
        }

        let chunkLength = UInt32(8 + png.count).bigEndian
        body.append(contentsOf: fourCC.utf8)
        withUnsafeBytes(of: chunkLength) { body.append(contentsOf: $0) }
        body.append(png)
    }

    var icnsData = Data()
    let totalLength = UInt32(8 + body.count).bigEndian
    icnsData.append(contentsOf: "icns".utf8)
    withUnsafeBytes(of: totalLength) { icnsData.append(contentsOf: $0) }
    icnsData.append(body)

    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try icnsData.write(to: outputURL, options: .atomic)
}

func drawVedaAppIcon(in ctx: CGContext, size: CGSize) {
    let w = size.width
    let h = size.height
    let s = min(w, h)
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }

    // macOS アイコンガイドライン準拠の余白と角丸
    let inset = s * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // ベースシャドウ
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.018),
        blur: s * 0.045,
        color: rgba(0.0, 0.0, 0.0, 0.58)
    )
    ctx.addPath(cardPath)
    ctx.setFillColor(rgba(0.015, 0.032, 0.095, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // カード内クリッピング
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    // 1. 深い宇宙ネイビー〜エレクトリックブルーの背景グラデーション
    if let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.08, 0.34, 0.78, 1.0),
            rgba(0.03, 0.14, 0.38, 1.0),
            rgba(0.010, 0.032, 0.115, 1.0),
            rgba(0.006, 0.014, 0.052, 1.0)
        ] as CFArray,
        locations: [0.0, 0.42, 0.78, 1.0]
    ) {
        ctx.drawRadialGradient(
            bgGrad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: cardRect.width * 0.68,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // 2. コア背後から広がる強いエレクトリックブルーのバックライトオーラ（四隅の隙間が美しく光る）
    if let auraGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.24, 0.72, 1.0, 0.92),
            rgba(0.10, 0.46, 1.0, 0.62),
            rgba(0.03, 0.18, 0.68, 0.18),
            rgba(0.0, 0.0, 0.0, 0.0)
        ] as CFArray,
        locations: [0.0, 0.46, 0.76, 1.0]
    ) {
        ctx.drawRadialGradient(
            auraGrad,
            startCenter: center,
            startRadius: s * 0.14,
            endCenter: center,
            endRadius: cardRect.width * 0.56,
            options: [.drawsBeforeStartLocation]
        )
    }

    // 3. 四隅へ伸びる外側の発光サポート支柱（ボリューム感あるソフトブルーの円柱ビーム）
    let frameInset = cardRect.width * 0.138
    let frameRect = cardRect.insetBy(dx: frameInset, dy: frameInset)
    let frameCornerRadius = frameRect.width * 0.17
    let frameCorners: [CGPoint] = [
        CGPoint(x: frameRect.minX + frameCornerRadius * 0.36, y: frameRect.maxY - frameCornerRadius * 0.36),
        CGPoint(x: frameRect.maxX - frameCornerRadius * 0.36, y: frameRect.maxY - frameCornerRadius * 0.36),
        CGPoint(x: frameRect.maxX - frameCornerRadius * 0.36, y: frameRect.minY + frameCornerRadius * 0.36),
        CGPoint(x: frameRect.minX + frameCornerRadius * 0.36, y: frameRect.minY + frameCornerRadius * 0.36)
    ]
    let cardCorners: [CGPoint] = [
        CGPoint(x: cardRect.minX, y: cardRect.maxY),
        CGPoint(x: cardRect.maxX, y: cardRect.maxY),
        CGPoint(x: cardRect.maxX, y: cardRect.minY),
        CGPoint(x: cardRect.minX, y: cardRect.minY)
    ]

    for idx in 0..<4 {
        let p0 = frameCorners[idx]
        let p1 = cardCorners[idx]
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: s * 0.042, color: rgba(0.12, 0.54, 1.0, 0.88))
        ctx.setLineWidth(max(2.0, s * 0.046))
        ctx.setStrokeColor(rgba(0.08, 0.36, 0.86, 0.78))
        ctx.move(to: p0)
        ctx.addLine(to: p1)
        ctx.strokePath()

        ctx.setShadow(offset: .zero, blur: s * 0.012, color: rgba(0.32, 0.76, 1.0, 0.75))
        ctx.setLineWidth(max(1.0, s * 0.018))
        ctx.setStrokeColor(rgba(0.36, 0.74, 1.0, 0.82))
        ctx.move(to: p0)
        ctx.addLine(to: p1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. 球体を四隅の角丸フレームへ懸架する 4 本の対角ストラット（コネクタ支柱）
    let sphereRadius = cardRect.width * 0.312
    for cornerPt in frameCorners {
        let dx = center.x - cornerPt.x
        let dy = center.y - cornerPt.y
        let dist = hypot(dx, dy)
        guard dist > 0 else { continue }
        let ux = dx / dist
        let uy = dy / dist
        let attachPt = CGPoint(
            x: center.x - ux * (sphereRadius * 0.88),
            y: center.y - uy * (sphereRadius * 0.88)
        )

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: s * 0.026, color: rgba(0.18, 0.72, 1.0, 0.92))
        ctx.setLineWidth(max(1.6, s * 0.026))
        ctx.setStrokeColor(rgba(0.16, 0.58, 0.98, 0.95))
        ctx.move(to: cornerPt)
        ctx.addLine(to: attachPt)
        ctx.strokePath()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setLineWidth(max(0.8, s * 0.010))
        ctx.setStrokeColor(rgba(0.72, 0.93, 1.0, 0.92))
        ctx.move(to: cornerPt)
        ctx.addLine(to: attachPt)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 5. Veda を囲むチューブ状の角丸スクエアフレーム（連続したメタリック発光パイプ）
    let framePath = CGPath(
        roundedRect: frameRect,
        cornerWidth: frameCornerRadius,
        cornerHeight: frameCornerRadius,
        transform: nil
    )

    // 外周ブルーム + ベースパイプ
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.050, color: rgba(0.12, 0.58, 1.0, 0.96))
    ctx.addPath(framePath)
    ctx.setLineWidth(max(2.2, s * 0.044))
    ctx.setStrokeColor(rgba(0.12, 0.46, 0.92, 0.96))
    ctx.strokePath()
    ctx.restoreGState()

    // 中間メタリックブルー層
    ctx.saveGState()
    ctx.addPath(framePath)
    ctx.setLineWidth(max(1.4, s * 0.026))
    ctx.setStrokeColor(rgba(0.36, 0.72, 1.0, 0.92))
    ctx.strokePath()

    // 繊細なスペキュラ芯線
    ctx.addPath(framePath)
    ctx.setLineWidth(max(0.7, s * 0.0085))
    ctx.setStrokeColor(rgba(0.76, 0.93, 1.0, 0.82))
    ctx.strokePath()
    ctx.restoreGState()

    // 6. 中央の Veda 球体コア（深みある濃紺メタリック球体 + 鮮烈なブルーリムライト）
    let sphereRect = CGRect(
        x: center.x - sphereRadius,
        y: center.y - sphereRadius,
        width: sphereRadius * 2,
        height: sphereRadius * 2
    )
    let spherePath = CGPath(ellipseIn: sphereRect, transform: nil)

    // 球体背後の強いブルー・バックグロウ
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.062, color: rgba(0.14, 0.66, 1.0, 0.96))
    ctx.addPath(spherePath)
    ctx.setFillColor(rgba(0.06, 0.10, 0.24, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 球体内部の描画（クリッピング）
    ctx.saveGState()
    ctx.addPath(spherePath)
    ctx.clip()

    // 球体ベース（参考画像に近い深みのあるインディゴ・スレート球面）
    if let sphereGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.19, 0.25, 0.44, 1.0),
            rgba(0.11, 0.16, 0.33, 1.0),
            rgba(0.055, 0.085, 0.20, 1.0),
            rgba(0.032, 0.055, 0.145, 1.0)
        ] as CFArray,
        locations: [0.0, 0.44, 0.80, 1.0]
    ) {
        ctx.drawRadialGradient(
            sphereGrad,
            startCenter: CGPoint(x: center.x - sphereRadius * 0.20, y: center.y + sphereRadius * 0.20),
            startRadius: sphereRadius * 0.05,
            endCenter: center,
            endRadius: sphereRadius * 1.04,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // 球体表面の円形リセスポート（奥行きのあるソフト3D窪み表現）
    if s >= 32 {
        struct SurfacePort {
            let angleDeg: CGFloat
            let distRatio: CGFloat
            let radiusRatio: CGFloat
            let foreshorten: CGFloat
        }

        let ports: [SurfacePort] = [
            SurfacePort(angleDeg: 94, distRatio: 0.83, radiusRatio: 0.21, foreshorten: 0.46),
            SurfacePort(angleDeg: 20, distRatio: 0.84, radiusRatio: 0.165, foreshorten: 0.48),
            SurfacePort(angleDeg: -26, distRatio: 0.78, radiusRatio: 0.13, foreshorten: 0.76),
            SurfacePort(angleDeg: -116, distRatio: 0.77, radiusRatio: 0.11, foreshorten: 0.82),
            SurfacePort(angleDeg: 152, distRatio: 0.83, radiusRatio: 0.16, foreshorten: 0.50),
            SurfacePort(angleDeg: -158, distRatio: 0.86, radiusRatio: 0.125, foreshorten: 0.46)
        ]

        for port in ports {
            let rad = port.angleDeg * .pi / 180.0
            let px = center.x + cos(rad) * sphereRadius * port.distRatio
            let py = center.y + sin(rad) * sphereRadius * port.distRatio
            let rMajor = sphereRadius * port.radiusRatio
            let rMinor = rMajor * port.foreshorten

            ctx.saveGState()
            ctx.translateBy(x: px, y: py)
            ctx.rotate(by: rad + .pi * 0.5)

            let portRect = CGRect(x: -rMajor, y: -rMinor, width: rMajor * 2, height: rMinor * 2)
            // 外側のソフトベベル光
            ctx.setLineWidth(max(0.8, s * 0.008))
            ctx.setStrokeColor(rgba(0.28, 0.64, 1.0, 0.58))
            ctx.strokeEllipse(in: portRect)

            // 内側の深い凹みグラデーション
            ctx.addEllipse(in: portRect)
            ctx.clip()
            if let portGrad = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    rgba(0.025, 0.045, 0.12, 0.96),
                    rgba(0.08, 0.16, 0.34, 0.88),
                    rgba(0.20, 0.48, 0.88, 0.52)
                ] as CFArray,
                locations: [0.0, 0.68, 1.0]
            ) {
                ctx.drawLinearGradient(
                    portGrad,
                    start: CGPoint(x: 0, y: -rMinor),
                    end: CGPoint(x: 0, y: rMinor),
                    options: []
                )
            }
            ctx.restoreGState()
        }

        // 右上寄りの小センサー・ドット群（参考画像の 4 点クラスター）
        let sensorDots: [(CGFloat, CGFloat, CGFloat)] = [
            (47, 0.69, 0.034),
            (37, 0.67, 0.030),
            (29, 0.61, 0.026),
            (41, 0.76, 0.024)
        ]
        for (deg, distR, dotR) in sensorDots {
            let rad = deg * .pi / 180.0
            let dx = center.x + cos(rad) * sphereRadius * distR
            let dy = center.y + sin(rad) * sphereRadius * distR
            let r = sphereRadius * dotR
            let dotRect = CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2)
            ctx.setFillColor(rgba(0.03, 0.06, 0.16, 0.92))
            ctx.fillEllipse(in: dotRect)
            ctx.setLineWidth(max(0.6, s * 0.005))
            ctx.setStrokeColor(rgba(0.34, 0.70, 1.0, 0.66))
            ctx.strokeEllipse(in: dotRect)
        }
    }

    // 球体エッジのフレネル・ブルーリムライト（背面光による輪郭の青い照り返し）
    if let rimGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.0, 0.0, 0.0, 0.0),
            rgba(0.08, 0.38, 0.92, 0.14),
            rgba(0.20, 0.68, 1.0, 0.58),
            rgba(0.58, 0.88, 1.0, 0.84)
        ] as CFArray,
        locations: [0.0, 0.74, 0.93, 1.0]
    ) {
        ctx.drawRadialGradient(
            rimGrad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: sphereRadius,
            options: []
        )
    }

    ctx.restoreGState() // 球体クリッピング解除

    // 球体外周のシャープなブルーリム
    ctx.saveGState()
    ctx.addPath(spherePath)
    ctx.setLineWidth(max(0.8, s * 0.007))
    ctx.setStrokeColor(rgba(0.38, 0.80, 1.0, 0.68))
    ctx.strokePath()
    ctx.restoreGState()

    // 7. 中央の Veda コアリング（外側の薄いリング + 鮮やかなエレクトリックブルーリング + クリーンなマットグレーコア）
    let haloRingRadius = sphereRadius * 0.67
    let mainRingRadius = sphereRadius * 0.56
    let coreDiskRadius = sphereRadius * 0.45

    // 外側の繊細な同心ベゼルリング
    ctx.saveGState()
    ctx.addArc(center: center, radius: haloRingRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(max(0.9, s * 0.011))
    ctx.setStrokeColor(rgba(0.28, 0.62, 1.0, 0.40))
    ctx.strokePath()
    ctx.restoreGState()

    // 中央のマットなスレートグレー・コア円盤（参考画像の中央の落ち着いた丸い鏡面）
    let coreRect = CGRect(
        x: center.x - coreDiskRadius,
        y: center.y - coreDiskRadius,
        width: coreDiskRadius * 2,
        height: coreDiskRadius * 2
    )
    ctx.saveGState()
    ctx.addEllipse(in: coreRect)
    ctx.clip()
    if let coreGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.28, 0.31, 0.39, 1.0),
            rgba(0.22, 0.26, 0.35, 1.0),
            rgba(0.13, 0.17, 0.28, 1.0)
        ] as CFArray,
        locations: [0.0, 0.68, 1.0]
    ) {
        ctx.drawRadialGradient(
            coreGrad,
            startCenter: CGPoint(x: center.x - coreDiskRadius * 0.12, y: center.y + coreDiskRadius * 0.12),
            startRadius: 0,
            endCenter: center,
            endRadius: coreDiskRadius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()

    // メインの発光エレクトリックブルーリング
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.052, color: rgba(0.12, 0.62, 1.0, 1.0))
    ctx.addArc(center: center, radius: mainRingRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(max(2.0, s * 0.036))
    ctx.setStrokeColor(rgba(0.16, 0.56, 1.0, 0.98))
    ctx.strokePath()

    ctx.setShadow(offset: .zero, blur: s * 0.018, color: rgba(0.36, 0.80, 1.0, 0.95))
    ctx.addArc(center: center, radius: mainRingRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(max(1.2, s * 0.019))
    ctx.setStrokeColor(rgba(0.46, 0.84, 1.0, 0.98))
    ctx.strokePath()

    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addArc(center: center, radius: mainRingRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(max(0.7, s * 0.008))
    ctx.setStrokeColor(rgba(0.84, 0.96, 1.0, 0.95))
    ctx.strokePath()
    ctx.restoreGState()

    // 8. 上部の控えめなガラスリフレクション
    let glossPath = CGMutablePath()
    glossPath.move(to: CGPoint(x: cardRect.minX, y: cardRect.maxY))
    glossPath.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY))
    glossPath.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.midY + cardRect.height * 0.14))
    glossPath.addLine(to: CGPoint(x: cardRect.minX, y: cardRect.midY + cardRect.height * 0.26))
    glossPath.closeSubpath()
    ctx.saveGState()
    ctx.addPath(glossPath)
    ctx.clip()
    if let glossGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(0.72, 0.90, 1.0, 0.11),
            rgba(0.72, 0.90, 1.0, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            glossGrad,
            start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.midX, y: cardRect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    // カード外周のクールブルーリム
    ctx.addPath(cardPath)
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.setStrokeColor(rgba(0.28, 0.72, 1.0, 0.52))
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - DMG Drag & Drop Background (660x380 @1x & @2x)

func generateDMGBackgrounds(to outputDir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let png1x = try renderPNG(width: 660, height: 380) { ctx, _ in
        drawDMGBackground(in: ctx, scale: 1.0)
    }
    try png1x.write(to: outputDir.appendingPathComponent("background.png"))

    let png2x = try renderPNG(width: 1320, height: 760) { ctx, _ in
        drawDMGBackground(in: ctx, scale: 2.0)
    }
    try png2x.write(to: outputDir.appendingPathComponent("background@2x.png"))
}

func drawDMGBackground(in ctx: CGContext, scale: CGFloat) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let width: CGFloat = 660
    let height: CGFloat = 380

    // Finder 座標（上原点）から CoreGraphics 座標（下原点）への変換ヘルパー
    func topDownRect(x: CGFloat, y: CGFloat, width w: CGFloat, height h: CGFloat) -> CGRect {
        CGRect(x: x, y: height - (y + h), width: w, height: h)
    }

    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    // 1. 背景グラデーション（GN 粒子エメラルド・ディープダーク）
    if let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.016, 0.072, 0.046, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.010, 0.036, 0.025, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.005, 0.016, 0.012, 1.0])!
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    ) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: width * 0.5, y: height),
            end: CGPoint(x: width * 0.5, y: 0),
            options: []
        )
    }

    // 放射状の GN 粒子発光オーラ（エメラルドグリーン〜ジェイドミント）
    let auraCenter = CGPoint(x: width * 0.5, y: height - 174)
    if let aura = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.14, 0.96, 0.48, 0.22])!,
            CGColor(colorSpace: colorSpace, components: [0.12, 0.88, 0.72, 0.06])!,
            CGColor(colorSpace: colorSpace, components: [0.0, 0.0, 0.0, 0.0])!
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    ) {
        ctx.drawRadialGradient(
            aura,
            startCenter: auraCenter,
            startRadius: 0,
            endCenter: auraCenter,
            endRadius: 310,
            options: [.drawsBeforeStartLocation]
        )
    }

    // 微細なグリッドライン（ほのかな GN グリーンティント）
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.35, 1.0, 0.65, 0.042])!)
    ctx.setLineWidth(1.0)
    var x: CGFloat = 0
    while x <= width {
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x, y: height))
        x += 30
    }
    var y: CGFloat = 0
    while y <= height {
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: width, y: y))
        y += 30
    }
    ctx.strokePath()

    // 2. 左右のアイコン配置ガイド枠 + 枠下のラベル背景ピル
    // Finder 側で Veda.app=(175, 164), Applications=(485, 164), iconSize=112, textSize=13 に配置する
    // macOS Finder は背景画像設定時にアイコン下ラベルを黒文字で描画するため、枠の外（直下）に明るいピルを敷いて視認性を確保する
    let iconCenterY: CGFloat = 164
    let slotXs: [CGFloat] = [175, 485]
    let slotWidth: CGFloat = 138
    let slotTopY: CGFloat = iconCenterY - 60    // 104
    let slotHeight: CGFloat = 118               // bottom = 222（アイコンのエイリアスバッジ下端 217 に対して 5pt 余白）

    let pillWidth: CGFloat = 128
    let pillTopY: CGFloat = iconCenterY + 64.5  // 228.5（枠下端 222 から 6.5pt の間隔）
    let pillHeight: CGFloat = 21                // bottom = 249.5（Finder ラベル 234..244.5 を中央収容）

    for (index, centerX) in slotXs.enumerated() {
        let isDestination = (index == 1)

        // アイコン枠（アイコンのみを囲む）
        let slotRect = topDownRect(
            x: centerX - slotWidth * 0.5,
            y: slotTopY,
            width: slotWidth,
            height: slotHeight
        )
        let slotPath = CGPath(roundedRect: slotRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.saveGState()
        ctx.addPath(slotPath)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.30, 1.0, 0.62, isDestination ? 0.055 : 0.045])!)
        ctx.fillPath()

        ctx.addPath(slotPath)
        if isDestination {
            ctx.setLineDash(phase: 0, lengths: [6, 5])
            ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.22, 0.96, 0.74, 0.60])!)
            ctx.setLineWidth(1.6)
        } else {
            ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.20, 0.96, 0.52, 0.58])!)
            ctx.setLineWidth(1.4)
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 枠下のラベル背景ピル（Finder の黒文字ラベル「Veda」「Applications」を明瞭に表示）
        let pillRect = topDownRect(
            x: centerX - pillWidth * 0.5,
            y: pillTopY,
            width: pillWidth,
            height: pillHeight
        )
        let pillRadius = pillHeight * 0.5
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)

        // ピルのソフト発光シャドウ（GN 粒子グリーン）
        ctx.saveGState()
        let glowColor = isDestination
            ? CGColor(colorSpace: colorSpace, components: [0.18, 0.96, 0.74, 0.34])!
            : CGColor(colorSpace: colorSpace, components: [0.18, 0.98, 0.50, 0.34])!
        ctx.setShadow(offset: .zero, blur: 8, color: glowColor)
        ctx.addPath(pillPath)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.93, 0.99, 0.96, 0.95])!)
        ctx.fillPath()
        ctx.restoreGState()

        // ピル内部のミントパールホワイト・グラデーション
        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.clip()
        if let pillGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(colorSpace: colorSpace, components: [0.96, 1.00, 0.98, 0.96])!,
                CGColor(colorSpace: colorSpace, components: [0.85, 0.96, 0.91, 0.93])!
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                pillGrad,
                start: CGPoint(x: pillRect.midX, y: pillRect.maxY),
                end: CGPoint(x: pillRect.midX, y: pillRect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        // ピルの GN 粒子アクセント枠線
        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.setLineWidth(1.1)
        let borderColor = isDestination
            ? CGColor(colorSpace: colorSpace, components: [0.22, 0.94, 0.74, 0.80])!
            : CGColor(colorSpace: colorSpace, components: [0.20, 0.96, 0.52, 0.80])!
        ctx.setStrokeColor(borderColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 3. 中央のドラッグ＆ドロップ発光矢印（>>>：GN 粒子エメラルド→ミントアクア）
    let arrowCenterY = height - (iconCenterY - 1)
    let chevronXs: [CGFloat] = [298, 330, 362]
    for (idx, cx) in chevronXs.enumerated() {
        let progress = CGFloat(idx) / CGFloat(chevronXs.count - 1)
        let r: CGFloat = 0.16 + progress * 0.14
        let g: CGFloat = 0.94 + progress * 0.06
        let b: CGFloat = 0.44 + progress * 0.36
        let alpha: CGFloat = 0.48 + progress * 0.48

        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: cx - 10, y: arrowCenterY + 18))
        chevron.addLine(to: CGPoint(x: cx + 10, y: arrowCenterY))
        chevron.addLine(to: CGPoint(x: cx - 10, y: arrowCenterY - 18))

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(4.0)
        ctx.setShadow(
            offset: .zero,
            blur: 10,
            color: CGColor(colorSpace: colorSpace, components: [r, g, b, 0.85])
        )
        ctx.addPath(chevron)
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [r, g, b, alpha])!)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

do {
    try run()
} catch {
    fputs("Asset generation failed: \(error)\n", stderr)
    exit(1)
}
