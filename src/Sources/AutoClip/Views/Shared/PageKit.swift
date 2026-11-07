import SwiftUI

// The pieces every page is built from, so Auto Reels, Podcast, Assess and Search look and
// behave alike: a page header, a sidebar of items, pill tabs, search pills and empty states.

/// The top of a page: a small sand eyebrow, a serif title, a line of detail, and the page's
/// actions on the right.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand)
                    Text(eyebrow.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
                }
                Text(title).font(Theme.display(36, weight: .medium)).foregroundColor(Theme.ink).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { trailing }
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 20)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Pill tabs that switch between the parts of a page.
struct PillTabs<T: Hashable>: View {
    @Binding var selection: T
    let items: [(value: T, title: String)]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.value) { item in
                PillTab(title: item.title, active: item.value == selection, compact: compact) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = item.value }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.ink.opacity(0.04)))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .fixedSize()
    }
}

private struct PillTab: View {
    let title: String
    let active: Bool
    let compact: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 11 : 12, weight: active ? .semibold : .medium))
                .foregroundColor(active ? Theme.bg : hover ? Theme.text : Theme.muted)
                .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 6)
                .background(Capsule().fill(active ? Theme.sand : hover ? Theme.ink.opacity(0.06) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A rounded search field.
struct SearchPill: View {
    @Binding var text: String
    var placeholder = "Search"
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.faint)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(Theme.faint) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: width)
        .background(Capsule().fill(Theme.ink.opacity(0.05)))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

/// The list down the left of Podcast and Assess.
struct SidebarPanel<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(Theme.display(13, weight: .medium)).tracking(2.2).foregroundColor(Theme.cream)
                Spacer()
                actions
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            content
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
    }
}

/// One item in a sidebar: a small picture (or icon), a title and a detail line. The chosen one
/// is raised with a sand edge.
struct SidebarRow: View {
    var thumb: String?
    let icon: String
    let title: String
    var detail: String?
    let selected: Bool
    var hovering: Binding<Bool>? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumb {
                    ReelThumbnailView(path: thumb).frame(width: 56, height: 34).clipped()
                } else {
                    LinearGradient(colors: [Theme.navy, Theme.charcoal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 13)).foregroundColor(Theme.sand.opacity(0.8))
                }
            }
            .frame(width: 56, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.ink.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? Theme.cream : Theme.text.opacity(0.85))
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundColor(selected ? Theme.sand : Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.raised : hover ? Theme.ink.opacity(0.035) : Color.clear)
        )
        .overlay(alignment: .leading) {
            Capsule().fill(selected ? Theme.sand : Color.clear).frame(width: 3, height: 22).offset(x: -1)
        }
        .contentShape(Rectangle())
        .onHover { h in hover = h; hovering?.wrappedValue = h }
    }
}

/// A small icon button for sidebars and headers.
struct IconPillButton: View {
    let icon: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(hover ? Theme.cream : Theme.sand)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.ink.opacity(hover ? 0.1 : 0.05)))
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// What a page shows before there's anything in it.
struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 26)).foregroundColor(Theme.sand)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.sand.opacity(0.08)))
                .overlay(Circle().stroke(Theme.sand.opacity(0.3), lineWidth: 1))
            Text(title).font(Theme.display(24)).foregroundColor(Theme.cream)
            Text(message).font(.system(size: 13)).foregroundColor(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions }.padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
