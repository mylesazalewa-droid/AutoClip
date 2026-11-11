import Foundation
import SwiftUI

// MARK: - Project

struct Project: Identifiable, Codable {
    var id: UUID
    var title: String
    var videoPath: String
    var duration: TimeInterval
    var dateCreated: TimeInterval
    var clipCount: Int
    var thumbnailData: String?
    var clips: [Clip]

    var thumbnail: NSImage? {
        guard let b64 = thumbnailData,
              let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    var formattedDuration: String {
        let s = Int(duration)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    var relativeDate: String {
        let date = Date(timeIntervalSinceReferenceDate: dateCreated)
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Clip

struct Clip: Identifiable, Codable {
    var id: UUID
    var title: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var score: Double
    var scoreReason: String
    var words: [Word]
    var isLiked: Bool
    var starRating: Int
    var captionStyleName: String
    var aspectRatio: String
    var notes: String
    var thumbnailData: String?
    var sourceVideoPath: String = ""  // empty = use the reel's primary source video
    /// Framing chosen in the reel editor: hold the crop still at this horizontal centre (0…1)
    /// Keep the crop on the person who starts here (0…1), following them as they move
    var trackX: Double?
    /// When they were at `trackX` (source seconds)
    var trackT: Double?
    var frameX: Double?
    /// Re-check the face tracking more closely for this clip
    var carefulFraming: Bool?
    /// Split screen (vertical reels): two people stacked, top and bottom, each centred at these
    /// horizontal positions (0…1)
    var splitX: [Double]?
    /// Stretches (source seconds, [start, end]) shown as the whole wide picture instead of the
    /// close crop, for when the speaker points to the stage screen
    var wide: [[Double]]?
    /// How far the wide shot zooms in (1 = the whole picture). nil = fit the speaker and screen
    var wideZoom: Double?
    /// Where the zoomed wide shot is centred across the picture (0…1). nil = automatic
    var wideX: Double?
    /// Wide moments as a split: the speaker on top, the stage screen below
    var wideSplit: Bool?
    /// Where the stage screen is in the picture: x, y, width, height (0…1, from the top left)
    var screenRect: [Double]?

    var duration: TimeInterval { endTime - startTime }

    var thumbnail: NSImage? {
        guard let b64 = thumbnailData,
              let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    var tags: [String] {
        scoreReason.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var isTrending: Bool {
        tags.contains(where: { $0.lowercased().contains("trending") || $0.lowercased().contains("viral") || $0.lowercased().contains("opener") })
    }

    var formattedStartTime: String {
        let s = Int(startTime)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    var formattedDuration: String {
        let s = Int(duration)
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }

    var transcriptText: String {
        words.map(\.word)
            .joined(separator: " ")
            .replacingOccurrences(of: "<|startoftranscript|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var scoreColor: Color {
        switch score {
        case 90...100: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case 75..<90:  return Color(red: 0.6, green: 0.85, blue: 0.3)
        case 60..<75:  return Color(red: 1.0, green: 0.7, blue: 0.0)
        default:       return Color(red: 1.0, green: 0.4, blue: 0.2)
        }
    }
}

// MARK: - Word

struct Word: Identifiable, Codable, Equatable {
    var id: UUID
    var word: String
    var startTime: Double
    var endTime: Double
    var confidence: Double
}

// MARK: - Caption Style

struct CaptionStyle: Identifiable {
    var id: String { name }
    var name: String
    var fontName: String
    var fontSize: CGFloat
    var textColor: Color
    var strokeColor: Color
    var backgroundColor: Color?
    var isKaraoke: Bool

    static let all: [CaptionStyle] = [
        CaptionStyle(name: "Karaoke", fontName: "Impact", fontSize: 36, textColor: .white, strokeColor: .black, backgroundColor: nil, isKaraoke: true),
        CaptionStyle(name: "Dark", fontName: "Arial-BoldMT", fontSize: 34, textColor: .white, strokeColor: .black, backgroundColor: Color.black.opacity(0.75), isKaraoke: false),
        CaptionStyle(name: "Clean", fontName: "Helvetica-Bold", fontSize: 34, textColor: .white, strokeColor: .clear, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Neon", fontName: "Impact", fontSize: 36, textColor: Color(red: 0, green: 1, blue: 0.8), strokeColor: Color(red: 0, green: 0.5, blue: 0.4), backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Pop", fontName: "Arial-BoldMT", fontSize: 38, textColor: .yellow, strokeColor: .black, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Minimal", fontName: "Helvetica", fontSize: 28, textColor: .white, strokeColor: .clear, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Fire", fontName: "Impact", fontSize: 38, textColor: Color(red: 1, green: 0.4, blue: 0), strokeColor: .black, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Beasty", fontName: "Impact", fontSize: 40, textColor: .white, strokeColor: Color(red: 0.5, green: 0, blue: 0.5), backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Matrix", fontName: "Courier-Bold", fontSize: 32, textColor: Color(red: 0, green: 1, blue: 0), strokeColor: .black, backgroundColor: Color.black.opacity(0.8), isKaraoke: false),
        CaptionStyle(name: "Bubblegum", fontName: "Arial-BoldMT", fontSize: 36, textColor: Color(red: 1, green: 0.4, blue: 0.7), strokeColor: .white, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Shadow", fontName: "Helvetica-Bold", fontSize: 34, textColor: .white, strokeColor: .clear, backgroundColor: nil, isKaraoke: false),
        CaptionStyle(name: "Chalk", fontName: "Chalkboard SE", fontSize: 32, textColor: .white, strokeColor: .clear, backgroundColor: nil, isKaraoke: false),
    ]

    static func named(_ name: String) -> CaptionStyle {
        all.first { $0.name == name } ?? all[0]
    }
}

// MARK: - Export Record

struct ExportRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var clipId: UUID
    var projectId: UUID
    var clipTitle: String
    var exportDate: Date
    var format: String
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable {
    case topScore = "Top Score"
    case newest = "Newest"
    case oldest = "Oldest"
    case duration = "Duration"
    case trending = "Trending"
}
