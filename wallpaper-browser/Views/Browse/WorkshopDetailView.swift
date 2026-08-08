import AppKit
import SwiftUI

struct WorkshopDetailView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @StateObject private var commentsViewModel: WorkshopCommentsViewModel
  @State private var isShowingPreview = false
  @State private var metadataColumnHeight: CGFloat = 320
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
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .top, spacing: 26) {
          previewButton
            .layoutPriority(1)

          metadataColumn
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .topLeading)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: MetadataColumnHeightPreferenceKey.self,
                  value: geometry.size.height
                )
              }
            }
        }
        .frame(maxWidth: 980, alignment: .topLeading)
        .onPreferenceChange(MetadataColumnHeightPreferenceKey.self) { height in
          metadataColumnHeight = max(320, height)
        }

        Divider()
        commentsSection
      }
      .padding(24)
      .frame(maxWidth: 1040, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("detail.title")
    .task {
      await commentsViewModel.loadInitial()
    }
    .sheet(isPresented: $isShowingPreview) {
      EnlargedWorkshopPreview(url: item.previewURL, title: item.title)
    }
  }

  private var previewButton: some View {
    Button {
      isShowingPreview = true
    } label: {
      ZStack(alignment: .topTrailing) {
        WorkshopPreviewImage(url: item.previewURL)

        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: 12, weight: .semibold))
          .padding(8)
          .background(.regularMaterial, in: Circle())
          .padding(10)
      }
      .frame(maxWidth: .infinity)
      .frame(height: metadataColumnHeight)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("detail.enlargePreview")
  }

  private var metadataColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(item.title)
          .font(.title2)
          .fontWeight(.semibold)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        let genres = item.genreTags.prefix(3).joined(separator: " · ")
        if !genres.isEmpty {
          Text(genres)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      downloadButton

      if !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Divider()
        MetadataSection(title: "detail.summary") {
          Text(item.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(5)
            .textSelection(.enabled)
        }
      }

      Divider()
      MetadataSection(title: "detail.information") {
        VStack(alignment: .leading, spacing: 8) {
          if let authorText = item.authorText {
            DetailRow(label: "detail.author", value: appSettings.localized(authorText))
          }
          if let ratingText = item.ratingText {
            DetailRow(label: "detail.rating", value: ratingText)
          }
          if item.positiveVotes + item.negativeVotes > 0 {
            DetailRow(
              label: "detail.reviews",
              value: String(
                format: appSettings.localized("detail.voteSummary"),
                item.positiveVotes,
                item.negativeVotes
              )
            )
          }
          DetailRow(label: "detail.subscriptions", value: formatCount(item.subscriptions))
          DetailRow(
            label: "detail.size",
            value: item.fileSize > 0
              ? ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file) : "common.unknown"
          )
          DetailRow(label: "detail.workshopID", value: item.id)
        }
      }

      if !item.tags.isEmpty {
        Divider()
        MetadataSection(title: "detail.tags") {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 7)],
            alignment: .leading,
            spacing: 7
          ) {
            ForEach(item.tags, id: \.self) { tag in
              Text(tag)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
          }
        }
      }
    }
  }

  private var commentsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("detail.comments")
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
          Text("detail.loadingComments")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
      } else if let error = commentsViewModel.errorMessage,
        commentsViewModel.comments.isEmpty
      {
        HStack(spacing: 12) {
          Image(systemName: "exclamationmark.bubble")
            .foregroundStyle(.secondary)
          Text(appSettings.localized(error))
            .foregroundStyle(.secondary)
          Spacer()
          Button("common.retry") {
            Task { await commentsViewModel.retry() }
          }
        }
        .padding(.vertical, 12)
      } else if commentsViewModel.comments.isEmpty {
        Text("detail.noComments")
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
              Text("detail.loadMoreComments")
            }
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  @ViewBuilder
  private var downloadButton: some View {
    switch record?.phase {
    case .queued, .extracting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(
          record.map { appSettings.localized($0.phase.localizationKey) }
            ?? appSettings.localized("download.phase.downloading")
        )
      }
      .foregroundStyle(.secondary)
    case .downloading:
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(appSettings.localized(record?.detail ?? "download.detail.downloading"))
        }
        .foregroundStyle(.secondary)

        if let progress = record?.progress {
          ProgressView(value: progress, total: 1)
            .progressViewStyle(.linear)
          HStack {
            Text(String(format: "%.0f%%", progress * 100))
            Spacer()
            if let bytesPerSecond = record?.bytesPerSecond, bytesPerSecond > 0 {
              Text(formatSpeed(bytesPerSecond))
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .progressViewStyle(.linear)
        }
      }
      .frame(maxWidth: 240)
    case .completed:
      Button {
        if let url = record?.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Label("common.showInFinder", systemImage: "folder")
      }
      .buttonStyle(.borderedProminent)
    case .failed, .cancelled:
      Button(action: download) {
        Label("download.retry", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderedProminent)
    case .none:
      if steamCMD.hasDownloaded(item.id) {
        Button(action: download) {
          Label("download.again", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button(action: download) {
          Label("download.video", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func formatCount(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  private func formatSpeed(_ bytesPerSecond: Double) -> String {
    let formatted = ByteCountFormatter.string(
      fromByteCount: Int64(bytesPerSecond),
      countStyle: .file
    )
    return "\(formatted)/s"
  }
}

private struct MetadataColumnHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 320

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct EnlargedWorkshopPreview: View {
  @Environment(\.dismiss) private var dismiss
  let url: URL?
  let title: String

  var body: some View {
    ZStack {
      Color.black.opacity(0.94)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
          dismiss()
        }

      WorkshopPreviewImage(url: url)
        .padding(28)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .topTrailing) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.bordered)
      .keyboardShortcut(.cancelAction)
      .help("detail.closePreview")
      .padding(18)
    }
    .frame(minWidth: 760, minHeight: 520)
    .navigationTitle(title)
  }
}

private struct MetadataSection<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      content
    }
  }
}

private struct WorkshopCommentRow: View {
  @Environment(\.locale) private var locale
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
    formatter.locale = locale
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct DetailRow: View {
  let label: LocalizedStringKey
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 54, alignment: .trailing)
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer()
    }
  }
}
