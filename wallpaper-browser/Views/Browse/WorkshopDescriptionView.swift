import AppKit
import SwiftUI

struct WorkshopDescriptionView: View {
  let text: String
  @State private var expanded = false

  private var canCollapse: Bool { text.count > 160 || text.components(separatedBy: .newlines).count > 5 }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(WorkshopDescriptionFormatter.attributed(text))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(expanded || !canCollapse ? nil : 5)
        .workshopCopyable(text)
      if canCollapse {
        Button(expanded ? "explore.collapse" : "explore.readMore") { expanded.toggle() }
          .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
      }
    }
  }
}

// Steam descriptions use BBCode. Keep text and basic formatting without embedding remote HTML.
enum WorkshopDescriptionFormatter {
  static func attributed(_ source: String) -> AttributedString {
    var text = source
    let rules: [(String, String)] = [
      (#"(?is)\[b\](.*?)\[/b\]"#, "**$1**"),
      (#"(?is)\[i\](.*?)\[/i\]"#, "*$1*"),
      (#"(?is)\[strike\](.*?)\[/strike\]"#, "~~$1~~"),
      (#"(?is)\[url=(https?://[^\]\s]+)\](.*?)\[/url\]"#, "[$2]($1)"),
      (#"(?is)\[url\](https?://[^\]\s]+)\[/url\]"#, "[$1]($1)"),
      (#"(?is)\[img\](https?://[^\]\s]+)\[/img\]"#, "[$1]($1)"),
      (#"(?i)\[\*\]"#, "\n• "),
      (#"(?i)\[/?(?:h[1-6]|list|olist|quote|code|table|tr)(?:=[^\]]*)?\]"#, "\n"),
      (#"(?i)\[/?(?:b|i|u|strike|spoiler|url|img|td|th)(?:=[^\]]*)?\]"#, ""),
    ]
    for (pattern, replacement) in rules {
      text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    for run in result.runs {
      if let link = run.link, !link.isWorkshopWebURL { result[run.range].link = nil }
    }
    return result
  }
}

extension View {
  func workshopCopyable(_ text: String) -> some View {
    contextMenu {
      Button("common.copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
    }
  }
}
