import PeakCore
import SwiftUI

/// The row on a peak's card that opens it in 3D.
struct PeakIn3DRow: View {
    let model: AppModel
    let peak: Peak
    /// The scene the card belongs to: the live view's or a photo's.
    let scene: TerrainScene?
    /// The scene is a photo's, so its position is the photo spot, not you.
    let isPhoto: Bool
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "view.3d")
                    .foregroundStyle(.amber)
                    .accessibilityHidden(true)
                Text("See it in 3D")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .fullScreenCover(isPresented: $showing) {
            PeakIn3DView(model: model, peak: peak, scene: scene, isPhoto: isPhoto)
        }
    }
}

/// A summit in 3D on its own, drawn as the walk in 3D draws a trail's ground: satellite
/// imagery over the terrain when that's the map's style and there's a connection, else the
/// terrain's own colors, tinted where OpenStreetMap has glaciers, water and bare rock; far
/// ridges fading into the haze; the summit named, and the mountains around it while they're
/// in sight. It opens looking straight down, then tilts
/// to look at the summit from the side it's seen from (you, or the photo spot). Drag to go
/// around it, pinch to come closer. Drawn from the terrain already on the phone, so it works
/// offline.
struct PeakIn3DView: View {
    let model: AppModel
    let peak: Peak
    /// The card's scene: the live view's, seen from you, or a photo's, from where it was taken.
    let scene: TerrainScene?
    let isPhoto: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var world: WalkWorld?
    @State private var player = WalkPlayer()
    @State private var imagery = WalkImagery()
    @State private var failed = false
    /// Some of the terrain drawn is USGS 3DEP's bare ground, to credit.
    @State private var usgs = false
    /// Where the chip and the footer are, in window coordinates, for labels to keep clear of.
    @State private var chipFrame = CGRect.zero
    @State private var footerFrame = CGRect.zero

