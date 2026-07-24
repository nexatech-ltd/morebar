import SwiftUI

/// Содержимое второго бара: ряд «живых» снимков спрятанных иконок.
/// Никакого собственного фона — стекло даёт NSGlassEffectView снаружи.
struct SecondBarView: View {
    struct Entry: Identifiable {
        let id: CGWindowID
        let image: NSImage
        let title: String?
    }

    enum Content {
        case items([Entry])
        case empty
        case needsPermissions(accessibility: Bool, screenRecording: Bool)
        case needsRelaunch
    }

    let content: Content
    let barHeight: CGFloat
    var onItemClick: (CGWindowID, _ rightClick: Bool) -> Void = { _, _ in }
    var onOpenAccessibility: () -> Void = {}
    var onOpenScreenRecording: () -> Void = {}
    var onRelaunch: () -> Void = {}

    var body: some View {
        Group {
            switch content {
            case .items(let entries):
                HStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ItemCell(entry: entry, barHeight: barHeight, onClick: onItemClick)
                    }
                }
                .padding(.horizontal, 6)

            case .empty:
                Text("Нет спрятанных иконок")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)

            case .needsPermissions(let accessibility, let screenRecording):
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("MoreBar нужны разрешения:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if !accessibility {
                        Button("Универсальный доступ", action: onOpenAccessibility)
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                    if !screenRecording {
                        Button("Запись экрана", action: onOpenScreenRecording)
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 14)

            case .needsRelaunch:
                HStack(spacing: 10) {
                    Text("Права выданы")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Перезапустить MoreBar", action: onRelaunch)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(height: barHeight)
        .fixedSize()
    }
}

/// Одна иконка: снимок в натуральную величину, hover-подсветка как у
/// системных итемов, левый/правый клик.
private struct ItemCell: View {
    let entry: SecondBarView.Entry
    let barHeight: CGFloat
    let onClick: (CGWindowID, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: entry.image)
            .frame(height: barHeight)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    .padding(.vertical, 3)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { onClick(entry.id, false) }
            .simultaneousGesture(
                TapGesture().modifiers(.control).onEnded { onClick(entry.id, true) }
            )
            .help(entry.title ?? "")
    }
}
