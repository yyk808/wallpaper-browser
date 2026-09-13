import SwiftUI

struct FavoritesView: View {
  @EnvironmentObject private var favoriteLibrary: FavoriteLibrary
  @EnvironmentObject private var explorer: WorkshopExplorer
  @EnvironmentObject private var settings: AppSettings
  @State private var selection: FavoriteKind = .collections
  let showWorkshop: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .navigationTitle("nav.favorites")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        Text("nav.favorites")
          .font(.title2.bold())
        Text(settings.localized("favorites.summary|\(favoriteLibrary.collections.count)|\(favoriteLibrary.authors.count)"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("favorites.kind", selection: $selection) {
        ForEach(FavoriteKind.allCases) { kind in
          Text(settings.localized(kind.localizationKey)).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 260)
    }
    .padding(.horizontal, 24)
    .frame(height: 72)
  }

  @ViewBuilder
  private var content: some View {
    switch selection {
    case .collections:
      if favoriteLibrary.collections.isEmpty {
        emptyState(
          title: "favorites.emptyCollections",
          description: "favorites.emptyCollectionsDescription",
          actionTitle: "favorites.discoverCollections",
          systemImage: "square.stack"
        ) {
          explorer.open(.collections(containing: nil))
        }
      } else {
        collectionGrid
      }
    case .authors:
      if favoriteLibrary.authors.isEmpty {
        emptyState(
          title: "favorites.emptyAuthors",
          description: "favorites.emptyAuthorsDescription",
          actionTitle: "favorites.discoverAuthors",
          systemImage: "person.crop.circle"
        ) {
          showWorkshop()
        }
      } else {
        authorGrid
      }
    }
  }

  private var collectionGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 18)],
        alignment: .leading,
        spacing: 22
      ) {
        ForEach(favoriteLibrary.collections) { collection in
          FavoriteCollectionCard(collection: collection) {
            explorer.open(.collection(id: collection.id, title: collection.title))
          } remove: {
            favoriteLibrary.removeCollection(collection.id)
          }
        }
      }
      .padding(24)
    }
  }

  private var authorGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16)],
        alignment: .leading,
        spacing: 16
      ) {
        ForEach(favoriteLibrary.authors) { author in
          FavoriteAuthorCard(author: author) {
            explorer.open(.author(id: author.id, name: author.name))
          } remove: {
            favoriteLibrary.removeAuthor(author.id)
          }
        }
      }
      .padding(24)
    }
  }

  private func emptyState(
    title: LocalizedStringKey,
    description: LocalizedStringKey,
    actionTitle: LocalizedStringKey,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    } actions: {
      Button(actionTitle, action: action)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private enum FavoriteKind: String, CaseIterable, Identifiable {
  case collections
  case authors

  var id: String { rawValue }
  var localizationKey: String {
    switch self {
    case .collections: "favorites.collections"
    case .authors: "favorites.authors"
    }
  }
}

private struct FavoriteCollectionCard: View {
  let collection: FavoriteWorkshopCollection
  let open: () -> Void
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .topTrailing) {
        Button(action: open) {
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { WorkshopPreviewImage(url: collection.previewURL) }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)

        Button(action: remove) {
          Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(9)
        .help("favorites.removeCollection")
        .accessibilityLabel("favorites.removeCollection")
      }

      Button(action: open) {
        VStack(alignment: .leading, spacing: 4) {
          Text(collection.title)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
          HStack(spacing: 10) {
            if let creatorName = collection.creatorName {
              Label(creatorName, systemImage: "person")
            }
            if let memberCount = collection.memberCount {
              Label("\(memberCount)", systemImage: "photo.on.rectangle.angled")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .contextMenu {
      Button("favorites.open", action: open)
      Divider()
      Button("favorites.removeCollection", role: .destructive, action: remove)
    }
  }
}

private struct FavoriteAuthorCard: View {
  let author: FavoriteWorkshopAuthor
  let open: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button(action: open) {
        AsyncImage(url: author.avatarURL) { image in
          image.resizable()
        } placeholder: {
          Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.tertiary)
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
      }
      .buttonStyle(.plain)

      Button(action: open) {
        VStack(alignment: .leading, spacing: 4) {
          Text(author.name)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text("favorites.viewAuthorWorks")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: remove) {
        Image(systemName: "star.fill")
          .foregroundStyle(.yellow)
      }
      .buttonStyle(.borderless)
      .help("favorites.removeAuthor")
      .accessibilityLabel("favorites.removeAuthor")
    }
    .padding(16)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.07))
    }
    .contextMenu {
      Button("favorites.open", action: open)
      Divider()
      Button("favorites.removeAuthor", role: .destructive, action: remove)
    }
  }
}
