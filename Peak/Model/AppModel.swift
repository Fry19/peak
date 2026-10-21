import ARKit
import CoreLocation
import Observation
import PeakCore
import SwiftUI

@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case loading(String)
        case ready
        case needsPermission(String)
        case failed(String)
    }

    /// The compass correction from skyline matching, smoothed over frames.
    struct Correction {
        var degrees = 0.0
        var matches = 0
        var lastMatch: Date?
        var lastRMS = 0.0

        /// Matched recently enough to trust over the compass.
        var isAligned: Bool { lastMatch.map { Date().timeIntervalSince($0) < 20 } ?? false }

        mutating func add(_ delta: Double, rms: Double) {
            // Take the first match whole; after that, move halfway each time so a single
            // odd frame can't make the labels jump.
            degrees += matches == 0 ? delta : 0.5 * delta
            matches += 1
            lastMatch = Date()
            lastRMS = rms
        }
    }

    /// A paused view: the camera picture and the camera that took it.
    struct Frozen {
        var image: UIImage
        var camera: ARCamera
    }

    var phase: Phase = .locating
    var scene: TerrainScene?
    var correction = Correction()
    var frozen: Frozen?

    let session = ARSession()
    @ObservationIgnored weak var arView: ARSCNView?
    private let locationManager = CLLocationManager()
    private let delegates = Delegates()
    private let store = DataStore()
    private let corrector = SkylineCorrector()
    @ObservationIgnored private var sceneLocation: CLLocation?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastSubmit = Date.distantPast
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true

        delegates.onLocation = { [weak self] in self?.locationChanged($0) }
        delegates.onAuthorization = { [weak self] status in
            if status == .denied || status == .restricted {
                self?.phase = .needsPermission("Peak needs your location to know which mountains you see. Allow it in Settings.")
            }
        }
        locationManager.delegate = delegates
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 50
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        delegates.onFrame = { [weak self] in self?.frameUpdated($0) }
        delegates.onSessionError = { [weak self] error in
            if (error as? ARError)?.code == .cameraUnauthorized {
                self?.phase = .needsPermission("Peak needs the camera to label the mountains. Allow it in Settings.")
            }
        }
        session.delegate = delegates
        let configuration = ARWorldTrackingConfiguration()
        // Gravity for up and the compass for north; skyline matching corrects the compass.
        configuration.worldAlignment = .gravityAndHeading
        session.run(configuration)
    }

    // MARK: Location and data

    private func locationChanged(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100, !loading else { return }
        if let previous = sceneLocation, location.distance(from: previous) < 500 { return }
        load(location)
    }

    private func load(_ location: CLLocation) {
        loading = true
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        if scene == nil { phase = .loading("Getting terrain…") }
        Task { @MainActor in
            defer { loading = false }
            do {
                let terrain = try await store.terrain(latitude: lat, longitude: lon, radius: TerrainScene.radius) { text in
                    Task { @MainActor [weak self] in
                        if self?.scene == nil { self?.phase = .loading(text) }
                    }
                }
                if scene == nil { phase = .loading("Finding peaks…") }
                let peaks = await store.peaks(latitude: lat, longitude: lon, radius: TerrainScene.radius)
                if scene == nil { phase = .loading("Working out what you can see…") }
                let built = await Task.detached(priority: .userInitiated) {
                    TerrainScene.build(terrain: terrain, latitude: lat, longitude: lon, peaks: peaks)
                }.value
                scene = built
                sceneLocation = location
                phase = .ready
            } catch {
                if scene == nil { phase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: Skyline matching

    private func frameUpdated(_ frame: ARFrame) {
        guard let scene, frozen == nil, !corrector.isBusy,
              Date().timeIntervalSince(lastSubmit) > 0.7,
              case .normal = frame.camera.trackingState else { return }
        lastSubmit = Date()
        corrector.submit(frame, scene: scene, correction: correction.degrees) { [weak self] outcome in
            guard let self, let outcome, outcome.accepted else { return }
            self.correction.add(outcome.delta, rms: outcome.rms)
        }
    }

    // MARK: Freeze frame

    func toggleFreeze() {
        if frozen != nil {
            frozen = nil
        } else if let view = arView, let camera = session.currentFrame?.camera {
            frozen = Frozen(image: view.snapshot(), camera: camera)
        }
    }
}

/// Delegate callbacks for location and the AR session, forwarded to closures. Both arrive
/// on the main thread.
private final class Delegates: NSObject, CLLocationManagerDelegate, ARSessionDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onFrame: ((ARFrame) -> Void)?
    var onSessionError: ((Error) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { onLocation?(last) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onSessionError?(error)
    }
}
