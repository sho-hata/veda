import AppKit
import CoreGraphics
import Darwin
import Foundation

private typealias SLSNotifyProc = @convention(c) (
    UInt32,
    UnsafeMutableRawPointer?,
    UInt32,
    UnsafeMutableRawPointer?
) -> Void

private typealias SLSRegisterNotifyProcFn = @convention(c) (
    SLSNotifyProc,
    UInt32,
    UnsafeMutableRawPointer?
) -> CGError

private typealias SLSRemoveNotifyProcFn = @convention(c) (
    SLSNotifyProc,
    UInt32,
    UnsafeMutableRawPointer?
) -> CGError

private let missionControlSkyLightCallback: SLSNotifyProc = { eventType, _, _, _ in
    DispatchQueue.main.async {
        MissionControlMonitor.handleGlobalSkyLightEvent(eventType)
    }
}

/// macOS の Mission Control（仮想ディスプレイ一覧）・App Exposé・デスクトップ表示が
/// アクティブかどうかを監視するモニター。
///
/// 1. SkyLight / CoreGraphics の WindowServer 通知（1204〜1208）で開始・終了を即時検知
/// 2. CGWindowListCopyWindowInfo の Dock オーバーレイ（layer == 18 等）でフォールバック＆クロスチェック
/// の 2 系統を併用し、仮想ディスプレイ一覧表示中はトランザムエフェクトを確実に OFF にする。
@MainActor
final class MissionControlMonitor {
    private static weak var activeInstance: MissionControlMonitor?

    // SkyLight / CoreGraphics WindowServer の Mission Control / Exposé 通知 ID
    private static let enterEventTypes: [UInt32] = [
        1204, // Mission Control（仮想ディスプレイ一覧 / 全ウィンドウ表示）開始
        1205, // App Exposé 開始
        1206, // デスクトップを表示 開始
        1207  // ウィンドウグループ Exposé 開始
    ]
    private static let exitEventType: UInt32 = 1208
    private static var allEventTypes: [UInt32] {
        enterEventTypes + [exitEventType]
    }

    private(set) var isActive: Bool = false

    private var observers: [(UUID, @MainActor (Bool) -> Void)] = []
    private var isStarted: Bool = false

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var registerNotifyProc: SLSRegisterNotifyProcFn?
    private var removeNotifyProc: SLSRemoveNotifyProcFn?
    private var registeredEvents: [UInt32] = []

    private var notifyBasedActive: Bool = false
    private var windowListBasedActive: Bool = false
    private var observedOverlayDuringNotifySession: Bool = false
    private var missingOverlayTicksDuringNotifySession: Int = 0
    private var lastWindowListCheckTime: CFTimeInterval = 0

    /// 通知の取りこぼし時にオーバーレイ消失から自動復帰するまでの連続フレーム数（60Hz 換算 約 0.30 秒）
    private let missingOverlayRecoveryThreshold: Int = 18

    @discardableResult
    func addObserver(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        observers.append((token, handler))
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeAll { $0.0 == token }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.activeInstance = self

        registerSkyLightNotifications()
        refreshFromSystemWindowListIfStale(maxAge: 0)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        unregisterSkyLightNotifications()

        if Self.activeInstance === self {
            Self.activeInstance = nil
        }

        notifyBasedActive = false
        windowListBasedActive = false
        observedOverlayDuringNotifySession = false
        missingOverlayTicksDuringNotifySession = 0
        lastWindowListCheckTime = 0
        recomputeActiveState()
    }

    /// ExternalWindowTracker の 60Hz ポーリングで取得したウィンドウ一覧を再利用して
    /// Mission Control オーバーレイの有無をクロスチェックする。
    func updateWindowListDetection(rawWindowList: [[String: Any]], now: CFTimeInterval = CACurrentMediaTime()) {
        lastWindowListCheckTime = now
        let detected = Self.detectMissionControlOverlay(in: rawWindowList)
        windowListBasedActive = detected

        if notifyBasedActive {
            if detected {
                observedOverlayDuringNotifySession = true
                missingOverlayTicksDuringNotifySession = 0
            } else if observedOverlayDuringNotifySession {
                missingOverlayTicksDuringNotifySession += 1
                if missingOverlayTicksDuringNotifySession >= missingOverlayRecoveryThreshold {
                    notifyBasedActive = false
                    observedOverlayDuringNotifySession = false
                    missingOverlayTicksDuringNotifySession = 0
                }
            }
        }

        recomputeActiveState()
    }

