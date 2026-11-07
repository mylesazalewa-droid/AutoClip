import SwiftUI

/// Header chip with this month's AI spend. Opens a breakdown by video and the on-device
/// AI switch.
struct AIUsageChip: View {
    @ObservedObject private var meter = CostMeter.shared
    @State private var show = false
    @State private var hover = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 12))
                Text("AI " + CostMeter.dollars(meter.thisMonth)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .foregroundColor(hover ? Theme.cream : Theme.sand)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().stroke(Theme.sand.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("What AI has cost this month, and on-device AI")
        .popover(isPresented: $show, arrowEdge: .bottom) { AIUsageView() }
    }
}

struct AIUsageView: View {
    @ObservedObject private var meter = CostMeter.shared
    @State private var localOn = LocalAI.enabled
    @State private var models: [String]? = nil
    @State private var checking = true
    @State private var model = LocalAI.model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand)
                Text("AI USAGE").font(.system(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(CostMeter.dollars(meter.thisMonth), "this month")
                stat("\(meter.callsThisMonth)", "AI calls")
                stat(CostMeter.dollars(meter.allTime), "all time")
            }
            let rows = meter.byVideo
            if rows.isEmpty {
                Text("No AI calls this month yet.").font(.system(size: 13)).foregroundColor(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.prefix(8), id: \.video) { r in
                        HStack {
                            Text(r.video).font(.system(size: 13)).foregroundColor(Theme.text).lineLimit(1)
                            Spacer()
                            Text("\(r.calls) call\(r.calls == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                            Text(CostMeter.dollars(r.cost)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundColor(Theme.cream).frame(width: 56, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                    }
                }
            }
            Text("Estimated from the tokens each AI reports and its list price. Your provider's bill is the final word.")
                .font(.system(size: 11.5)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Theme.line).frame(height: 1)

            Toggle(isOn: $localOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use this Mac for simple jobs").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.cream)
                    Text("Hooks, post captions, hashtags and topic ideas run on-device: free and private. Picking clips still uses your cloud AI.")
                        .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Theme.sand)
            .onChange(of: localOn) { _, v in LocalAI.enabled = v }

            if localOn {
                if checking {
                    Text("Looking for Ollama…").font(.system(size: 12)).foregroundColor(Theme.faint)
                } else if let models, !models.isEmpty {
                    Picker("Model", selection: $model) {
                        Text("Best available").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .font(.system(size: 13)).frame(maxWidth: 280)
                    .onChange(of: model) { _, v in LocalAI.model = v }
                    Label("Ready on this Mac", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundColor(Theme.good)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On-device AI needs the free Ollama app with a model installed. Install it from ollama.com, then run “ollama pull llama3.2”.")
                            .font(.system(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        Button("Check again") { Task { await check() } }.buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
            }

            if !meter.entries.isEmpty {
                Button("Clear history") { meter.reset() }.buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.surface)
        .task { await check() }
    }

    private func check() async {
        checking = true
        models = await LocalAI.installedModels()
        checking = false
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(Theme.display(22)).foregroundColor(Theme.cream).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.muted)
        }
    }
}
