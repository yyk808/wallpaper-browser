import SwiftUI

struct FilterPopover: View {
  let filters: WorkshopFilters
  let onCancel: () -> Void
  let onApply: (WorkshopFilters) -> Void

  @State private var draft: WorkshopFilters
  @State private var genreSearch = ""

  init(
    filters: WorkshopFilters,
    onCancel: @escaping () -> Void,
    onApply: @escaping (WorkshopFilters) -> Void
  ) {
    self.filters = filters
    self.onCancel = onCancel
    self.onApply = onApply
    _draft = State(initialValue: filters)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("筛选")
          .font(.headline)
        Spacer()
        Button("重置") {
          draft = WorkshopFilters()
          genreSearch = ""
        }
        .buttonStyle(.link)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          filterSection("内容分级") {
            HStack(spacing: 16) {
              ForEach(WorkshopFilters.contentRatings, id: \.self) { rating in
                Toggle(ratingTitle(rating), isOn: setBinding(for: rating))
                  .toggleStyle(.checkbox)
              }
            }
          }

          filterSection("分辨率") {
            Picker("分辨率", selection: $draft.resolution) {
              Text("全部").tag(String?.none)
              ForEach(WorkshopFilters.resolutions, id: \.self) { resolution in
                Text(resolutionTitle(resolution)).tag(Optional(resolution))
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          filterSection("题材") {
            TextField("搜索题材", text: $genreSearch)
              .textFieldStyle(.roundedBorder)

            LazyVGrid(
              columns: [GridItem(.flexible()), GridItem(.flexible())],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(filteredGenres, id: \.self) { genre in
                Toggle(genre, isOn: genreBinding(for: genre))
                  .toggleStyle(.checkbox)
                  .lineLimit(1)
              }
            }
          }
        }
        .padding(16)
      }

      Divider()

      HStack {
        Text("仅显示 Video 类型")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("应用") { onApply(draft) }
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
    _ title: String,
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
      get: { draft.genres.contains(genre) },
      set: { enabled in
        if enabled { draft.genres.insert(genre) } else { draft.genres.remove(genre) }
      }
    )
  }

  private func ratingTitle(_ rating: String) -> String {
    switch rating {
    case "Everyone": "所有人"
    case "Questionable": "辅导级"
    case "Mature": "成人"
    default: rating
    }
  }

  private func resolutionTitle(_ resolution: String) -> String {
    switch resolution {
    case "1920 x 1080": "1080p"
    case "2560 x 1440": "1440p"
    case "3840 x 2160": "4K"
    case "3440 x 1440": "超宽屏"
    case "1440 x 2560": "竖屏"
    default: resolution
    }
  }
}
