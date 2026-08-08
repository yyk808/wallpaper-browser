import SwiftUI

struct FilterPopover: View {
  @EnvironmentObject private var appSettings: AppSettings
  let filters: WorkshopFilters
  let onCancel: () -> Void
  let onApply: (WorkshopFilters) -> Void

  @State private var draft: WorkshopFilters
  @State private var genreSearch = ""
  @State private var genreMode: GenreFilterMode

  init(
    filters: WorkshopFilters,
    onCancel: @escaping () -> Void,
    onApply: @escaping (WorkshopFilters) -> Void
  ) {
    self.filters = filters
    self.onCancel = onCancel
    self.onApply = onApply
    _draft = State(initialValue: filters)
    _genreMode = State(
      initialValue: filters.genres.isEmpty && !filters.excludedGenres.isEmpty ? .exclude : .include
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("common.filter")
          .font(.headline)
        Spacer()
        Button("common.reset") {
          draft = WorkshopFilters()
          genreSearch = ""
          genreMode = .include
        }
        .buttonStyle(.link)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          filterSection("filter.contentRating") {
            HStack(spacing: 16) {
              ForEach(WorkshopFilters.contentRatings, id: \.self) { rating in
                Toggle(ratingTitle(rating), isOn: setBinding(for: rating))
                  .toggleStyle(.checkbox)
              }
            }
          }

          filterSection("filter.resolution") {
            Picker("filter.resolution", selection: $draft.resolution) {
              Text("common.all").tag(String?.none)
              ForEach(WorkshopFilters.resolutions, id: \.self) { resolution in
                Text(resolutionTitle(resolution)).tag(Optional(resolution))
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          filterSection("filter.genre") {
            Picker("filter.genreMode", selection: $genreMode) {
              ForEach(GenreFilterMode.allCases) { mode in
                Label(appSettings.localized(mode.localizationKey), systemImage: mode.systemImage)
                  .tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("filter.searchGenre", text: $genreSearch)
              .textFieldStyle(.roundedBorder)

            LazyVGrid(
              columns: [GridItem(.flexible()), GridItem(.flexible())],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(filteredGenres, id: \.self) { genre in
                Toggle(isOn: genreBinding(for: genre)) {
                  HStack(spacing: 4) {
                    Text(genre)
                      .lineLimit(1)
                    if let oppositeMode = oppositeMode(for: genre) {
                      Image(systemName: oppositeMode.systemImage)
                        .font(.caption2)
                        .foregroundStyle(oppositeMode == .exclude ? Color.red : Color.secondary)
                    }
                  }
                }
                .toggleStyle(.checkbox)
              }
            }
          }
        }
        .padding(16)
      }

      Divider()

      HStack {
        Text("filter.videoOnly")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("common.cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("common.apply") { onApply(draft) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(width: 370, height: 470)
  }

  private var filteredGenres: [String] {
    guard !genreSearch.isEmpty else { return WorkshopFilters.genres }
    return WorkshopFilters.genres.filter {
      $0.localizedCaseInsensitiveContains(genreSearch)
    }
  }

  private func filterSection<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func setBinding(for rating: String) -> Binding<Bool> {
    Binding(
      get: { draft.ratings.contains(rating) },
      set: { enabled in
        if enabled {
          draft.ratings.insert(rating)
        } else if draft.ratings.count > 1 {
          draft.ratings.remove(rating)
        }
      }
    )
  }

  private func genreBinding(for genre: String) -> Binding<Bool> {
    Binding(
      get: {
        switch genreMode {
        case .include: draft.genres.contains(genre)
        case .exclude: draft.excludedGenres.contains(genre)
        }
      },
      set: { enabled in
        switch genreMode {
        case .include:
          if enabled {
            draft.genres.insert(genre)
            draft.excludedGenres.remove(genre)
          } else {
            draft.genres.remove(genre)
          }
        case .exclude:
          if enabled {
            draft.excludedGenres.insert(genre)
            draft.genres.remove(genre)
          } else {
            draft.excludedGenres.remove(genre)
          }
        }
      }
    )
  }

  private func oppositeMode(for genre: String) -> GenreFilterMode? {
    switch genreMode {
    case .include:
      draft.excludedGenres.contains(genre) ? .exclude : nil
    case .exclude:
      draft.genres.contains(genre) ? .include : nil
    }
  }

  private func ratingTitle(_ rating: String) -> String {
    switch rating {
    case "Everyone": appSettings.localized("rating.everyone")
    case "Questionable": appSettings.localized("rating.questionable")
    case "Mature": appSettings.localized("rating.mature")
    default: rating
    }
  }

  private func resolutionTitle(_ resolution: String) -> String {
    switch resolution {
    case "1920 x 1080": appSettings.localized("resolution.1080p")
    case "2560 x 1440": appSettings.localized("resolution.1440p")
    case "3840 x 2160": appSettings.localized("resolution.4k")
    case "3440 x 1440": appSettings.localized("resolution.ultrawide")
    case "1440 x 2560": appSettings.localized("resolution.vertical")
    default: resolution
    }
  }
}

private enum GenreFilterMode: String, CaseIterable, Identifiable {
  case include
  case exclude

  var id: String { rawValue }

  var localizationKey: String {
    switch self {
    case .include: "filter.include"
    case .exclude: "filter.exclude"
    }
  }

  var systemImage: String {
    switch self {
    case .include: "plus.circle"
    case .exclude: "minus.circle"
    }
  }
}
