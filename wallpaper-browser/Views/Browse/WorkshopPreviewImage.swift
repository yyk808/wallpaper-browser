import AppKit
import Combine
import SwiftUI

struct WorkshopPreviewImage: View {
  let url: URL?
  let refreshToken: Int

  @StateObject private var loader = WorkshopImageLoader()
  @State private var isVisible = false

  init(url: URL?, refreshToken: Int = 0) {
    self.url = url
    self.refreshToken = refreshToken
  }

  var body: some View {
    ZStack {
      placeholder
        .opacity(loader.image == nil ? 1 : 0)

      if let image = loader.image {
        WorkshopNSImageView(image: image, allowsAnimation: isVisible)
      }

      if loader.isLoading && loader.image == nil {
        ProgressView()
          .controlSize(.small)
      }
    }
    .task(id: PreviewLoadID(url: url, refreshToken: refreshToken)) {
      await loader.load(url: url, refreshToken: refreshToken)
    }
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
  }

  private var placeholder: some View {
    Rectangle()
      .fill(Color(nsColor: .quaternaryLabelColor))
      .overlay {
        Image(systemName: "photo")
          .font(.largeTitle)
          .foregroundStyle(.tertiary)
      }
  }
}

@MainActor
private final class WorkshopImageLoader: ObservableObject {
  @Published private(set) var image: NSImage?
  @Published private(set) var isLoading = false
  private var loadedURL: URL?
  private var loadedRefreshToken = 0

  func load(url: URL?, refreshToken: Int) async {
    guard let url else {
      image = nil
      loadedURL = nil
      loadedRefreshToken = refreshToken
      return
    }

    let shouldRefresh = loadedURL == url && loadedRefreshToken != refreshToken
    loadedURL = url
    loadedRefreshToken = refreshToken

    if !shouldRefresh, let cachedImage = await WorkshopImageCache.shared.image(for: url) {
      image = cachedImage
      return
    }

    if !shouldRefresh {
      image = nil
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard
        let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        let image = await WorkshopImageCache.shared.image(from: data, for: url)
      else { return }
      self.image = image
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }
}

private struct PreviewLoadID: Equatable {
  let url: URL?
  let refreshToken: Int
}

private struct WorkshopNSImageView: NSViewRepresentable {
  let image: NSImage
  let allowsAnimation: Bool

  func makeNSView(context: Context) -> WorkshopImageView {
    let imageView = WorkshopImageView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.allowsAnimation = allowsAnimation
    imageView.imageFrameStyle = .none
    imageView.isEditable = false
    imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    imageView.image = image
    return imageView
  }

  func updateNSView(_ imageView: WorkshopImageView, context: Context) {
    if imageView.image !== image {
      imageView.image = image
    }
    imageView.allowsAnimation = allowsAnimation
  }
}

private final class WorkshopImageView: NSImageView {
  var allowsAnimation = false {
    didSet { updatePlaybackState() }
  }

  private var notificationObservers: [NSObjectProtocol] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    observePlaybackConditions()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    observePlaybackConditions()
  }

  deinit {
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updatePlaybackState()
  }

  private func observePlaybackConditions() {
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
      NSApplication.didHideNotification,
      NSApplication.didUnhideNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    notificationObservers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.updatePlaybackState()
      }
    }
  }

  private func updatePlaybackState() {
    let isWindowVisible = window.map {
      !$0.isMiniaturized && $0.occlusionState.contains(.visible)
    } ?? false
    animates = allowsAnimation && NSApp.isActive && isWindowVisible
  }
}
