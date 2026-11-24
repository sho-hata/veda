import AppKit
import CoreImage

/// スレッドセーフな CoreImage トランザム発光プロセッサ（バックグラウンドスレッドから安全に実行可能）
final class TransAmImageProcessor: @unchecked Sendable {
    private let ciContext: CIContext

    init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }

    /// CoreImage でトランザム風の赤〜マゼンタ発光ティントを適用する。
    /// ボヤけを抑えて輪郭と文字の視認性を保ちつつ、出力サイズを入力の extent と完全一致させる。
    func applyTransAmEffect(to cgImage: CGImage, glowIntensity: Double) -> CGImage? {
        let inputImage = CIImage(cgImage: cgImage)
        let originalExtent = inputImage.extent
        let clampedIntensity = max(0.0, min(1.5, glowIntensity))

        // 1. 赤〜マゼンタ系へのトランザム色相変換（暗部の白浮きを抑えてコントラストを維持）
        let colorMatrix = CIFilter(name: "CIColorMatrix")
        colorMatrix?.setValue(inputImage, forKey: kCIInputImageKey)

        let redBoost = CGFloat(0.92 + clampedIntensity * 0.32)
        let redFromG = CGFloat(0.42 + clampedIntensity * 0.18)
        let redFromB = CGFloat(0.22 + clampedIntensity * 0.10)
        let greenScale = CGFloat(0.16 + clampedIntensity * 0.08)
        let blueFromR = CGFloat(0.16 + clampedIntensity * 0.14)
        let blueScale = CGFloat(0.28 + clampedIntensity * 0.14)
        let redBias = CGFloat(0.06 + clampedIntensity * 0.06)
        let greenBias = CGFloat(0.0)
        let blueBias = CGFloat(0.015 + clampedIntensity * 0.025)

        colorMatrix?.setValue(CIVector(x: redBoost, y: redFromG, z: redFromB, w: 0), forKey: "inputRVector")
        colorMatrix?.setValue(CIVector(x: 0.06, y: greenScale, z: 0.04, w: 0), forKey: "inputGVector")
        colorMatrix?.setValue(CIVector(x: blueFromR, y: 0.06, z: blueScale, w: 0), forKey: "inputBVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        colorMatrix?.setValue(CIVector(x: redBias, y: greenBias, z: blueBias, w: 0), forKey: "inputBiasVector")

        var outputImage = colorMatrix?.outputImage ?? inputImage

        // 2. ごく控えめでタイトなハイライト発光（広いブラーで輪郭がボヤけない範囲に抑える）
        if clampedIntensity > 0.05, let bloom = CIFilter(name: "CIBloom") {
            bloom.setValue(outputImage.clampedToExtent(), forKey: kCIInputImageKey)
            bloom.setValue(2.0 + clampedIntensity * 2.0, forKey: kCIInputRadiusKey)
            bloom.setValue(0.08 + clampedIntensity * 0.12, forKey: kCIInputIntensityKey)
            if let bloomed = bloom.outputImage {
                outputImage = bloomed.cropped(to: originalExtent)
            }
        }

        // 3. 輪郭と文字をくっきりさせるシャープ化
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(outputImage.clampedToExtent(), forKey: kCIInputImageKey)
            sharpen.setValue(0.55, forKey: kCIInputSharpnessKey)
            sharpen.setValue(1.2, forKey: kCIInputRadiusKey)
            if let sharpened = sharpen.outputImage {
                outputImage = sharpened.cropped(to: originalExtent)
            }
        }

        // 4. コントラストと彩度を整えて残像の視認性を強調
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(outputImage, forKey: kCIInputImageKey)
            controls.setValue(1.05 + clampedIntensity * 0.20, forKey: kCIInputSaturationKey)
            controls.setValue(1.12 + clampedIntensity * 0.12, forKey: kCIInputContrastKey)
            controls.setValue(0.0, forKey: kCIInputBrightnessKey)
            if let adjusted = controls.outputImage {
                outputImage = adjusted.cropped(to: originalExtent)
            }
        }

        return ciContext.createCGImage(outputImage, from: originalExtent)
    }
}

@MainActor
final class SnapshotRenderer {
    struct CachedSnapshot {
        let cgImage: CGImage
        let backingScaleFactor: CGFloat
        let contentSize: CGSize
    }

    private let processor = TransAmImageProcessor()
    private var cachedSnapshot: CachedSnapshot?
    private var lastCaptureTimestamp: CFTimeInterval = 0
    private var cachedGlowIntensity: Double = -1
    private var isDirty: Bool = true