    var body: some View {
        let satellite = model.settings.mapStyle == .satellite
        ZStack {
            TrailFromAboveView.background
                .ignoresSafeArea()
            if let world {
                // The blue dot is you; a photo's spot isn't.
                WalkSceneView(world: world, player: player, you: isPhoto ? nil : scene?.position, label: "\(peak.name) in 3D")
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else if failed {
                ContentUnavailableView("No terrain here yet", systemImage: "mountain.2",
                                       description: Text("The mountain is drawn in 3D from the terrain around it, once it's loaded."))
            } else {
                ProgressView()
                    .tint(.white)
            }
            if world != nil {
                // Snow and glaciers can be bright in either style: shade the bottom so the
                // hint and the credits stay readable.
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 150)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                PeakIn3DChip(name: peak.name, detail: subtitle) { dismiss() }
                    // Larger text grows it only so far, so the mountain stays in view.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chipFrame = $0 }
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                Spacer()
                if world != nil {
                    PeakIn3DFooter(draped: imagery.draped, usgs: usgs)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { footerFrame = $0 }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: scene.map { ObjectIdentifier($0.terrain) }) {
            await build()
        }
        .task(id: model.online) {
            await model.fetchCover(key: coverKey, box: coverBox)
        }
        // Over satellite imagery when that's the map's style and it loads; in the terrain's own
        // colors otherwise, or until it does.
        .task(id: WalkImagery.DrapeKey(world: world, satellite: satellite, online: model.online)) {
            await imagery.drape(satellite: satellite)
        }
        // Sharper imagery around the summit, once the imagery is laid.
        .task(id: WalkImagery.DetailKey(world: world, draped: imagery.draped, online: model.online)) {
            await imagery.sharpen(player: player)
        }
        // Land cover that arrives once it's drawn tints the terrain where it stands.
        .task(id: [model.covers[coverKey]?.revision ?? -1, world == nil ? 0 : 1]) {
            if let world, let cover = model.covers[coverKey] { await world.tint(with: cover) }
        }
        // The mountains around, to label: those the card's scene knows.
        .task(id: LabelKey(world: world.map(ObjectIdentifier.init), peaks: scene?.allPeaks.count ?? 0)) {
            guard let world, let peaks = scene.map({ Array($0.allPeaks.values.map(\.peak)) }) else { return }
            let pool = await Task.detached(priority: .userInitiated) { world.peaksToLabel(from: peaks) }.value
            guard !Task.isCancelled else { return }
            world.labelPeaks = pool
        }
        .onChange(of: [chipFrame, footerFrame], initial: true) { _, frames in player.keepClear = frames }
        .onAppear { model.showsPeakIn3D = true }
        .onDisappear {
            player.stop()
            model.showsPeakIn3D = false
        }
    }

    private var subtitle: String {
        if world == nil { return failed ? "No terrain loaded" : "Building the terrain…" }
        let units = model.settings.units
        var parts = [Format.elevation(of: peak, units)]
        if let distance = scene?.allPeaks[peak.id]?.distance {
            parts.append("\(Format.distance(distance, units)) from \(isPhoto ? "the photo spot" : "you")")
        }
        return parts.joined(separator: " · ")
    }

    /// The summit's land cover, kept apart from the trails'.
    private var coverKey: String { "summit/\(peak.id)" }
    private var coverBox: GeoBox { GeoBox(TrailTerrainStyle.extent(peak: peak)) }

    private struct LabelKey: Equatable {
        var world: ObjectIdentifier?
        var peaks: Int
    }

    private func build() async {
        guard let terrain = scene?.terrain else {
            failed = true
            return
        }
        let peak = peak, viewer = scene?.position, units = model.settings.units
        let cover = await model.savedCover(key: coverKey, box: coverBox)
        guard !Task.isCancelled else { return }
        let (built, ground) = await Task.detached(priority: .userInitiated) {
            (WalkWorld.build(peak: peak, seenFrom: viewer, terrain: terrain, cover: cover, units: units),
             Self.hasGround(terrain, around: peak.position))
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            world = built
            failed = built == nil
            usgs = ground
            imagery.show(built)
        }
    }

    /// Whether USGS bare ground is under any of the terrain drawn, the ring around the sharp
    /// terrain included, sampled every kilometer.
    private nonisolated static func hasGround(_ terrain: Terrain, around center: LatLon) -> Bool {
        guard !terrain.groundPatches.isEmpty else { return false }
        let projection = MapProjection(center: center), half = 35
        for i in -half...half {
            for j in -half...half {
                let p = projection.latLon(SIMD2(Double(i), Double(j)) * 1_000)
                if terrain.hasGround(latitude: p.latitude, longitude: p.longitude) { return true }
            }
        }
        return false
    }
}

/// The summit's name, how high and how far, and the way back to the card.
private struct PeakIn3DChip: View {
    let name: String
    let detail: String
    let onClose: () -> Void
    /// As on the other floating controls, growing with the text size.
    @ScaledMetric(relativeTo: .caption) private var titleSize = 13.0
    @ScaledMetric(relativeTo: .caption2) private var detailSize = 11.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(Color.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: detailSize))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
                    // A full target around the smaller circle: a button takes taps only within
                    // its label's frame. The chip's padding makes up for it.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.vertical, 1)
        .frame(maxWidth: 420)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// How to look around, and the credits.
private struct PeakIn3DFooter: View {
    let draped: Bool
    /// Some of the terrain drawn is USGS 3DEP's.
    let usgs: Bool
    @ScaledMetric(relativeTo: .caption2) private var hintSize = 11.0
    @ScaledMetric(relativeTo: .caption2) private var creditSize = 9.0

    var body: some View {
        VStack(spacing: 8) {
            Text("Drag to look around · pinch to come closer")
                .font(.system(size: hintSize))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
            Text((draped ? "Imagery © Apple Maps · " : "") + "Terrain © Copernicus DEM (DLR, Airbus)" +
                 (usgs ? ", USGS 3DEP" : "") + ", NOAA ETOPO · Map data © OpenStreetMap contributors")
                .font(.system(size: creditSize))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
