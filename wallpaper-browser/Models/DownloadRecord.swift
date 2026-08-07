import Foundation

enum DownloadPhase: String, Codable, Sendable {
  case queued
  case downloading
  case extracting
  case completed
  case failed
  case cancelled

  var title: String {
    switch self {
    case .queued: "等待下载"
    case .downloading: "正在下载"
    case .extracting: "正在提取视频"
    case .completed: "下载完成"
    case .failed: "下载失败"
    case .cancelled: "已取消"
    }
  }
}

struct DownloadRecord: Identifiable, Codable, Hashable, Sendable {
  let id: String
  var item: WorkshopItem
  var phase: DownloadPhase
  var detail: String
  var localPath: String?
  var createdAt: Date
  var completedAt: Date?

  var localURL: URL? {
    localPath.map { URL(fileURLWithPath: $0) }
  }
}
