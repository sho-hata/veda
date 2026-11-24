import SwiftUI

struct ControlView: View {
    let settings: TransAmSettings

    private var isTransAmLit: Bool {
        settings.isEnabled || settings.isActivating
    }

    private var accentColor: Color {
        isTransAmLit
            ? Color(red: 1.0, green: 0.14, blue: 0.70)
            : Color(red: 0.30, green: 0.96, blue: 0.34)
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
