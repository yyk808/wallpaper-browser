import AppKit
import SwiftUI

struct WorkshopDetailView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @StateObject private var commentsViewModel: WorkshopCommentsViewModel
  let item: WorkshopItem
  let download: () -> Void

  init(item: WorkshopItem, download: @escaping () -> Void) {
    self.item = item
    self.download = download
    _commentsViewModel = StateObject(wrappedValue: WorkshopCommentsViewModel(item: item))
  }

  private var record: DownloadRecord? { steamCMD.record(for: item.id) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        preview

        HStack(alignment: .top, spacing: 18) {
          VStack(alignment: .leading, spacing: 7) {
            Text(item.title)
              .font(.title2)
              .fontWeight(.semibold)
              .textSelection(.enabled)

            Text(item.genreTags.prefix(3).joined(separator: " · "))
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 12)
          downloadButton
        }

        if !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text("简介")
              .font(.headline)
            Text(item.summary)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          Text("信息")
            .font(.headline)
          DetailRow(label: "订阅数", value: formatCount(item.subscriptions))
          DetailRow(
            label: "文件大小",
            value: item.fileSize > 0
              ? ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file) : "未知"
          )
          DetailRow(label: "创意工坊 ID", value: item.id)
        }

        if !item.tags.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Text("标签")
              .font(.headline)
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(item.tags, id: \.self) { tag in
                Text(tag)
                  .font(.caption)
                  .padding(.horizontal, 9)
                  .padding(.vertical, 5)
                  .background(.quaternary, in: Capsule())
              }
            }
          }
        }

        Divider()
        commentsSection
      }
      .padding(24)
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("壁纸详情")
    .task {
      await commentsViewModel.loadInitial()
    }
  }

  private var commentsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("评论")
          .font(.headline)
        if commentsViewModel.totalCount > 0 {
          Text(formatCount(commentsViewModel.totalCount))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if commentsViewModel.isLoading && commentsViewModel.comments.isEmpty {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("正在加载评论…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
      } else if let error = commentsViewModel.errorMessage,
        commentsViewModel.comments.isEmpty
      {
        HStack(spacing: 12) {
          Image(systemName: "exclamationmark.bubble")
            .foregroundStyle(.secondary)
          Text(error)
            .foregroundStyle(.secondary)
          Spacer()
          Button("重试") {
            Task { await commentsViewModel.retry() }
          }
        }
        .padding(.vertical, 12)
      } else if commentsViewModel.comments.isEmpty {
        Text("暂时还没有评论")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 72)
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(commentsViewModel.comments.enumerated()), id: \.element.id) {
            index, comment in
            WorkshopCommentRow(comment: comment)
            if index < commentsViewModel.comments.count - 1 {
              Divider().padding(.leading, 46)
            }
          }
        }

        if commentsViewModel.canLoadMore {
          Button {
            Task { await commentsViewModel.loadMore() }
          } label: {
            if commentsViewModel.isLoading {
              ProgressView().controlSize(.small)
            } else {
              Text("加载更多评论")
            }
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private var preview: some View {
    AsyncImage(url: item.previewURL) { phase in
      switch phase {
      case .success(let image):
        image.resizable().scaledToFill()
      case .failure:
        previewPlaceholder
      default:
        previewPlaceholder.overlay { ProgressView() }
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .clipped()
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  @ViewBuilder
  private var downloadButton: some View {
    switch record?.phase {
    case .queued, .downloading, .extracting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(record?.phase.title ?? "正在下载")
      }
      .foregroundStyle(.secondary)
    case .completed:
      Button {
        if let url = record?.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Label("在 Finder 中显示", systemImage: "folder")
      }
      .buttonStyle(.borderedProminent)
    case .failed, .cancelled:
      Button(action: download) {
        Label("重试下载", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderedProminent)
    case .none:
      Button(action: download) {
        Label("下载视频", systemImage: "arrow.down.circle")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var previewPlaceholder: some View {
    Rectangle()
      .fill(Color(nsColor: .quaternaryLabelColor))
      .overlay {
        Image(systemName: "photo")
          .font(.largeTitle)
          .foregroundStyle(.tertiary)
      }
  }

  private func formatCount(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }
}

private struct WorkshopCommentRow: View {
  let comment: WorkshopComment

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AsyncImage(url: comment.avatarURL) { phase in
        if case .success(let image) = phase {
          image.resizable().scaledToFill()
        } else {
          Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 34, height: 34)
      .clipShape(Circle())

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(comment.authorName)
            .font(.subheadline)
            .fontWeight(.medium)
          if let postedAt = comment.postedAt {
            Text(relativeTime(for: postedAt))
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        Text(comment.text)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 12)
  }

  private func relativeTime(for date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 90, alignment: .trailing)
      Text(value)
        .textSelection(.enabled)
      Spacer()
    }
  }
}
