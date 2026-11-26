import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

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

    /// 画面収録権限（システム設定のトグル）が付与されているか
    var hasScreenCapturePermission: Bool = false

    /// ScreenCaptureKit の直接アクセス許可（macOS 15+ のプライベートウィンドウピッカーバイパス許可ダイアログ）まで承認済みか
    var isDirectCaptureAuthorized: Bool = false

    /// 現在、直接アクセス許可ダイアログの応答待ちか
    var isRequestingScreenCapture: Bool = false

    /// このセッション中にシステム設定の画面収録ペインを開いたか（再起動ボタン表示用）
    var hasRequestedScreenCaptureInSession: Bool = false

    /// このセッション中に直接アクセス許可の自動プロンプトを既に試行したか（キャンセル時の無限ループ防止）
    var hasAutoAttemptedDirectAuthInSession: Bool = false

    /// 実画面キャプチャ（他アプリのトランザム実画面残像）が即座に使える完全許可状態か
    var isScreenCaptureReady: Bool {
        hasScreenCapturePermission && isDirectCaptureAuthorized
    }

    /// 初回セットアップ（オンボーディング）を完了したか
    private static let onboardingCompletedKey = "com.sho-hata.veda.onboardingCompleted.v1"
    private static let directCaptureAuthorizedKey = "com.sho-hata.veda.directCaptureAuthorized.v1"

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingCompletedKey) }
    }

    /// 残像の持続時間（秒）: 0.2s 〜 1.2s
    var fadeDuration: Double = 0.42 {
        didSet { onVisualChange?() }
    }

    /// 残像の生成間隔（ミリ秒）: 16ms 〜 100ms
    var spawnIntervalMs: Double = 26.0 {
        didSet { onVisualChange?() }
    }

    /// 他アプリ用の残像生成間隔（ミリ秒）
    /// 60Hz ポーリング（16.67ms 周期）上で 4 tick（約 66.7ms）ごとに安定発火させ、Veda 本体の残像感に揃える
    var externalSpawnIntervalMs: Double = 58.0 {
        didSet { onVisualChange?() }
    }

    /// 発光強度: 0.2 〜 1.5
    var glowIntensity: Double = 0.85 {
        didSet { onVisualChange?() }
    }

    /// 残像を生成する最低移動距離（pt）
    let minimumMoveDistance: CGFloat = 10.0

    /// 他アプリ用の残像を生成する最低移動距離（pt）
    let externalMinimumMoveDistance: CGFloat = 28.0

    /// 縮小時に残像を生成する最低サイズ変化量（pt）
    let minimumShrinkDelta: CGFloat = 8.0

    /// 他アプリ用の縮小時に残像を生成する最低サイズ変化量（pt）
    let externalMinimumShrinkDelta: CGFloat = 18.0

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

    var externalSpawnIntervalSeconds: TimeInterval {
        externalSpawnIntervalMs / 1000.0
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
        let granted = CGPreflightScreenCaptureAccess()
        hasScreenCapturePermission = granted
        if granted {
            if UserDefaults.standard.bool(forKey: Self.directCaptureAuthorizedKey) {
                isDirectCaptureAuthorized = true
            }
        } else {
            isDirectCaptureAuthorized = false
            UserDefaults.standard.set(false, forKey: Self.directCaptureAuthorizedKey)
        }
    }

    /// システム設定の画面収録トグルを促す（未許可時）
    func requestScreenCapturePermission() {
        hasRequestedScreenCaptureInSession = true
        let granted = CGRequestScreenCaptureAccess()
        hasScreenCapturePermission = granted
        if granted {
            Task { @MainActor in
                await authorizeDirectScreenCapture()
            }
            return
        }
        // システムの初回ダイアログとフォーカスが競合しないよう少しずらして確実に「画面収録」リストを開く
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            AppInstallHelper.openScreenCaptureSettings()
        }
    }

    /// macOS 15+ の ScreenCaptureKit 直接アクセス許可ダイアログ（「許可」/「システム設定を開く」）を
    /// セットアップ内で明示的に発火・ハンドリングし、承認完了を確定する。
    func authorizeDirectScreenCapture() async {
        guard !isRequestingScreenCapture else { return }
        isRequestingScreenCapture = true
        defer { isRequestingScreenCapture = false }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            hasScreenCapturePermission = true
            isDirectCaptureAuthorized = true
            UserDefaults.standard.set(true, forKey: Self.directCaptureAuthorizedKey)
        } catch {
            hasRequestedScreenCaptureInSession = true
            isDirectCaptureAuthorized = false
            UserDefaults.standard.set(false, forKey: Self.directCaptureAuthorizedKey)
            hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
        }
    }

    /// システム設定トグルが ON になった直後（再起動直後やアプリ復帰時）に、
    /// ユーザーが押し忘れないよう直接アクセス許可ダイアログを自動で 1 回だけ発火する。
    func triggerAutoDirectCaptureAuthIfNeeded() {
        guard hasScreenCapturePermission,
              !isDirectCaptureAuthorized,
              !isRequestingScreenCapture,
              !hasAutoAttemptedDirectAuthInSession else {
            return
        }
        hasAutoAttemptedDirectAuthInSession = true
        Task { @MainActor in
            // ウィンドウ表示直後のフォーカス安定をわずかに待ってから表示
            try? await Task.sleep(for: .milliseconds(250))
            await authorizeDirectScreenCapture()
        }
    }

    /// 実行中に権限が拒否・失効（月次再確認など）されたときに再許可待ちへ戻し、バックグラウンド連打を防ぐ。
    func markDirectCaptureNeedsAuthorization() {
        isDirectCaptureAuthorized = false
        UserDefaults.standard.set(false, forKey: Self.directCaptureAuthorizedKey)
        hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    }
}