    /// 外部トラッカー停止中（Veda 単体動作中）でも必要時にウィンドウ一覧から最新状態を補完確認する。
    func refreshFromSystemWindowListIfStale(maxAge: CFTimeInterval = 0.08) {
        let now = CACurrentMediaTime()
        if maxAge > 0, (now - lastWindowListCheckTime) < maxAge {
            return
        }
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return
        }
        updateWindowListDetection(rawWindowList: rawList, now: now)
    }

    // MARK: - SkyLight Notification Handling

    fileprivate static func handleGlobalSkyLightEvent(_ eventType: UInt32) {
        activeInstance?.handleSkyLightEvent(eventType)
    }

    private func handleSkyLightEvent(_ eventType: UInt32) {
        guard isStarted else { return }

        if Self.enterEventTypes.contains(eventType) {
            notifyBasedActive = true
            observedOverlayDuringNotifySession = windowListBasedActive
            missingOverlayTicksDuringNotifySession = 0
            recomputeActiveState()
        } else if eventType == Self.exitEventType {
            notifyBasedActive = false
            observedOverlayDuringNotifySession = false
            missingOverlayTicksDuringNotifySession = 0
            // 終了通知直後にウィンドウ一覧上もまだ残っていないか確認せず即座に終了反映させるため、
            // 終了アニメーション中の一時的な残存は呼び出し側のクールダウン抑止に委ねる
            windowListBasedActive = false
            recomputeActiveState()
        }
    }

    private func recomputeActiveState() {
        let nextActive = notifyBasedActive || windowListBasedActive
        guard nextActive != isActive else { return }
        isActive = nextActive
        for (_, handler) in observers {
            handler(nextActive)
        }
    }

    private func registerSkyLightNotifications() {
        let candidates: [(path: String, registerSymbol: String, removeSymbol: String)] = [
            (
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                "SLSRegisterNotifyProc",
                "SLSRemoveNotifyProc"
            ),
            (
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                "CGSRegisterNotifyProc",
                "CGSRemoveNotifyProc"
            )
        ]

        for candidate in candidates {
            guard let handle = dlopen(candidate.path, RTLD_LAZY) else { continue }
            guard let regPtr = dlsym(handle, candidate.registerSymbol),
                  let remPtr = dlsym(handle, candidate.removeSymbol) else {
                dlclose(handle)
                continue
            }

            let regFn = unsafeBitCast(regPtr, to: SLSRegisterNotifyProcFn.self)
            let remFn = unsafeBitCast(remPtr, to: SLSRemoveNotifyProcFn.self)

            var registered: [UInt32] = []
            for event in Self.allEventTypes {
                if regFn(missionControlSkyLightCallback, event, nil) == .success {
                    registered.append(event)
                }
            }

            if !registered.isEmpty {
                frameworkHandle = handle
                registerNotifyProc = regFn
                removeNotifyProc = remFn
                registeredEvents = registered
                return
            } else {
                dlclose(handle)
            }
        }
    }

    private func unregisterSkyLightNotifications() {
        if let removeNotifyProc {
            for event in registeredEvents {
                _ = removeNotifyProc(missionControlSkyLightCallback, event, nil)
            }
        }
        registeredEvents.removeAll()
        registerNotifyProc = nil
        removeNotifyProc = nil

        if let frameworkHandle {
            dlclose(frameworkHandle)
            self.frameworkHandle = nil
        }
    }

    // MARK: - Window List Fallback Detection

    /// `CGWindowListCopyWindowInfo` の結果から、Dock が生成する Mission Control / Exposé の
    /// オーバーレイウィンドウの存在を検出する。
    /// 通常時の Dock バー本体は layer == 20、壁紙は負の layer に配置されるため、
    /// Mission Control / Exposé 専用レイヤー（layer == 18）等を対象として誤検知を防ぐ。
    static func detectMissionControlOverlay(in rawWindowList: [[String: Any]]) -> Bool {
        for entry in rawWindowList {
            guard let ownerName = entry[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock" else {
                continue
            }

            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
                continue
            }

            guard let layer = entry[kCGWindowLayer as String] as? Int else {
                continue
            }

            if let name = entry[kCGWindowName as String] as? String,
               layer != 0,
               name.localizedCaseInsensitiveContains("Mission Control") {
                return true
            }

            // Mission Control（仮想ディスプレイ一覧・Exposé）表示中、Dock は layer 18 に
            // オーバーレイ／Spaces バーウィンドウを生成する（通常 Dock は layer 20）。
            if layer == 18 {
                if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                   let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                    if rect.width >= 100 && rect.height >= 40 {
                        return true
                    }
                } else {
                    return true
                }
            }
        }

        return false
    }
}
