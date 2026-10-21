import SwiftUI

/// Local values passed into the production card. These are not downloader events.
struct WorkshopRingReviewView: View {
    @GlassState private var updated = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 3)

    private struct Fixture: Identifiable {
        let id: String
        let label: String
        let state: WorkshopDownloadState
        let fraction: Double?
    }

    private var fixtures: [Fixture] {
        [
            Fixture(id: "zero", label: "已知进度 · 0%", state: .downloading(fraction: 0, text: "模拟传输"), fraction: 0),
            Fixture(id: "reactive", label: "已知进度 · \(updated ? 68 : 42)%", state: .downloading(fraction: updated ? 0.68 : 0.42, text: "模拟传输"), fraction: updated ? 0.68 : 0.42),
            Fixture(id: "hundred", label: "下载达 100% · 尚未校验", state: .downloading(fraction: 1, text: "模拟传输"), fraction: 1),
            Fixture(id: "unknown", label: "未知进度", state: .downloading(fraction: nil, text: "模拟传输"), fraction: nil),
            Fixture(id: "queued", label: "排队中", state: .queued, fraction: nil),
            Fixture(id: "validating", label: "校验中", state: .validating("模拟校验"), fraction: 1),
            Fixture(id: "completed", label: "已完成", state: .completed, fraction: 1),
            Fixture(id: "failed", label: "失败 · 可重试", state: .failed(message: "模拟失败"), fraction: 0.42),
            Fixture(id: "cancelled", label: "已取消 · 可重试", state: .cancelled, fraction: 0.42)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("下载按钮状态验证")
                            .font(.title2.bold())
                        Text("全部为本地模拟进度；使用实际作品卡片，无网络下载、账号或桌面操作。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(updated ? "重置模拟进度" : "更新模拟进度") {
                        updated.toggle()
                    }
                    .accessibilityIdentifier("review.update-simulated-progress")
                }
                Text("点击更新后，中间首张卡片从 42% 变为 68%；下载 100% 与校验完成分别展示。封面为内置占位图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(fixtures) { fixture in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(fixture.label)
                                .font(.callout.weight(.semibold))
                                .accessibilityIdentifier("review.fixture.\(fixture.id)")
                            WorkshopResultCard(
                                result: result(for: fixture),
                                isSaved: false,
                                downloadItem: item(for: fixture),
                                onSelect: {}, onSave: {}, onDownload: {}, onOpenSource: {}
                            )
                        }
                    }
                }
            }
            .padding(24)
            .padding(.top, 20)
        }
        .frame(minWidth: 900, minHeight: 680)
    }

    private func result(for fixture: Fixture) -> WorkshopSearchResult {
        WorkshopSearchResult(
            publishedFileID: "review-\(fixture.id)", title: "模拟作品 · \(fixture.label)",
            shortDescription: "界面验证用模拟作品", consumerAppID: 431960, previewURL: nil,
            timeCreated: nil, timeUpdated: nil, fileSizeBytes: 128_000_000, tags: ["Video"],
            subscriptions: 1234, favorited: nil, views: nil, commentCount: nil,
            starRating: nil, totalVotes: nil, childCount: 0, isCollection: false
        )
    }

    private func item(for fixture: Fixture) -> WorkshopDownloadItem {
        var item = WorkshopDownloadItem(
            publishedFileID: "review-\(fixture.id)", title: "模拟作品 · \(fixture.label)",
            kind: .video, declaredTags: ["Video"], previewImageURLString: nil,
            fileSizeBytes: 128_000_000, state: fixture.state
        )
        item.progressFraction = fixture.fraction
        item.progressText = "模拟进度"
        return item
    }
}
