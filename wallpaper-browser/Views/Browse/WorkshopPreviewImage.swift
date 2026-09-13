import AppKit
import Combine
import SwiftUI

struct WorkshopPreviewImage: View {
  let url: URL?
  let refreshToken: Int
  let allowsAnimation: Bool

  @StateObject private var loader = WorkshopImageLoader()
  @State private var isVisible = false

  init(url: URL?, refreshToken: Int = 0, allowsAnimation: Bool = true) {
    self.url = url
    self.refreshToken = refreshToken
    self.allowsAnimation = allowsAnimation
  }

  var body: some View {
    ZStack {
      placeholder
        .opacity(loader.image == nil ? 1 : 0)

      if let image = loader.image {
        WorkshopNSImageView(
          image: image,
          allowsAnimation: allowsAnimation && isVisible
        )
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

extension View {
  func workshopDetailTransitionSource(
    id: String,
    in namespace: Namespace.ID,
    isActive: Bool
  ) -> some View {
    modifier(
      WorkshopDetailMatchedGeometryModifier(
        id: id,
        namespace: namespace,
        isActive: isActive
      )
    )
  }

  func workshopDetailTransitionDestination(
    id: String,
    in namespace: Namespace.ID
  ) -> some View {
    modifier(
      WorkshopDetailMatchedGeometryModifier(
        id: id,
        namespace: namespace,
        isActive: true
      )
    )
  }
}

private struct WorkshopDetailMatchedGeometryModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let id: String
  let namespace: Namespace.ID
  let isActive: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceMotion || !isActive {
      content
    } else {
      content.matchedGeometryEffect(
        id: id,
        in: namespace,
        properties: .frame,
        anchor: .center
      )
    }
  }
}

@MainActor
private final class WorkshopImageLoader: ObservableObject {
  @Published private(set) var image: NSImage?
  @Published private(set) var isLoading = false
  private var loadedURL: URL?
  private var loadedRefreshToken = 0
  private var loadGeneration = 0

  func load(url: URL?, refreshToken: Int) async {
    loadGeneration &+= 1
    let generation = loadGeneration

    guard let url else {
      image = nil
      isLoading = false
      loadedURL = nil
      loadedRefreshToken = refreshToken
      return
    }

    let shouldRefresh = loadedURL == url && loadedRefreshToken != refreshToken
    loadedURL = url
    loadedRefreshToken = refreshToken

    if !shouldRefresh, let cachedImage = WorkshopImageCache.shared.memoryImage(for: url) {
      image = cachedImage
      isLoading = false
      return
    }

    if !shouldRefresh, image != nil {
      image = nil
    }

    isLoading = true
    defer {
      if loadGeneration == generation {
        isLoading = false
      }
    }

    if let image = await WorkshopImageCache.shared.loadImage(
      for: url,
      bypassCache: shouldRefresh
    ), !Task.isCancelled, loadGeneration == generation {
      self.image = image
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

@MainActor
private final class WorkshopImageView: NSImageView {
  var allowsAnimation = false {
    didSet { updatePlaybackState() }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    WorkshopPlaybackCoordinator.shared.register(self)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    WorkshopPlaybackCoordinator.shared.register(self)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updatePlaybackState()
  }

  fileprivate func updatePlaybackState() {
    let isWindowVisible = window.map {
      $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
    } ?? false
    let isApplicationVisible = NSApp.isActive && !NSApp.isHidden
    animates = allowsAnimation && isApplicationVisible && isWindowVisible
  }
}

@MainActor
private final class WorkshopPlaybackCoordinator {
  static let shared = WorkshopPlaybackCoordinator()

  private let imageViews = NSHashTable<WorkshopImageView>.weakObjects()
  private var notificationObservers: [NSObjectProtocol] = []

  private init() {
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
        // The main operation queue guarantees the callback runs on AppKit's main thread.
        // Enter the actor synchronously so every visibility event does not allocate a task.
        MainActor.assumeIsolated {
          self?.updatePlaybackStates()
        }
      }
    }
  }

  func register(_ imageView: WorkshopImageView) {
    imageViews.add(imageView)
  }

  private func updatePlaybackStates() {
    for imageView in imageViews.allObjects {
      imageView.updatePlaybackState()
    }
  }
}
