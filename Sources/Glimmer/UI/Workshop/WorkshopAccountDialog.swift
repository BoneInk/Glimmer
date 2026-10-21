import SwiftUI

/// Both workspace panes use the same account content and coordinator-owned session.
/// Dismissing this sheet changes presentation only; authentication continues normally.
struct WorkshopAccountDialog: View {
    @Bindable var coordinator: WorkshopCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GlassStyleReader { style in
            VStack(spacing: 0) {
                HStack {
                    // The reused account content owns the visible title.
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭 Steam 登录")
                    .accessibilityLabel("关闭 Steam 登录")
                }
                .padding(16)
                Divider()
                // The account view owns its ScrollView; avoid a nested scroll container.
                WorkshopAccountView(coordinator: coordinator, style: style)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 460)
        .background { PopupSurfaceBackground() }
        .onAppear {
            let account = coordinator.account
            if account.nativeContentAvailable, !account.isNativeContentReady,
               !account.loginState.isActive, !account.nativeSavedSessionRetryAvailable {
                account.startNativeSignIn()
            }
        }
        .onChange(of: coordinator.account.isNativeContentReady) { wasReady, isReady in
            // No initial callback: opening an existing connection stays available for management.
            if !wasReady && isReady {
                let account = coordinator.account
                if account.nativeSessionPersistenceEnabled,
                   account.nativeContentBroker?.hasSavedSession != true { return }
                dismiss()
            }
        }
    }
}
