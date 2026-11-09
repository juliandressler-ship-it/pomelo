import SwiftUI

/// Willkommensfenster beim ersten Start (Phase 2).
/// Links das echte Rad als Vorschau, rechts die drei Tasten mit Tastenkappen.
struct WelcomeView: View {
    @EnvironmentObject private var settings: AppSettings
    let done: () -> Void
    let openSettings: () -> Void

    static let width: CGFloat = 760
    static let height: CGFloat = 480

    private let preview: [RadialItem] = [FileFormat.jpg, .webp, .heic, .tiff, .avif, .bmp, .pdf].map(RadialItem.init(format:))

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.primary.opacity(0.03)
                RadialWheelView(
                    items: preview,
                    highlighted: 0,
                    title: "JPG",
                    caption: "Convert to JPG",
                    modeKey: settings.key(for: .convert),
                    emptyMessage: "",
                    emptyDetail: "",
                    geometry: RadialGeometry(count: preview.count)
                )
                .scaleEffect(0.78)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: BrandArtwork.image(size: 128))
                    .resizable().frame(width: 48, height: 48)
                    .padding(.bottom, 16)
                Text("Convert files where they are")
                    .font(.system(size: 24, weight: .medium))
                Text("Drag files in Finder, hold a key and drop them on the wheel. The result appears next to the original.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 16) {
                    row(.convert, "Convert", "PNG to JPEG, MP4 to GIF and more")
                    row(.tools, "Tools", "Compress, crop, metadata, PDF tools")
                    row(.actions, "File actions", "Reveal, copy paths, checksum")
                }
                .padding(.top, 28)

                Spacer(minLength: 24)

                HStack(spacing: 12) {
                    Label("Stays on this Mac", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    Button("Settings…", action: openSettings)
                        .controlSize(.large)
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 28)
        }
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
    }

    private func row(_ wheel: AppSettings.Wheel, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Keycap(key: settings.key(for: wheel), size: .regular)
                .frame(minWidth: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}
