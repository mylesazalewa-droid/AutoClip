import SwiftUI
import AppKit

struct CaptionsPanel: View {
    @Binding var clip: Clip
    @Binding var bgEnabled: Bool
    @Binding var bgOpacity: Double
    @Binding var bgColor: NSColor

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Caption style grid
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(CaptionStyle.all) { style in
                    CaptionStyleCard(
                        style: style,
                        isSelected: clip.captionStyleName == style.name
                    )
                    .onTapGesture {
                        var updated = clip
                        updated.captionStyleName = style.name
                        clip = updated
                        LibraryService.shared.updateClip(updated, in: LibraryService.shared.projects.first(where: { $0.clips.contains { $0.id == clip.id } }) ?? Project(id: UUID(), title: "", videoPath: "", duration: 0, dateCreated: 0, clipCount: 0, thumbnailData: nil, clips: []))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 14)

            // Caption Background
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $bgEnabled) {
                    Text("Caption Background")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                }
                .toggleStyle(CheckboxToggleStyle())
                .padding(.horizontal, 14)

                if bgEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Opacity")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.5))
                            Slider(value: $bgOpacity, in: 0...1)
                                .accentColor(Color(red: 1.0, green: 0.75, blue: 0.0))
                            Text("\(Int(bgOpacity * 100))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.6))
                                .frame(width: 36)
                        }
                        .padding(.horizontal, 14)

                        HStack {
                            Text("Bg Color")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.5))
                            Spacer()
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: bgColor) },
                                set: { bgColor = NSColor($0) }
                            ))
                            .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

struct CaptionStyleCard: View {
    let style: CaptionStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0) : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )

                // Caption preview
                VStack(spacing: 2) {
                    if style.isKaraoke {
                        HStack(spacing: 0) {
                            Text("LIFE")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundColor(Color(red: 1.0, green: 0.9, blue: 0.0))
                            Text(" IS")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundColor(.white)
                        }
                    } else {
                        Text("LIFE IS")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(style.textColor)
                    }
                    Text("GOOD")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(style.textColor.opacity(0.8))
                }
            }
            .frame(height: 60)

            Text(style.name)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0) : Color.white.opacity(0.6))
        }
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? Color(red: 1.0, green: 0.75, blue: 0.0) : Color.white.opacity(0.1))
                    .frame(width: 16, height: 16)
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                }
            }
            .onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}
