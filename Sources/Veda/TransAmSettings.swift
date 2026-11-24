import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class TransAmSettings {
    enum ModePhase: Equatable {
        case standby
        case activating(startedAt: Date)
        case active
    }

    /// 現在のトランザム状態（スタンバイ / 発動シークエンス中 / 稼働中）
    var phase: ModePhase = .standby {
        didSet {
            onVisualChange?()
            onTrackingStateChange?()
        }
    }

    /// 残像エフェクトが有効かどうか（稼働中のみ ON）
    var isEnabled: Bool {
        get { phase == .active }
        set {
            if newValue {
                activateTransAm()
            } else {
                deactivateTransAm()
            }
        }
    }

    /// 発動シークエンス再生中かどうか
    var isActivating: Bool {
        if case .activating = phase { return true }
        return false
    }

    /// 他のアプリのウィンドウ移動にもトランザム残像を適用するか
    var includeOtherApps: Bool = true {
        didSet {
            onVisualChange?()
            onTrackingStateChange?()
        }
    }

    /// 画面収録権限が付与されているか（true なら他アプリも実画面キャプチャ、false なら発光シルエット残像）
    var hasScreenCapturePermission: Bool = false

    /// 残像の持続時間（秒）: 0.2s 〜 1.2s
    var fadeDuration: Double = 0.42 {
        didSet { onVisualChange?() }
    }

    /// 残像の生成間隔（ミリ秒）: 16ms 〜 100ms
    var spawnIntervalMs: Double = 26.0 {
        didSet { onVisualChange?() }
    }

    /// 発光強度: 0.2 〜 1.5
    var glowIntensity: Double = 0.85 {
        didSet { onVisualChange?() }
    }

    /// 残像を生成する最低移動距離（pt）
    let minimumMoveDistance: CGFloat = 10.0

    /// 縮小時に残像を生成する最低サイズ変化量（pt）
    let minimumShrinkDelta: CGFloat = 8.0

    /// 現在オーバーレイ上に存在する残像レイヤー数（デバッグ・確認用）
    var activeAfterimageCount: Int = 0

    /// UIや発光設定の変更時にスナップショットキャッシュを無効化するためのコールバック
    @ObservationIgnored
    var onVisualChange: (@MainActor () -> Void)?

    /// 外部ウィンドウ監視の開始/停止を同期するためのコールバック
    @ObservationIgnored
    var onTrackingStateChange: (@MainActor () -> Void)?

    var spawnIntervalSeconds: TimeInterval {
        spawnIntervalMs / 1000.0
    }

    func activateTransAm() {
        guard phase == .standby else { return }
        phase = .activating(startedAt: Date())
    }

    func finishActivationSequence() {
        guard case .activating = phase else { return }
        phase = .active
    }

    func deactivateTransAm() {
        phase = .standby
    }

    func refreshScreenCapturePermission() {
        hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        let granted = CGRequestScreenCaptureAccess()
        hasScreenCapturePermission = granted
        if !granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
