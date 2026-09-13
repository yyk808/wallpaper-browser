import AVFoundation
import Darwin
import Foundation

struct PreparedVideoPlayback: Sendable {
  let url: URL
  let temporaryDirectory: URL?
  let repairedSource: Bool
}

actor VideoPlaybackCompatibility {
  static let shared = VideoPlaybackCompatibility()

  func prepare(_ sourceURL: URL) async -> PreparedVideoPlayback? {
    let sourceAsset = AVURLAsset(url: sourceURL)
    if (try? await sourceAsset.load(.isPlayable)) == true {
      return PreparedVideoPlayback(
        url: sourceURL,
        temporaryDirectory: nil,
        repairedSource: false
      )
    }

    guard ["mp4", "m4v", "mov"].contains(sourceURL.pathExtension.lowercased()) else {
      return nil
    }

    if await repairSourceInPlace(sourceURL) {
      return PreparedVideoPlayback(
        url: sourceURL,
        temporaryDirectory: nil,
        repairedSource: true
      )
    }

    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appending(path: "Wallpaper Browser/Video Compatibility/\(UUID().uuidString)")
    let compatibleURL = temporaryDirectory.appending(path: sourceURL.lastPathComponent)

    do {
      try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
      try cloneOrCopy(sourceURL, to: compatibleURL)
      guard try replaceHEV1SampleEntries(in: compatibleURL) > 0 else {
        try? fileManager.removeItem(at: temporaryDirectory)
        return nil
      }

      let compatibleAsset = AVURLAsset(url: compatibleURL)
      guard (try? await compatibleAsset.load(.isPlayable)) == true else {
        try? fileManager.removeItem(at: temporaryDirectory)
        return nil
      }
      return PreparedVideoPlayback(
        url: compatibleURL,
        temporaryDirectory: temporaryDirectory,
        repairedSource: false
      )
    } catch {
      try? fileManager.removeItem(at: temporaryDirectory)
      return nil
    }
  }

  func removeTemporaryFiles(for playback: PreparedVideoPlayback?) {
    guard let directory = playback?.temporaryDirectory else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  private func cloneOrCopy(_ sourceURL: URL, to destinationURL: URL) throws {
    if clonefile(sourceURL.path, destinationURL.path, 0) == 0 {
      return
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  }

  private func repairSourceInPlace(_ url: URL) async -> Bool {
    do {
      let offsets = try sampleEntryOffsets(in: url, matching: "hev1")
      guard !offsets.isEmpty else { return false }
      try writeSampleEntryType("hvc1", at: offsets, in: url)

      let repairedAsset = AVURLAsset(url: url)
      if (try? await repairedAsset.load(.isPlayable)) == true {
        return true
      }
      try? writeSampleEntryType("hev1", at: offsets, in: url)
    } catch {
      return false
    }
    return false
  }

  private func replaceHEV1SampleEntries(in url: URL) throws -> Int {
    try replaceSampleEntries(in: url, from: "hev1", to: "hvc1")
  }

  private func replaceSampleEntries(
    in url: URL,
    from sourceType: String,
    to destinationType: String
  ) throws -> Int {
    guard sourceType.utf8.count == 4, destinationType.utf8.count == 4 else {
      throw VideoCompatibilityError.invalidBox
    }
    let offsets = try sampleEntryOffsets(in: url, matching: sourceType)
    try writeSampleEntryType(destinationType, at: offsets, in: url)
    return offsets.count
  }

  private func sampleEntryOffsets(in url: URL, matching type: String) throws -> [UInt64] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let fileSize = try handle.seekToEnd()
    return try hev1SampleEntryOffsets(
      in: handle,
      range: 0..<fileSize,
      containerType: nil,
      sampleEntryType: type
    )
  }

  private func writeSampleEntryType(
    _ type: String,
    at offsets: [UInt64],
    in url: URL
  ) throws {
    guard type.utf8.count == 4 else { throw VideoCompatibilityError.invalidBox }
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    for offset in offsets {
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: Data(type.utf8))
    }
    try handle.synchronize()
  }

  private func hev1SampleEntryOffsets(
    in handle: FileHandle,
    range: Range<UInt64>,
    containerType: String?,
    sampleEntryType: String
  ) throws -> [UInt64] {
    if containerType == "stsd" {
      return try sampleEntryOffsets(
        in: handle,
        range: range,
        sampleEntryType: sampleEntryType
      )
    }

    let nestedContainers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    var offsets: [UInt64] = []
    var cursor = range.lowerBound

    while cursor + 8 <= range.upperBound {
      let box = try readBox(in: handle, at: cursor, upperBound: range.upperBound)
      if nestedContainers.contains(box.type) || box.type == "stsd" {
        offsets += try hev1SampleEntryOffsets(
          in: handle,
          range: box.payloadStart..<box.end,
          containerType: box.type,
          sampleEntryType: sampleEntryType
        )
      }
      guard box.end > cursor else { break }
      cursor = box.end
    }
    return offsets
  }

  private func sampleEntryOffsets(
    in handle: FileHandle,
    range: Range<UInt64>,
    sampleEntryType: String
  ) throws -> [UInt64] {
    guard range.lowerBound + 8 <= range.upperBound else { return [] }
    let header = try readExactly(in: handle, at: range.lowerBound, count: 8)
    let entryCount = UInt64(readUInt32(header, at: 4))
    var offsets: [UInt64] = []
    var cursor = range.lowerBound + 8

    for _ in 0..<entryCount where cursor + 8 <= range.upperBound {
      let entry = try readBox(in: handle, at: cursor, upperBound: range.upperBound)
      if entry.type == sampleEntryType {
        offsets.append(cursor + 4)
      }
      guard entry.end > cursor else { break }
      cursor = entry.end
    }
    return offsets
  }

  private func readBox(
    in handle: FileHandle,
    at offset: UInt64,
    upperBound: UInt64
  ) throws -> ISOBox {
    let header = try readExactly(in: handle, at: offset, count: 8)
    let shortSize = UInt64(readUInt32(header, at: 0))
    guard let type = String(data: header.subdata(in: 4..<8), encoding: .ascii) else {
      throw VideoCompatibilityError.invalidBox
    }

    let headerSize: UInt64
    let size: UInt64
    if shortSize == 1 {
      let extendedSize = try readExactly(in: handle, at: offset + 8, count: 8)
      headerSize = 16
      size = readUInt64(extendedSize, at: 0)
    } else if shortSize == 0 {
      headerSize = 8
      size = upperBound - offset
    } else {
      headerSize = 8
      size = shortSize
    }

    guard size >= headerSize, offset <= upperBound, size <= upperBound - offset else {
      throw VideoCompatibilityError.invalidBox
    }
    return ISOBox(
      type: type,
      payloadStart: offset + headerSize,
      end: offset + size
    )
  }

  private func readExactly(
    in handle: FileHandle,
    at offset: UInt64,
    count: Int
  ) throws -> Data {
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
      throw VideoCompatibilityError.invalidBox
    }
    return data
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
  }

  private struct ISOBox {
    let type: String
    let payloadStart: UInt64
    let end: UInt64
  }

  private enum VideoCompatibilityError: Error {
    case invalidBox
  }
}
