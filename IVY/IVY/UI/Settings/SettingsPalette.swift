import SwiftUI

/// Opaque neutral surfaces prevent wallpaper tint from coloring the settings window.
enum SettingsPalette {
    static func window(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.11 : 0.99) }
    static func sidebar(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.14 : 0.95) }
    static func card(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.16 : 1) }
    static func border(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.25 : 0.88) }
}

struct ConnectorLogo: View {
    let listing: ConnectorListing?
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let listing, ConnectorListing.featured.contains(where: { $0.id == listing.id }) {
                Image("Connector-" + listing.id).resizable().scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary).padding(6)
            }
        }.frame(width: size, height: size)
            .accessibilityLabel(listing?.title ?? "Custom connector")
    }
}
