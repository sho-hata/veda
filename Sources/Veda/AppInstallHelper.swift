import AppKit
import Foundation

/// Veda.app のインストール場所判定、/Applications へのインストール、再起動、システム設定誘導を担うヘルパー。
@MainActor
enum AppInstallHelper {
    enum InstallState: Equatable {
        case installedInApplications(URL)
        case runningFromDiskImage(URL)
        case runningFromTranslocation(URL)
        case runningOutsideApplications(URL)
        case developmentExecutable(URL)

        var isInstalled: Bool {
            if case .installedInApplications = self {
                return true
            }
            return false
        }

        var requiresInstallAttention: Bool {
            switch self {
            case .runningFromDiskImage, .runningFromTranslocation:
                return true
            case .installedInApplications, .runningOutsideApplications, .developmentExecutable:
                return false
            }
        }

        var badgeText: String {
            switch self {
            case .installedInApplications:
                return "済"
            case .runningFromDiskImage:
                return "DMG"
            case .runningFromTranslocation:
                return "一時領域"
            case .runningOutsideApplications:
                return "未配置"
            case .developmentExecutable:
                return "開発"
            }
        }
    }

    enum InstallError: LocalizedError {
        case notAnAppBundle
        case failedToCopy(String)
        case failedToLaunch(String)

        var errorDescription: String? {
            switch self {
            case .notAnAppBundle:
                return "現在のプロセスは .app バンドルではないためインストールできません。"
            case .failedToCopy(let reason):
                return "Applications フォルダへのコピーに失敗しました: \(reason)"
            case .failedToLaunch(let reason):
                return "インストール後の Veda 起動に失敗しました: \(reason)"
            }
        }
    }

    static var currentBundleURL: URL {
        Bundle.main.bundleURL.standardizedFileURL
    }

    static var isAppBundle: Bool {
        currentBundleURL.pathExtension.lowercased() == "app"
    }

    static var draggableAppURL: URL? {
        guard isAppBundle else { return nil }
        return currentBundleURL
    }

    static func currentInstallState() -> InstallState {
        let url = currentBundleURL
        guard isAppBundle else {
            return .developmentExecutable(url)
        }

        let path = url.path
        let userAppsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path

        if path.hasPrefix("/Applications/") || path.hasPrefix(userAppsPath + "/") {
            return .installedInApplications(url)
        }

        if path.contains("/AppTranslocation/") {
            return .runningFromTranslocation(url)
        }

        if path.hasPrefix("/Volumes/") || isReadOnlyVolume(url) {
            return .runningFromDiskImage(url)
        }

        return .runningOutsideApplications(url)
    }

    static func preferredApplicationsDirectory() -> URL {
        let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: systemApps.path) {
            return systemApps
        }

        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
        return userApps
    }

    /// 現在の Veda.app を /Applications（不可なら ~/Applications）へコピーして配置先 URL を返す。
    @discardableResult
    static func copyToApplications() throws -> URL {
        guard isAppBundle else {
            throw InstallError.notAnAppBundle
        }

        let sourceURL = currentBundleURL
        let appsDir = preferredApplicationsDirectory()
        let appFileName = sourceURL.lastPathComponent.isEmpty ? "Veda.app" : sourceURL.lastPathComponent
        let destinationURL = appsDir.appendingPathComponent(appFileName, isDirectory: true)

        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return destinationURL
        }

        let fm = FileManager.default
        let stagingURL = appsDir.appendingPathComponent(".\(appFileName).installing-\(UUID().uuidString)", isDirectory: true)

        do {
            if fm.fileExists(atPath: stagingURL.path) {
                try fm.removeItem(at: stagingURL)
            }
            try fm.copyItem(at: sourceURL, to: stagingURL)

            // 既存の /Applications/Veda.app がある場合は安全に置き換える
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: stagingURL, to: destinationURL)
            }

            // 隔離属性が付いている場合は除去を試みる（失敗しても続行）
            stripQuarantineIfPossible(at: destinationURL)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw InstallError.failedToCopy(error.localizedDescription)
        }

        return destinationURL
    }

    /// コピー済みの /Applications/Veda.app を起動し、現在のインスタンスを終了する。
    static func launchInstalledAppAndTerminate(at destinationURL: URL) {
        if currentBundleURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true

        NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
            Task { @MainActor in
                if error == nil {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 現在の Veda.app を /Applications（不可なら ~/Applications）へコピーし、そこから再起動する。
    static func installToApplicationsAndRelaunch() throws {
        let destinationURL = try copyToApplications()
        launchInstalledAppAndTerminate(at: destinationURL)
    }

    /// /Applications または ~/Applications に配置された Veda.app の現在の配置 URL と更新スタンプを返す。
    /// アプリ起動中に Finder 等から外部コピーされた瞬間の検知に使用する。
    static func installedApplicationsBundleSnapshot() -> (url: URL, stamp: String)? {
        let fm = FileManager.default
        let appFileName = (isAppBundle && !currentBundleURL.lastPathComponent.isEmpty)
            ? currentBundleURL.lastPathComponent
            : "Veda.app"
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(appFileName, isDirectory: true),
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(appFileName, isDirectory: true)
        ]

        for bundleURL in candidates {
            let executableURL = bundleURL
                .appendingPathComponent("Contents/MacOS/Veda", isDirectory: false)
            guard fm.isExecutableFile(atPath: executableURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: executableURL.path),
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let stamp = "\(bundleURL.standardizedFileURL.path)|\(Int64(mtime.timeIntervalSince1970))|\(size)"
            return (bundleURL, stamp)
        }
        return nil
    }

    /// 画面収録権限の変更を反映させるため、現在の Veda.app を再起動する。
    static func relaunchCurrentApp() {
        let targetURL = currentBundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if isAppBundle {
            process.arguments = [
                "-c",
                "sleep 0.35 && open -n \"$1\"",
                "veda-relaunch",
                targetURL.path
            ]
        } else {
            let executablePath = CommandLine.arguments.first ?? targetURL.path
            process.arguments = [
                "-c",
                "sleep 0.35 && \"$1\" &",
                "veda-relaunch",
                executablePath
            ]
        }
        try? process.run()
        NSApp.terminate(nil)
    }

    static func openApplicationsFolder() {
        NSWorkspace.shared.open(preferredApplicationsDirectory())
    }

    static func openScreenCaptureSettings() {
        let primaryURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

        guard let primaryURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open(primaryURL, configuration: config) { _, error in
            if error != nil, let fallbackURL {
                Task { @MainActor in
                    let fallbackConfig = NSWorkspace.OpenConfiguration()
                    fallbackConfig.activates = true
                    NSWorkspace.shared.open(fallbackURL, configuration: fallbackConfig) { _, _ in }
                }
            }
        }
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentBundleURL])
    }

    static func appIconImage(size: CGFloat = 64) -> NSImage {
        if let icon = NSApp.applicationIconImage?.copy() as? NSImage {
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        let fallback = NSWorkspace.shared.icon(forFile: currentBundleURL.path)
        fallback.size = NSSize(width: size, height: size)
        return fallback
    }

    private static func isReadOnlyVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true
    }

    private static func stripQuarantineIfPossible(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
