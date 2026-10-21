import SwiftUI

/// 创意工坊工作区；Steam 账号通过状态徽章打开独立登录弹窗。
///
/// 用法（主控接线）：
/// ```swift
/// @GlassState private var workshop = WorkshopCoordinator()
/// WorkshopView(coordinator: workshop)
///     .onAppear {
///         workshop.onImportVideo = { url, metadata in
///             await importService.importURLs([url]); return nil
///         }
///     }
/// ```
struct WorkshopView: View {
    @Bindable var coordinator: WorkshopCoordinator

    @GlassState private var showsAccountDialog = false

    var body: some View {
        GlassStyleReader { style in
            WorkshopSearchView(
                coordinator: coordinator,
                style: style,
                onOpenAccount: { showsAccountDialog = true }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WorkshopAtmosphere() }
        }
        .sheet(isPresented: $showsAccountDialog) {
            WorkshopAccountDialog(coordinator: coordinator)
        }
        .onAppear { coordinator.prepareIfNeeded() }
    }

}
