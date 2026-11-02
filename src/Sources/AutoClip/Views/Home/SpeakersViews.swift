import SwiftUI
import Charts

private let gold = Theme.sand

/// Add, rename and remove the people whose messages are assessed.
struct SpeakersSheet: View {
    let reports: [SpeakerReport]
    @ObservedObject private var profiles = SpeakerProfiles.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
            Text("Give each preacher their own progress charts. Right-click a video in the list to say whose message it is.")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(Array(profiles.speakers.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        Circle().fill(profiles.color(s)).frame(width: 10, height: 10)
                        TextField("Name", text: Binding(get: { s.name }, set: { profiles.rename(s.id, to: $0) }))
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                        let n = reports.filter { !$0.isPractice && profiles.speaker(for: $0.videoPath).id == s.id }.count
                        Text("\(n) message\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                        Spacer()
                        if i == 0 {
                            Text("Default").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                                .help("Videos you haven't assigned belong to this speaker")
                        } else {
                            Button { profiles.remove(s.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundColor(Color.white.opacity(0.6))
                                .help("Remove \(s.name). Their videos and reports stay and move to \(profiles.primary.name).")
                        }
                    }
                    .padding(8).background(Color.white.opacity(0.04)).cornerRadius(8)
                }
            }

            HStack(spacing: 8) {
                TextField("New speaker's name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit(add)
                Button("Add speaker", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.surface)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        profiles.add(name)
        newName = ""
    }
}

/// With "Everyone" picked: each speaker's averages side by side, plus filler words over time.
struct SpeakerCompareCard: View {
    let rows: [(speaker: SpeakerProfiles.Speaker, color: Color, reports: [SpeakerReport])]
    let pick: (SpeakerProfiles.Speaker) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Speakers side by side", subtitle: "Averages across each speaker's assessed messages. Click a speaker to see their trends.") {
                HStack {
                    Text("Speaker").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(["Messages", "Fillers / min", "Words / min", "Pitch variety", "Coach"], id: \.self) {
                        Text($0).frame(width: 84, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.4))
                ForEach(rows, id: \.speaker.id) { row in
                    Button { pick(row.speaker) } label: {
                        HStack {
                            HStack(spacing: 7) {
                                Circle().fill(row.color).frame(width: 9, height: 9)
                                Text(row.speaker.name).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            cell("\(row.reports.count)")
                            cell(avg(row.reports) { $0.fillersPerMin }, "%.1f")
                            cell(avg(row.reports) { $0.delivery?.averageWPM }, "%.0f")
                            cell(avg(row.reports) { $0.delivery?.pitchRangeSemitones }, "%.1f")
                            cell(avg(row.reports) { $0.coach.map { Double($0.score) } }, "%.1f/10")
                        }
                        .padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            let points = rows.flatMap { row in row.reports.map { (row.speaker.name, $0.videoDate, $0.fillersPerMin) } }
            if points.count >= 2 {
                AssessCard(title: "Filler words per minute", subtitle: "Every assessed message, by speaker") {
                    Chart {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Date", p.1), y: .value("Fillers / min", p.2))
                                .foregroundStyle(by: .value("Speaker", p.0))
                            PointMark(x: .value("Date", p.1), y: .value("Fillers / min", p.2))
                                .foregroundStyle(by: .value("Speaker", p.0))
                        }
                    }
                    .chartForegroundStyleScale(domain: rows.map(\.speaker.name), range: rows.map(\.color))
                    .frame(height: 160)
                }
            }
        }
    }

    private func avg(_ rs: [SpeakerReport], _ f: (SpeakerReport) -> Double?) -> Double? {
        let v = rs.compactMap(f)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    private func cell(_ v: Double?, _ fmt: String) -> some View { cell(v.map { String(format: fmt, $0) } ?? "–") }
    private func cell(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(gold).frame(width: 84, alignment: .trailing)
    }
}
