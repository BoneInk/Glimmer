import SwiftUI
import UniformTypeIdentifiers

/// 中间列表区：工具栏搜索 + 排序 + 网格 + 空/加载/错误状态 + 拖放导入。
struct LibraryGridView: View {
    let items: [WallpaperItem]
    let missingIDs: Set<UUID>
    let selection: UUID?
    let query: LibraryQuery
    let isLibraryEmpty: Bool
    let importService: ImportService
    let errorMessage: String?
    let style: GlassStyle
    let onSelect: (UUID) -> Void
    let onApply: (WallpaperItem) -> Void
    let onToggleFavorite: (WallpaperItem) -> Void
    let onDismissError: () -> Void
    /// 空素材库时的主操作：导入视频（可选，未接线时不显示）。
    var onImportAction: (() -> Void)? = nil
    /// 空素材库时的次操作：浏览创意工坊（可选，未接线时不显示）。
    var onBrowseWorkshop: (() -> Void)? = nil
    var onOpenDetails: ((WallpaperItem) -> Void)? = nil
    var onDelete: ((WallpaperItem) -> Void)? = nil

    @GlassState private var isDropTargeted = false
    var body: some View {
        ZStack {
            content
            if isDropTargeted {
                dropOverlay
            }
        }
        .animation(style.cardAnimation, value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return false }
            Task { await importService.importURLs(fileURLs) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
            if !visibleImportJobs.isEmpty {
                importProgressArea
            }
            if items.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    /// 终态由页级 toast 汇总；列表只保留真实进行中的任务和取消入口。
    private var visibleImportJobs: [ImportJob] {
        Array(importService.jobs.filter { !$0.state.isTerminal }.suffix(4))
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: WallpaperCardLayout.columns,
                spacing: WallpaperCardLayout.spacing
            ) {
                ForEach(items) { item in
                    WallpaperCardView(
                        item: item,
                        isSelected: selection == item.id,
                        isMissing: missingIDs.contains(item.id),
                        style: style,
                        onToggleFavorite: { onToggleFavorite(item) },
                        onSelect: {
                            // 只选中：应用桌面必须由用户显式点击「应用」按钮或右键菜单。
                            onSelect(item.id)
                        },
                        onApply: {
                            onSelect(item.id)
                            onApply(item)
                        },
                        onOpenDetails: { onSelect(item.id); onOpenDetails?(item) },
                        onDelete: onDelete.map { action in { action(item) } }
                    )
                }
            }
            .padding(.horizontal, WallpaperCardLayout.horizontalPadding)
            .padding(.top, WallpaperCardLayout.topPadding)
            .padding(.bottom, WallpaperCardLayout.bottomPadding)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: isLibraryEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(query.emptyStateMessage(isLibraryEmpty: isLibraryEmpty))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if isLibraryEmpty {
                HStack(spacing: 10) {
                    if let onImportAction {
                        Button(action: onImportAction) {
                            Label("导入视频…", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if let onBrowseWorkshop {
                        Button(action: onBrowseWorkshop) {
                            Label("浏览创意工坊", systemImage: "storefront")
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(28)
        .background(style.panelBackground(cornerRadius: 26))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(style.stateTransition)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout)
            Spacer()
            Button("关闭", action: onDismissError)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(style.panelBackground(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var importProgressArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleImportJobs) { job in
                HStack(spacing: 8) {
                    switch job.state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .duplicated:
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    case .failed, .cancelled:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    default:
                        ProgressView().controlSize(.small)
                    }
                    Text("\(job.displayName) · \(job.state.displayText)")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    if let detail = job.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            if !importService.activeJobs.isEmpty {
                HStack {
                    Spacer()
                    Button("取消导入") { importService.cancelAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(style.panelBackground(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 30))
                    Text("松开即可导入视频文件或文件夹").font(.headline)
                }
                .foregroundStyle(Color.accentColor)
            )
            .padding(12)
            .allowsHitTesting(false)
    }
}
