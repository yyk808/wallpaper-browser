import AVFoundation
import Foundation

@main
struct VideoPlaybackCompatibilityChecks {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw CheckError.usage
    }

    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let playback = await VideoPlaybackCompatibility.shared.prepare(sourceURL) else {
      throw CheckError.preparationFailed
    }
    do {
      let asset = AVURLAsset(url: playback.url)
      guard (try? await asset.load(.isPlayable)) == true else {
        throw CheckError.notPlayable
      }

      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      _ = try await generator.image(at: CMTime(seconds: 5, preferredTimescale: 600))
      print("PASS: prepared video is playable and decodes a video frame")
    } catch {
      await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: playback)
      throw error
    }
    await VideoPlaybackCompatibility.shared.removeTemporaryFiles(for: playback)
  }

  private enum CheckError: Error {
    case usage
    case preparationFailed
    case notPlayable
  }
}
