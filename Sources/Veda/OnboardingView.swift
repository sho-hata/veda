import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 最小限の UI でドラッグ＆ドロップによるインストールと画面収録許可を完結させるセットアップ画面。
struct OnboardingView: View {
    let settings: TransAmSettings
    let onContinue: () -> Void

    @State private var installState: AppInstallHelper.InstallState = AppInstallHelper.currentInstallState()
    @State private var showInstallStep: Bool = !AppInstallHelper.currentInstallState().isInstalled
    @State private var isDropTargetedOnApplications: Bool = false
    @State private var isInstalling: Bool = false
    @State private var installErrorMessage: String?
    @State private var isPollingActive: Bool = true
    @State private var baselineExternalInstallStamp: String? = AppInstallHelper.installedApplicationsBundleSnapshot()?.stamp
    @State private var didCelebrateExternalInstall: Bool = false

    private var windowHeight: CGFloat {
        showInstallStep ? 354 : 256
    }

    @State private var dragDemo = DragDemoOverlayController()
    @State private var demoFlightMode: DragDemoOverlayController.DemoMode = .none
    @State private var isDemoInFlight: Bool = false
    @State private var isDemoHighlightingApplications: Bool = false
    @State private var isSystemSettingsVisible: Bool = false

    private var isAllReady: Bool {
        settings.isScreenCaptureReady && !installState.requiresInstallAttention
    }

    private var accentGNEmerald: Color {
        Color(red: 0.18, green: 0.95, blue: 0.50)
    }

    private var accentGNMint: Color {
        Color(red: 0.24, green: 0.96, blue: 0.72)
    }

    private var accentGNButtonStart: Color {
        Color(red: 0.07, green: 0.72, blue: 0.38)
    }

    private var accentGNButtonEnd: Color {
        Color(red: 0.04, green: 0.58, blue: 0.48)
    }

    private var accentGreen: Color {
        Color(red: 0.28, green: 0.98, blue: 0.52)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.016, green: 0.068, blue: 0.044),
                    Color(red: 0.006, green: 0.022, blue: 0.015)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                header

                VStack(spacing: 10) {
                    if showInstallStep {
                        installRow
                    }
                    screenCaptureRow
                }

