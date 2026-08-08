import Foundation

enum DownloadPhase: String, Codable, Sendable {
  case queued
  case downloading
  case extracting
  case completed
  case failed
  case cancelled

  var localizationKey: String {
    switch self {
    case .queued: "download.phase.queued"
    case .downloading: "download.phase.downloading"
    case .extracting: "download.phase.extracting"
    case .completed: "download.phase.completed"
    case .failed: "download.phase.failed"
    case .cancelled: "download.phase.cancelled"
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
  var progress: Double? = nil
  var bytesPerSecond: Double? = nil

  var localURL: URL? {
    localPath.map { URL(fileURLWithPath: $0) }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case item
    case phase
    case detail
    case localPath
    case createdAt
    case completedAt
    case progress
    case bytesPerSecond
  }

  init(
    id: String,
    item: WorkshopItem,
    phase: DownloadPhase,
    detail: String,
    localPath: String?,
    createdAt: Date,
    completedAt: Date?,
    progress: Double? = nil,
    bytesPerSecond: Double? = nil
  ) {
    self.id = id
    self.item = item
    self.phase = phase
    self.detail = detail
    self.localPath = localPath
    self.createdAt = createdAt
    self.completedAt = completedAt
    self.progress = progress
    self.bytesPerSecond = bytesPerSecond
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    item = try container.decode(WorkshopItem.self, forKey: .item)
    phase = try container.decode(DownloadPhase.self, forKey: .phase)
    detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    bytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .bytesPerSecond)
  }
}
