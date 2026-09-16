import AppKit
import AVFoundation
import SwiftUI

/// Library grid on the left, live preview of the selection on the right.
struct GalleryView: View {
    let model: GalleryModel

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                LibraryPane(model: model)
                    .frame(width: min(max(geo.size.width * 0.38, 300), 540))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(SidebarMaterial())
                Divider()
                StagePane(model: model)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Library

private struct LibraryPane: View {
    let model: GalleryModel
    @FocusState private var gridFocused: Bool

    private let cellMinWidth: CGFloat = 150
    private let spacing: CGFloat = 14
    private let inset: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(countText)
                .font(.headline)
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload library")
            Button {
                model.openLibraryFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open library folder")
        }
        .buttonStyle(.borderless)
        // Clears the traffic lights in the transparent title bar.
        .padding(.top, 46)
        .padding(.horizontal, inset)
        .padding(.bottom, 12)
    }

    private var countText: String {
        let count = model.wallpapers.count
        if count == 0, model.isLoading { return "Loading library" }
        return count == 1 ? "1 wallpaper" : "\(count) wallpapers"
    }

    @ViewBuilder
    private var content: some View {
        if model.wallpapers.isEmpty {
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No wallpapers yet", systemImage: "film.stack")
                } description: {
                    Text("Use Import & Convert in the menu bar to add a video. Converted wallpapers appear here.")
                } actions: {
                    Button("Open Library Folder") { model.openLibraryFolder() }
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - inset * 2 + spacing) / (cellMinWidth + spacing)))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(model.wallpapers) { wallpaper in
                            cell(for: wallpaper)
                        }
                    }
                    .padding(.horizontal, inset)
                    .padding(.top, 4)
                    .padding(.bottom, inset)
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: model.moveSelection(by: -1)
                    case .right: model.moveSelection(by: 1)
                    case .up: model.moveSelection(by: -columns)
                    case .down: model.moveSelection(by: columns)
                    @unknown default: return
                    }
                    if let id = model.selection {
                        proxy.scrollTo(id)
                    }
                }
                .onAppear {
                    gridFocused = true
                    if let id = model.selection {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func cell(for wallpaper: Wallpaper) -> some View {
        ThumbnailCell(
            wallpaper: wallpaper,
            image: model.thumbnails[wallpaper],
            isSelected: model.selection == wallpaper.id,
            isCurrent: model.isCurrent(wallpaper)
        )
        .id(wallpaper.id)
        .onTapGesture(count: 2) {
            model.apply(wallpaper)
        }
        .simultaneousGesture(TapGesture().onEnded {
            model.select(wallpaper.id)
            gridFocused = true
        })
        .contextMenu {
            Button("Set as Wallpaper") { model.apply(wallpaper) }
                .disabled(model.isCurrent(wallpaper))
            Button("Show in Finder") { model.revealInFinder(wallpaper) }
        }
    }
}

private struct ThumbnailCell: View {
    let wallpaper: Wallpaper
    let image: NSImage?
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color(white: 0.14)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if isCurrent {
                        CurrentBadge()
                    }
                }
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                }

            Text(wallpaper.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 3)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCurrent ? "\(wallpaper.name), current wallpaper" : wallpaper.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CurrentBadge: View {
    var body: some View {
        Label("Current", systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }
}

// MARK: - Stage

private struct StagePane: View {
    let model: GalleryModel

    private let footerHeight: CGFloat = 64
    private let gap: CGFloat = 22

    var body: some View {
        let wallpaper = model.selected
        let poster = wallpaper.flatMap { model.thumbnails[$0] }

        GeometryReader { geo in
            let area = CGSize(width: geo.size.width - 72, height: geo.size.height - 46 - 32)
            let aspect = model.screenShape.aspect
            let previewHeight = max(area.height - footerHeight - gap, 80)
            let width = max(min(area.width, previewHeight * aspect), 160)

            Group {
                if let wallpaper {
                    VStack(alignment: .leading, spacing: gap) {
                        DesktopPreview(
                            poster: poster,
                            player: model.player,
                            menuBarFraction: model.screenShape.menuBarFraction
                        )
                        .frame(width: width, height: width / aspect)

                        StageFooter(model: model, wallpaper: wallpaper)
                            .frame(width: width, height: footerHeight, alignment: .topLeading)
                    }
                } else if !model.isLoading, !model.wallpapers.isEmpty {
                    Text("Select a wallpaper to preview it.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: 7)
        }
        .background {
            AmbientGlow(key: wallpaper?.id, image: poster)
        }
    }
}

private struct StageFooter: View {
    let model: GalleryModel
    let wallpaper: Wallpaper

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(wallpaper.name)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                DetailsLine(details: model.details[wallpaper])
            }

            Spacer(minLength: 16)

            Button("Show in Finder") { model.revealInFinder(wallpaper) }
                .controlSize(.large)

            if model.isCurrent(wallpaper) {
                Label("Current wallpaper", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(height: 28)
            } else {
                Button("Set as Wallpaper") { model.apply(wallpaper) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .help("Sets the desktop and lock screen wallpaper.")
            }
        }
    }
}

private struct DetailsLine: View {
    let details: WallpaperDetails?

    var body: some View {
        HStack(spacing: 14) {
            if let details {
                Text(verbatim: "\(Int(details.pixelSize.width)) × \(Int(details.pixelSize.height))")
                Text(Duration.seconds(details.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                if details.frameRate > 0 {
                    Text(verbatim: "\(Int(details.frameRate.rounded())) fps")
                }
                Text(details.fileSize.formatted(.byteCount(style: .file)))
            } else {
                // Holds the line height while details load.
                Text(" ")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// The selected video as it will sit on this display: same aspect ratio, same
/// aspect-fill crop as the wallpaper engine, with the menu bar drawn over it.
private struct DesktopPreview: View {
    let poster: NSImage?
    let player: AVPlayer?
    let menuBarFraction: CGFloat

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(white: 0.06)
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                // Transparent until its first frame, so the poster shows through.
                PlayerView(player: player)
                MenuBarSketch(height: geo.size.height * menuBarFraction)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wallpaper preview")
    }
}

private struct MenuBarSketch: View {
    let height: CGFloat

    var body: some View {
        if height >= 6 {
            TimelineView(.everyMinute) { context in
                HStack(spacing: height * 0.9) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.bold)
                    Spacer()
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    Text(context.date, format: .dateTime.hour().minute())
                }
                .font(.system(size: height * 0.5, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .padding(.horizontal, height * 0.7)
                .frame(height: height)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A heavily blurred copy of the selection behind the stage, so the room
/// takes on the wallpaper's colour.
private struct AmbientGlow: View {
    let key: Wallpaper.ID?
    let image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 90, opaque: true)
                        .opacity(0.38)
                        .id(key)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: key)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - AppKit bridges

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView {
        PlayerLayerView()
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer?.player !== player {
            view.playerLayer?.player = player
        }
    }
}

private final class PlayerLayerView: NSView {
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