                if let installErrorMessage {
                    Text(installErrorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.40))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                footer
            }
            .padding(.top, 28)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 420, height: windowHeight)
        .preferredColorScheme(.dark)
        .onAppear {
            configureDragDemoCallbacks()
            syncDragDemoMode()
        }
        .task {
            await pollPermissionLoop()
        }
        .onDisappear {
            isPollingActive = false
            dragDemo.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInstallHelper.appIconImage(size: 32))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            Text("Veda")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Spacer()
        }
    }

    // MARK: - Step 1: Applications

    private var installRow: some View {
        let completed = installState.isInstalled
        let isApplicationsHighlighted = isDropTargetedOnApplications || isDemoHighlightingApplications

        return rowContainer(step: "1", title: "Applications", isCompleted: completed) {
            if !completed, let appURL = AppInstallHelper.draggableAppURL {
                HStack(spacing: 10) {
                    DraggableAppTile(
                        appURL: appURL,
                        isDimmedByDemo: isDemoInFlight && demoFlightMode == .applications,
                        onIconViewReady: { iconView in
                            dragDemo.registerInstallAnchors(sourceIconView: iconView, targetView: nil)
                        },
                        onInteractionChanged: { interacting in
                            dragDemo.setUserInteracting(interacting)
                        }
                    )

                    arrowGlyph(highlighted: isApplicationsHighlighted)

                    Button {
                        performInstallToApplications()
                    } label: {
                        HStack(spacing: 8) {
                            if isInstalling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications"))
                                    .resizable()
                                    .frame(width: 28, height: 28)
                            }
                            Text("Applications")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            (isApplicationsHighlighted
                                ? accentGreen.opacity(isDropTargetedOnApplications ? 0.22 : 0.14)
                                : Color.white.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isApplicationsHighlighted ? accentGreen : Color.white.opacity(0.18),
                                    style: StrokeStyle(
                                        lineWidth: isApplicationsHighlighted ? 1.5 : 1.0,
                                        dash: isApplicationsHighlighted ? [] : [4, 4]
                                    )
                                )
                        )
                        .animation(.easeInOut(duration: 0.18), value: isApplicationsHighlighted)
                        .background(
                            ViewAnchorBridge { view in
                                dragDemo.registerInstallAnchors(sourceIconView: nil, targetView: view)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isInstalling)
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargetedOnApplications) { providers in
                        guard !providers.isEmpty else { return false }
                        performInstallToApplications()
                        return true
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Screen Recording

    private var screenCaptureRow: some View {
        let ready = settings.isScreenCaptureReady
        let needsDirectConfirm = settings.hasScreenCapturePermission && !settings.isDirectCaptureAuthorized

        return rowContainer(
            step: showInstallStep ? "2" : nil,
            badgeSymbol: "lock.shield.fill",
            title: "画面収録",
            subtitle: "残像エフェクトを描画するため、画面収録の許可が必要です",
            isCompleted: ready
        ) {
            if !ready {
                if needsDirectConfirm {
                    // システム設定のトグルは ON 済み → macOS の直接アクセス許可ダイアログ（「許可」）をハンドリング
                    HStack(spacing: 10) {
                        Button {
                            Task { @MainActor in
                                await settings.authorizeDirectScreenCapture()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if settings.isRequestingScreenCapture {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 12.5))
                                }
                                Text(settings.isRequestingScreenCapture ? "確認中..." : "アクセスを許可")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                LinearGradient(
                                    colors: [accentGNButtonStart, accentGNButtonEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(accentGNEmerald.opacity(0.55), lineWidth: 1)
                            )
                            .shadow(color: accentGNEmerald.opacity(0.28), radius: 8, y: 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.isRequestingScreenCapture)

                        Button {
                            AppInstallHelper.openScreenCaptureSettings()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.80))
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("システム設定を開く")
                    }
                } else {
                    HStack(spacing: 10) {
                        if let appURL = AppInstallHelper.draggableAppURL {
                            DraggableAppTile(
                                appURL: appURL,
                                isDimmedByDemo: isDemoInFlight && demoFlightMode == .systemSettings,
                                onIconViewReady: { iconView in
                                    dragDemo.registerScreenCaptureSourceIconView(iconView)
                                },
                                onInteractionChanged: { interacting in
                                    dragDemo.setUserInteracting(interacting)
                                }
                            )
                            arrowGlyph(highlighted: isDemoInFlight && demoFlightMode == .systemSettings)
                        }

                        Button {
                            openSystemSettingsAndStartDemo()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 12))
                                Text("設定を開く")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                LinearGradient(
                                    colors: [accentGNButtonStart, accentGNButtonEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(accentGNEmerald.opacity(0.55), lineWidth: 1)
                            )
                            .shadow(color: accentGNEmerald.opacity(0.28), radius: 8, y: 0)
                        }
                        .buttonStyle(.plain)

                        if settings.hasRequestedScreenCaptureInSession {
                            Button {
                                AppInstallHelper.relaunchCurrentApp()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(accentGNMint)
                                    .frame(width: 44, height: 44)
                                    .background(accentGNMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(accentGNMint.opacity(0.42), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("再起動して反映")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                dragDemo.stop()
                settings.hasCompletedOnboarding = true
                onContinue()
            } label: {
                Text(isAllReady ? "開始" : "あとで")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7.5)
                    .background(
                        isAllReady ? accentGreen.opacity(0.85) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Components

    private func rowContainer<Content: View>(
        step: String?,
        badgeSymbol: String? = nil,
        title: String,
        subtitle: String? = nil,
        isCompleted: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill((isCompleted ? accentGreen : accentGNEmerald).opacity(0.18))
                            .frame(width: 22, height: 22)
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(accentGreen)
                        } else if let step {
                            Text(step)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(accentGNEmerald)
                        } else if let badgeSymbol {
                            Image(systemName: badgeSymbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(accentGNEmerald)
                        }
                    }

                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(isCompleted ? 0.65 : 0.96))

                    Spacer()
                }

                if !isCompleted, let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(12)
        .background(Color(red: 0.14, green: 0.95, blue: 0.52).opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isCompleted ? accentGreen.opacity(0.36) : accentGNEmerald.opacity(0.18),
                    lineWidth: 1
                )
        )
    }

    private func arrowGlyph(highlighted: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        highlighted
                            ? accentGreen
                            : accentGNMint.opacity(0.38 + Double(index) * 0.28)
                    )
            }
        }
    }

    // MARK: - Drag Demo Coordination

    private func configureDragDemoCallbacks() {
        dragDemo.onFlightStateChanged = { mode, inFlight in
            demoFlightMode = mode
            isDemoInFlight = inFlight
        }
        dragDemo.onTargetHighlightChanged = { mode, highlighted in
            isDemoHighlightingApplications = (mode == .applications && highlighted)
        }
    }

    private func openSystemSettingsAndStartDemo() {
        settings.requestScreenCapturePermission()
        Task { @MainActor in
            // システム設定のコールド起動も含め最大 ~2.5 秒待機し、表示された瞬間に重なりを解消してデモ開始
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(250))
                guard isPollingActive, !settings.hasScreenCapturePermission else { return }
                let visible = DragDemoOverlayController.systemSettingsAppKitFrame() != nil
                isSystemSettingsVisible = visible
                if visible {
                    dragDemo.nudgeOnboardingBesideSystemSettingsIfOverlapping()
                    syncDragDemoMode()
                    return
                }
            }
            syncDragDemoMode()
        }
    }

    private func syncDragDemoMode() {
        guard AppInstallHelper.draggableAppURL != nil, !isInstalling else {
            dragDemo.setMode(.none)
            return
        }

        // システム設定が開いていて画面収録が未許可なら、Rex 同様にシステム設定リストへのクロスウィンドウデモを優先
        if !settings.hasScreenCapturePermission && isSystemSettingsVisible {
            dragDemo.setMode(.systemSettings)
            return
        }

        // Applications 未配置時は Step 1 のドラッグデモを再生
        if !installState.isInstalled {
            dragDemo.setMode(.applications)
            return
        }

        dragDemo.setMode(.none)
    }

    // MARK: - Actions & Polling

    private func performInstallToApplications() {
        guard !isInstalling else { return }
        let effectOrigin = dragDemo.installTargetScreenCenter()
        dragDemo.setMode(.none)
        isInstalling = true
        installErrorMessage = nil

        do {
            let destinationURL = try AppInstallHelper.copyToApplications()
            baselineExternalInstallStamp = AppInstallHelper.installedApplicationsBundleSnapshot()?.stamp
            didCelebrateExternalInstall = true
            withAnimation(.easeOut(duration: 0.22)) {
                installState = .installedInApplications(destinationURL)
            }

            let relaunch: @MainActor () -> Void = {
                AppInstallHelper.launchInstalledAppAndTerminate(at: destinationURL)
            }

            if let effectOrigin {
                GNParticleRingEffectController.play(at: effectOrigin, onComplete: relaunch)
            } else {
                GNParticleRingEffectController.play(centeredOn: NSApp.keyWindow, onComplete: relaunch)
            }
        } catch {
            isInstalling = false
            installErrorMessage = error.localizedDescription
            syncDragDemoMode()
        }
    }

    private func pollPermissionLoop() async {
        while isPollingActive && !Task.isCancelled {
            settings.refreshScreenCapturePermission()
            if !isInstalling {
                if !didCelebrateExternalInstall {
                    let current = AppInstallHelper.currentInstallState()
                    if !current.isInstalled,
                       let external = AppInstallHelper.installedApplicationsBundleSnapshot(),
                       external.stamp != baselineExternalInstallStamp {
                        // Veda 起動中に Finder 等から /Applications へコピーされた瞬間を検知して GN 粒子リング 2 つを再生
                        didCelebrateExternalInstall = true
                        baselineExternalInstallStamp = external.stamp
                        dragDemo.setMode(.none)
                        withAnimation(.easeOut(duration: 0.22)) {
                            installState = .installedInApplications(external.url)
                        }
                        GNParticleRingEffectController.play(at: NSEvent.mouseLocation)
                    } else {
                        installState = current
                    }
                }
            }
            isSystemSettingsVisible = DragDemoOverlayController.systemSettingsAppKitFrame() != nil
            syncDragDemoMode()
            settings.triggerAutoDirectCaptureAuthIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
        }
    }
}

// MARK: - Anchor Bridge for Target Drop Area

private struct ViewAnchorBridge: NSViewRepresentable {
    let onViewReady: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onViewReady(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onViewReady(nsView)
        }
    }
}

// MARK: - Native NSDraggingSource Tile (Never moves window; works when window is inactive)

private struct DraggableAppTile: NSViewRepresentable {
    let appURL: URL
    var isDimmedByDemo: Bool = false
    var onIconViewReady: ((NSView) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DraggableAppTileNSView {
        let view = DraggableAppTileNSView(appURL: appURL)
        view.onInteractionChanged = onInteractionChanged
        DispatchQueue.main.async {
            onIconViewReady?(view.iconAnchorView)
        }
        return view
    }

    func updateNSView(_ nsView: DraggableAppTileNSView, context: Context) {
        nsView.onInteractionChanged = onInteractionChanged
        nsView.configure(appURL: appURL, isDimmedByDemo: isDimmedByDemo)
        DispatchQueue.main.async {
            onIconViewReady?(nsView.iconAnchorView)
        }
    }
}

private final class DraggableAppTileNSView: NSView, NSDraggingSource {
    private var appURL: URL
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Veda")
    private var mouseDownEvent: NSEvent?
    private var isHovered: Bool = false
    private var isDraggingSessionActive: Bool = false
    private var isDimmedByDemo: Bool = false
    private var trackingAreaRef: NSTrackingArea?

    var onInteractionChanged: ((Bool) -> Void)?

    var iconAnchorView: NSView {
        iconView
    }

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        configure(appURL: appURL, isDimmedByDemo: false)
        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ドラッグ時に親ウィンドウが一緒に動かないようにする
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// システム設定が前面にある（非アクティブな）状態からも 1 ドラッグで掴めるようにする
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 108, height: 44)
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white

        addSubview(iconView)
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 108),
            heightAnchor.constraint(equalToConstant: 44),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    func configure(appURL: URL, isDimmedByDemo: Bool) {
        self.appURL = appURL
        self.isDimmedByDemo = isDimmedByDemo
        if iconView.image == nil {
            iconView.image = AppInstallHelper.appIconImage(size: 28)
        }
        updateIconOpacity()
    }

    private func updateIconOpacity() {
        let shouldDim = isDraggingSessionActive || isDimmedByDemo
        let targetAlpha: CGFloat = shouldDim ? 0.26 : 1.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            iconView.animator().alphaValue = targetAlpha
        }
    }

    private func updateLayerStyle() {
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.backgroundColor = NSColor(
            calibratedRed: 0.14,
            green: 0.94,
            blue: 0.48,
            alpha: isHovered ? 0.22 : 0.11
        ).cgColor
        layer.borderWidth = isHovered ? 1.4 : 1.0
        layer.borderColor = NSColor(
            calibratedRed: 0.26,
            green: 0.98,
            blue: 0.56,
            alpha: isHovered ? 0.88 : 0.48
        ).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLayerStyle()
        onInteractionChanged?(true)
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLayerStyle()
        if !isDraggingSessionActive {
            onInteractionChanged?(false)
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        onInteractionChanged?(true)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        if !isHovered && !isDraggingSessionActive {
            onInteractionChanged?(false)
        }
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - startEvent.locationInWindow.x
        let dy = event.locationInWindow.y - startEvent.locationInWindow.y
        guard hypot(dx, dy) >= 2.0 else { return }

        mouseDownEvent = nil
        isDraggingSessionActive = true
        onInteractionChanged?(true)
        updateIconOpacity()

        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let dragImage = AppInstallHelper.appIconImage(size: 52)
        let localPoint = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: localPoint.x - 26, y: localPoint.y - 26, width: 52, height: 52),
            contents: dragImage
        )

        beginDraggingSession(with: [draggingItem], event: startEvent, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return [.copy, .move]
        case .outsideApplication:
            return [.copy, .generic]
        @unknown default:
            return .copy
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDraggingSessionActive = false
        updateIconOpacity()
        if !isHovered {
            onInteractionChanged?(false)
        }
    }
}