    /// ドラッグ中のスナップショット再取得間隔（秒）
    private let cacheTTL: CFTimeInterval = 0.25

    init() {}

    func invalidateCache() {
        isDirty = true
    }

    func clearCache() {
        cachedSnapshot = nil
        isDirty = true
        lastCaptureTimestamp = 0
    }

    /// ライブ縮小中などメインスレッドの描画負荷を避けたい場合に、既存キャッシュを即座に返す
    func reusableCachedSnapshot() -> CachedSnapshot? {
        cachedSnapshot
    }

    /// キャッシュされたトランザム発光スナップショットを返す。
    /// 一定時間経過・サイズ/スケール変更・UI更新時のみ再キャプチャする。
    func snapshot(
        for contentView: NSView,
        scale: CGFloat,
        glowIntensity: Double,
        now: CFTimeInterval
    ) -> CachedSnapshot? {
        let bounds = contentView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let sizeChanged = cachedSnapshot.map {
            abs($0.contentSize.width - bounds.width) > 0.5
                || abs($0.contentSize.height - bounds.height) > 0.5
        } ?? true
        let scaleChanged = cachedSnapshot.map {
            abs($0.backingScaleFactor - scale) > 0.01
        } ?? true
        let glowChanged = abs(cachedGlowIntensity - glowIntensity) > 0.02
        let expired = (now - lastCaptureTimestamp) >= cacheTTL

        if !isDirty && !sizeChanged && !scaleChanged && !glowChanged && !expired,
           let cached = cachedSnapshot {
            return cached
        }

        guard let rawImage = captureView(contentView, scale: scale) else {
            return cachedSnapshot
        }

        let tintedImage = renderTransAmImage(from: rawImage, glowIntensity: glowIntensity) ?? rawImage
        let snapshot = CachedSnapshot(
            cgImage: tintedImage,
            backingScaleFactor: scale,
            contentSize: bounds.size
        )

        cachedSnapshot = snapshot
        cachedGlowIntensity = glowIntensity
        lastCaptureTimestamp = now
        isDirty = false
        return snapshot
    }

    /// 外部ウィンドウ含む任意の CGImage にトランザム発光エフェクトを適用する
    func renderTransAmImage(from cgImage: CGImage, glowIntensity: Double) -> CGImage? {
        processor.applyTransAmEffect(to: cgImage, glowIntensity: glowIntensity)
    }

    /// 外部ウィンドウ向け：バックグラウンドスレッドでトランザム発光エフェクトを適用する
    func renderTransAmImageAsync(from cgImage: CGImage, glowIntensity: Double) async -> CGImage? {
        let imageProcessor = self.processor
        return await Task.detached(priority: .userInitiated) {
            imageProcessor.applyTransAmEffect(to: cgImage, glowIntensity: glowIntensity)
        }.value
    }

    private func captureView(_ view: NSView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds
        let expectedWidth = max(1, Int((bounds.width * scale).rounded()))
        let expectedHeight = max(1, Int((bounds.height * scale).rounded()))

        if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            let targetRep: NSBitmapImageRep
            if bitmapRep.pixelsWide == expectedWidth && bitmapRep.pixelsHigh == expectedHeight {
                targetRep = bitmapRep
            } else if let scaledRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: expectedWidth,
                pixelsHigh: expectedHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) {
                scaledRep.size = bounds.size
                targetRep = scaledRep
            } else {
                targetRep = bitmapRep
            }

            view.cacheDisplay(in: bounds, to: targetRep)
            if let cgImage = targetRep.cgImage, hasVisiblePixels(in: targetRep) {
                return cgImage
            }
        }

        // NSHostingView 等で cacheDisplay が空になる環境向けフォールバック（CALayer レンダリング）
        return captureLayerFallback(view, width: expectedWidth, height: expectedHeight, scale: scale)
    }

    private func hasVisiblePixels(in rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return false }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = max(4, rep.bitsPerPixel / 8)
        guard width > 0, height > 0 else { return false }

        let sampleCoords = [
            (width / 2, height / 2),
            (width / 4, height / 4),
            ((width * 3) / 4, height / 4),
            (width / 4, (height * 3) / 4),
            ((width * 3) / 4, (height * 3) / 4)
        ]

        for (x, y) in sampleCoords {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let alpha = data[offset + 3]
            if alpha > 0 {
                return true
            }
        }
        return false
    }

    private func captureLayerFallback(
        _ view: NSView,
        width: Int,
        height: Int,
        scale: CGFloat
    ) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
}
