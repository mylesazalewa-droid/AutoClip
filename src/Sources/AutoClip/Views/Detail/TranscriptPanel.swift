import SwiftUI

enum TranscriptSubTab: String, CaseIterable {
    case paragraph = "Paragraph"
    case list = "List"
    case fillers = "Fillers"
}

struct TranscriptPanel: View {
    let clip: Clip
    var seekAction: ((Double) -> Void)?
    @State private var subTab: TranscriptSubTab = .paragraph

    var fillerWords: Set<String> {
        Set(["um", "uh", "like", "you know", "sort of", "kind of", "basically", "literally", "actually"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sub-tab picker
            HStack(spacing: 4) {
                ForEach(TranscriptSubTab.allCases, id: \.self) { tab in
                    Button(action: { subTab = tab }) {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: subTab == tab ? .semibold : .regular))
                            .foregroundColor(subTab == tab ? .white : Color.white.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(subTab == tab ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 14)

            // Content
            Group {
                switch subTab {
                case .paragraph:
                    paragraphView
                case .list:
                    listView
                case .fillers:
                    fillersView
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
    }

    var paragraphView: some View {
        let text = cleanText(clip.transcriptText)
        return Text(text.isEmpty ? "No transcript available." : text)
            .font(.system(size: 13, design: .default))
            .foregroundColor(Color.white.opacity(0.8))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var listView: some View {
        let sentences = splitIntoSentences(clip.transcriptText)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                if !sentence.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.75, blue: 0.0))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(sentence.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var fillersView: some View {
        let detected = detectFillers()
        return VStack(alignment: .leading, spacing: 12) {
            if detected.isEmpty {
                Text("No filler words detected.")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.4))
            } else {
                Text("Filler words found: \(detected.count)")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))

                transcriptWithFillers
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var transcriptWithFillers: some View {
        let words = clip.words.filter { !$0.word.hasPrefix("<|") }
        return FlowLayout(spacing: 4) {
            ForEach(words) { word in
                let clean = word.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                let isFiller = fillerWords.contains(clean)
                Button(action: {
                    seekAction?(word.startTime - clip.startTime)
                }) {
                    Text(word.word)
                        .font(.system(size: 13))
                        .foregroundColor(isFiller ? Color(red: 1, green: 0.5, blue: 0.1) : Color.white.opacity(0.8))
                        .background(isFiller ? Color(red: 1, green: 0.5, blue: 0.1).opacity(0.15) : Color.clear)
                        .cornerRadius(2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "<|startoftranscript|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func splitIntoSentences(_ text: String) -> [String] {
        let clean = cleanText(text)
        return clean.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func detectFillers() -> [String] {
        clip.words.compactMap { word -> String? in
            let clean = word.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return fillerWords.contains(clean) ? word.word : nil
        }
    }
}

// Simple flow layout for transcript words
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var height: CGFloat = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                height += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
