import SwiftUI

/// Shown in the detail pane when no session is selected.
///
/// (The legacy "record in the main window" flow is gone. Recording now
/// happens in the dedicated floating RecorderWidget after the user picks
/// their settings in the SetupWindow.)
struct WelcomeView: View {
    @EnvironmentObject var manager: TranscriptionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [AppTheme.accent.opacity(0.45), AppTheme.accent.opacity(0)],
                                center: .center, startRadius: 1, endRadius: 80
                            )
                        )
                        .frame(width: 140, height: 140)
                    ZStack {
                        Circle()
                            .fill(AppTheme.panelElevated)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Circle().stroke(AppTheme.accentBorder, lineWidth: 0.7)
                            )
                        Image(systemName: "mic.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .shadow(color: AppTheme.accentGlow, radius: 14)
                }

                VStack(spacing: 6) {
                    Text("Ready to record")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(manager.isLoadingModel
                         ? "Preparing the model…"
                         : "Click Start Recording to configure and begin a new session.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                Button {
                    openWindow(id: WindowID.setup)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Start Recording")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.accent, AppTheme.accentDim],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: AppTheme.accentGlow, radius: 10)
                }
                .buttonStyle(.plain)
                // Always enabled — clicking opens Setup, which handles
                // model loading. Gating on `modelLoaded` left the button
                // permanently disabled because we deferred loading.
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
