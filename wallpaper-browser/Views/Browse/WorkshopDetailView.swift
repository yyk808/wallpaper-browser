import AppKit
import SwiftUI

struct WorkshopDetailView: View {
  @EnvironmentObject private var steamCMD: SteamCMDService
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var favoriteLibrary: FavoriteLibrary
  @StateObject private var commentsViewModel: WorkshopCommentsViewModel
  @State private var isShowingPreview = false
  private let seedItem: WorkshopItem
  @State private var details: WorkshopDetails?
  @State private var creator: WorkshopCreator?
  @State private var detailsError: String?
  @State private var detailsAttempt = 0
  @State private var selectedPreviewURL: URL?
  private var item: WorkshopItem { details?.item ?? seedItem }
  private var previewURL: URL? { selectedPreviewURL ?? item.previewURL }
  let dismiss: () -> Void
  let download: () -> Void
  let showDownloads: () -> Void
  let setSidebarVisible: (Bool) -> Void
  let transitionSourceID: String
  let transitionNamespace: Namespace.ID

  init(
    item: WorkshopItem,
    dismiss: @escaping () -> Void,
    download: @escaping () -> Void,
    showDownloads: @escaping () -> Void,
    setSidebarVisible: @escaping (Bool) -> Void,
    transitionSourceID: String,
    transitionNamespace: Namespace.ID
  ) {
    self.seedItem = item
    self.dismiss = dismiss
    self.download = download
    self.showDownloads = showDownloads
    self.setSidebarVisible = setSidebarVisible
    self.transitionSourceID = transitionSourceID
    self.transitionNamespace = transitionNamespace
    _commentsViewModel = StateObject(wrappedValue: WorkshopCommentsViewModel(item: item))
  }

  private var record: DownloadRecord? { steamCMD.record(for: item.id) }

