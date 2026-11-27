import SwiftUI

struct ControlView: View {
    let settings: TransAmSettings
    let onOpenSetup: () -> Void

    private var isTransAmLit: Bool {
        settings.isEnabled || settings.isActivating
    }

    private var accentColor: Color {
        isTransAmLit
            ? Color(red: 1.0, green: 0.14, blue: 0.70)
            : Color(red: 0.30, green: 0.96, blue: 0.34)
    }

    private var needsSetupBadge: Bool {
        !settings.isScreenCaptureReady || AppInstallHelper.currentInstallState().requiresInstallAttention
    }

    var body: some View {
        ZStack {
            backgroundLayer

            TransAmConsoleView(
                phase: settings.phase,
                onToggle: {
                    if settings.isEnabled {
                        settings.deactivateTransAm()
                    } else {
                        settings.activateTransAm()
                    }
                },
                onComplete: {
                    settings.finishActivationSequence()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 26)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if needsSetupBadge {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onOpenSetup) {
                            HStack(spacing: 5) {
                                Image(systemName: AppInstallHelper.currentInstallState().requiresInstallAttention ? "arrow.down.app" : "lock.shield")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(
                                    AppInstallHelper.currentInstallState().requiresInstallAttention
                                        ? "インストール"
                                        : "Enable Trans-Am Effect"
                                )
                                .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.90))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(
                                accentColor.opacity(0.20),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(accentColor.opacity(0.55), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .padding(.trailing, 12)
                    }
                    Spacer()
                }
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: isTransAmLit
                    ? [
                        Color(red: 0.05, green: 0.01, blue: 0.09),
                        Color(red: 0.03, green: 0.01, blue: 0.06),
                        Color(red: 0.01, green: 0.005, blue: 0.03)
                    ]
                    : [
                        Color(red: 0.015, green: 0.055, blue: 0.020),
                        Color(red: 0.010, green: 0.032, blue: 0.012),
                        Color(red: 0.005, green: 0.018, blue: 0.008)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    accentColor.opacity(isTransAmLit ? 0.38 : 0.18),
                    lineWidth: 1
                )
                .padding(1)
        }
        .animation(.easeOut(duration: 0.16), value: settings.phase)
    }
}
