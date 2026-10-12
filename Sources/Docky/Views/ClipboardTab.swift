import AppKit
import SwiftUI

private let shareTint = Color(red: 0.25, green: 0.56, blue: 1.0)

/// A shelf for files: drop things on it to keep them, drag them back out into any app,
/// or drop them on Share to send them somewhere.
struct ClipboardTab: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clipboard: ClipboardStore
    @State private var shelfTargeted = false
    @State private var shareTargeted = false
    @State private var shareFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 12) {
            shelf
            shareZone
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: shelfTargeted)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: shareTargeted)
    }

    private var shelf: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(shelfTargeted ? 0.11 : 0.05))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.white.opacity(shelfTargeted ? 0.55 : (clipboard.items.isEmpty ? 0.2 : 0)))

            if clipboard.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(shelfTargeted ? 0.9 : 0.35))
                        .symbolEffect(.bounce, value: shelfTargeted)
                    Text(shelfTargeted ? "Drop to Keep" : "Drop Files Here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                    Text("They stay here until you remove them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .transition(.island())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(clipboard.items) { item in
                            ClipTile(item: item) { share([item.url]) }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: clipboard.items.map(\.id))
                }
                .transition(.island())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(shelfTargeted ? 1.015 : 1)
        .onDrop(of: ClipboardStore.supportedTypes, isTargeted: $shelfTargeted) { providers in
            clipboard.add(providers: providers)
        }
    }

    private var shareZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 21, weight: .semibold))
                .symbolEffect(.bounce, value: shareTargeted)
            Text("Share")
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(shareTargeted ? Color.white : shareTint)
        .frame(width: 96)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(shareTargeted ? shareTint.opacity(0.85) : shareTint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(shareTint.opacity(shareTargeted ? 0 : 0.45))
        )
        .scaleEffect(shareTargeted ? 1.06 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { shareFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, frame in shareFrame = frame }
        })
        .onTapGesture { share(clipboard.items.map(\.url)) }
        .help(clipboard.items.isEmpty ? "Drop a file here to share it" : "Share everything on the shelf")
        .onDrop(of: ClipboardStore.supportedTypes, isTargeted: $shareTargeted) { providers in
            ClipboardStore.resolve(providers) { urls in share(urls) }
        }
    }

    private func share(_ urls: [URL]) {
        model.share(urls, from: shareFrame)
    }
}

struct ClipTile: View {
    @EnvironmentObject var clipboard: ClipboardStore
    let item: ClipItem
    var onShare: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumb = clipboard.thumbnails[item.id] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 74, height: 28, alignment: .top)
        }
        .padding(.vertical, 8)
        .frame(width: 86)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation { clipboard.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(PressableStyle(scale: 0.8))
                .offset(x: 3, y: -3)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(item.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Share…", action: onShare)
            Divider()
            Button("Remove") { withAnimation { clipboard.remove(item) } }
            Button("Remove All") { withAnimation { clipboard.clear() } }
        }
    }
}
