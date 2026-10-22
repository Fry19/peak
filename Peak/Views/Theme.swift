import SwiftUI

/// The app's few colors, kept in one place: a night-sky blue-black, a slate a step lighter,
/// and amber for what you act on (and the trail).
extension ShapeStyle where Self == Color {
    /// Behind every sheet and the pages pushed in it, and the views from above and the 3D
    /// walk. Opaque: a material turns light gray over a bright sky or snow, and the rows sink
    /// into it.
    static var sheetBackground: Color { Color(red: 0.035, green: 0.043, blue: 0.058) }
    /// Rows and tiles on a sheet: the same blue, a step lighter, in place of the system's
    /// neutral gray.
    static var sheetSurface: Color { Color(red: 0.085, green: 0.1, blue: 0.125) }
    /// The accent: buttons that do something, the trail, its profile.
    static var amber: Color { Color(red: 1, green: 0.72, blue: 0.28) }
    /// Laid over the glass controls, so over plain black they're the sheets' blue rather than
    /// a neutral gray; over the camera they still read as glass.
    static var glassTint: Color { Color(red: 0.035, green: 0.043, blue: 0.058).opacity(0.3) }
}

extension View {
    /// A sheet's list section, its rows in the app's slate instead of the system gray. Rows
    /// that set their own background keep it.
    func sheetSection() -> some View {
        listRowBackground(Color.sheetSurface)
    }

    /// The floating controls' frosted glass, tinted toward the app's blue.
    func glassBackground(in shape: some Shape) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.glassTint))
        }
    }
}