  var body: some View {
    VStack(spacing: 0) {
      detailHeader
      Divider()

      GeometryReader { geometry in
        HStack(alignment: .top, spacing: 30) {
          previewColumn
            .frame(maxWidth: min(560, max(0, geometry.size.height - 56)))
            .frame(
              minWidth: 460,
              maxWidth: 760,
              maxHeight: .infinity,
              alignment: .topLeading
            )

          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              metadataColumn

              Divider()
              commentsSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.trailing, 10)
          }
          .frame(
            minWidth: 300,
            idealWidth: 360,
            maxWidth: 420,
            maxHeight: .infinity,
            alignment: .topLeading
          )
        }
        .padding(28)
        .frame(maxWidth: 1280, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .navigationTitle("")
    .navigationBarBackButtonHidden(true)
    .onDisappear {
      Task { @MainActor in
        await Task.yield()
        setSidebarVisible(true)
      }
    }
    .task {
      await commentsViewModel.loadInitial()
    }
    .task(id: detailsAttempt) {
      detailsError = nil
      do {
        let loaded = try await WorkshopAPIClient().fetchDetails(id: seedItem.id)
        try Task.checkCancellation()
        details = loaded
        if loaded.item.previewURL == nil {
          selectedPreviewURL = loaded.previews.first(where: { $0.kind == .image })?.url
        }
        if let id = loaded.item.creatorSteamID {
          let profile = try? await WorkshopAPIClient().fetchCreator(id: id)
          if !Task.isCancelled {
            creator = profile
            favoriteLibrary.refreshAuthor(
              id: id,
              fallbackName: loaded.item.authorText ?? id,
              creator: profile
            )
          }
        }
      } catch {
        if !Task.isCancelled { detailsError = error.localizedDescription }
      }
    }
    .sheet(isPresented: $isShowingPreview) {
      EnlargedWorkshopPreview(url: previewURL, title: item.title)
    }
  }

  private var detailHeader: some View {
    ZStack {
      Text("detail.title")
        .font(.headline)

      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.backward")
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help("common.cancel")

        Spacer()

        HStack(spacing: 8) {
          Button {
            if let workshopPageURL = item.workshopPageURL {
              NSWorkspace.shared.open(workshopPageURL)
            }
          } label: {
            Label("home.openInWorkshop", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(.bordered)
          .disabled(item.workshopPageURL == nil)
          .help("home.openInWorkshop")

          Button(action: showDownloads) {
            Label("nav.downloads", systemImage: "arrow.down.circle")
              .overlay(alignment: .topTrailing) {
                if steamCMD.activeDownloadCount > 0 {
                  Text("\(steamCMD.activeDownloadCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 7, y: -7)
                }
              }
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
  }

  private var previewColumn: some View {
    VStack(alignment: .leading, spacing: 12) {
      previewButton
      if let details, details.previews.contains(where: { $0.kind == .videoLink || $0.url != item.previewURL }) {
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(details.previews) { media in
              if media.kind == .image {
                Button { selectedPreviewURL = media.url } label: {
                  WorkshopPreviewImage(url: media.url, allowsAnimation: false)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(previewURL == media.url ? Color.accentColor : .clear, lineWidth: 2)
                    }
                }.buttonStyle(.plain).help("detail.enlargePreview")
              } else {
                Link(destination: media.url) {
                  Label("explore.videoPreview", systemImage: "play.rectangle")
                    .padding(10)
                }
              }
            }
          }.padding(3)
        }
      }
      Button { explorer.open(.collections(containing: item.id)) } label: {
        Label("explore.containing", systemImage: "square.stack")
      }.buttonStyle(.bordered)
      Spacer(minLength: 0)
    }
  }

  private var previewButton: some View {
    Button {
      isShowingPreview = true
    } label: {
      ZStack(alignment: .topTrailing) {
        WorkshopPreviewImage(url: previewURL, allowsAnimation: true)

        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: 12, weight: .semibold))
          .padding(8)
          .background(.regularMaterial, in: Circle())
          .padding(10)
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: 560)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.primary.opacity(0.07), lineWidth: 1)
      }
      .workshopDetailTransitionDestination(
        id: transitionSourceID,
        in: transitionNamespace
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("detail.enlargePreview")
  }

  private var metadataColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(item.title)
          .font(.title2.weight(.bold))
          .fontWeight(.semibold)
          .workshopCopyable(item.title)
          .fixedSize(horizontal: false, vertical: true)

        let genres = item.genreTags.prefix(3).joined(separator: " · ")
        if !genres.isEmpty {
          Text(genres)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      quickStats
      if item.isVideo {
        downloadButton
      } else {
        Label("explore.unsupported", systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let detailsError {
        HStack {
          Text(appSettings.localized(detailsError)).font(.caption).foregroundStyle(.secondary)
          Button("common.retry") { detailsAttempt += 1 }
        }
      } else if details == nil {
        ProgressView().controlSize(.small)
      }

      if !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Divider()
        MetadataSection(title: "detail.summary") {
          WorkshopDescriptionView(text: details?.description ?? item.summary)
        }
      }

      Divider()
      MetadataSection(title: "detail.information") {
        VStack(alignment: .leading, spacing: 8) {
          if let authorText = item.authorText {
            HStack(spacing: 10) {
              if let avatar = creator?.avatarURL {
                AsyncImage(url: avatar) { image in image.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                  .frame(width: 30, height: 30).clipShape(Circle())
              }
              if let id = item.creatorSteamID {
                Button { explorer.open(.author(id: id, name: authorText)) } label: {
                  HStack {
                    Text(authorText).lineLimit(2)
                    Image(systemName: "chevron.forward").font(.caption)
                  }
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                  .help("explore.authorWorks")
              } else { Text(authorText) }
              Spacer()
              if let id = item.creatorSteamID {
                Button {
                  favoriteLibrary.toggleAuthor(id: id, name: authorText, creator: creator)
                } label: {
                  Image(systemName: favoriteLibrary.containsAuthor(id) ? "star.fill" : "star")
                    .foregroundStyle(favoriteLibrary.containsAuthor(id) ? .yellow : .primary)
                }
                .buttonStyle(.borderless)
                .help(favoriteLibrary.containsAuthor(id) ? "favorites.removeAuthor" : "favorites.addAuthor")
                .accessibilityLabel(favoriteLibrary.containsAuthor(id) ? "favorites.removeAuthor" : "favorites.addAuthor")
              }
              if let url = creator?.profileURL {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                  .help("home.openInWorkshop")
              }
            }
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
          if let date = details?.createdAt {
            DetailRow(label: "explore.created", value: date.formatted(date: .abbreviated, time: .omitted))
          }
          if let date = details?.updatedAt {
            DetailRow(label: "explore.updated", value: date.formatted(date: .abbreviated, time: .omitted))
          }
          if let views = details?.views {
            DetailRow(label: "explore.views", value: formatCount(views))
          }
          if let favorites = details?.favorites {
            DetailRow(label: "explore.favorites", value: formatCount(favorites))
          }
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
              Button { explorer.open(.tag(tag)) } label: {
                Text(tag)
                  .font(.caption)
                  .lineLimit(1)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(.quaternary, in: Capsule())
              }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
          }
        }
      }
    }
  }

  private var quickStats: some View {
    HStack(spacing: 16) {
      if let ratingText = item.ratingText {
        Label(ratingText, systemImage: "star.fill")
          .foregroundStyle(.yellow)
      }
      if item.subscriptions > 0 {
        Label(formatCount(item.subscriptions), systemImage: "person.2")
      }
      if item.fileSize > 0 {
        Label(
          ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
          systemImage: "internaldrive"
        )
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
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
          ForEach(commentsViewModel.comments) { comment in
            WorkshopCommentRow(comment: comment)
            if comment.id != commentsViewModel.comments.last?.id {
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
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
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
      .frame(maxWidth: .infinity)
    case .completed:
      Button {
        if let url = record?.localURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Label("common.showInFinder", systemImage: "folder")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    case .failed, .cancelled:
      Button(action: download) {
        Label("download.retry", systemImage: "arrow.clockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    case .none:
      if steamCMD.hasDownloaded(item.id) {
        Button(action: download) {
          Label("download.again", systemImage: "checkmark.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      } else {
        Button(action: download) {
          Label("download.video", systemImage: "arrow.down")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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

      WorkshopPreviewImage(url: url, allowsAnimation: true)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 760, maxHeight: 760)
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
          .workshopCopyable(comment.text)
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
        .workshopCopyable(value)
      Spacer()
    }
  }
}
