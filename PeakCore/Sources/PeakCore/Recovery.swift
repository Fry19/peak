import Foundation

/// Waits between tries that double each time, up to `maximum` seconds.
public struct Backoff: Equatable, Sendable {
    public var initial: Double
    public var maximum: Double
    public private(set) var attempts = 0

    public init(initial: Double = 5, maximum: Double = 300) {
        self.initial = initial
        self.maximum = maximum
    }

    /// The wait before the next try, seconds.
    public mutating func next() -> Double {
        let wait = min(maximum, initial * pow(2, Double(min(attempts, 30))))
        attempts += 1
        return wait
    }

    /// Back to the first, short wait (the connection came back, or a try worked).
    public mutating func reset() {
        attempts = 0
    }
}

/// The Copernicus bucket on S3: whether an answer means there's no tile (open sea) or the
/// download went wrong.
public enum CopernicusBucket {
    public enum Answer: Equatable {
        case data
        /// The bucket says it has no such tile.
        case sea
        case error
    }

    /// How long a tile counts as sea before the bucket is asked again, seconds.
    public static let seaLifetime: TimeInterval = 90 * 86_400

    /// What an answer means. Only S3 itself can say a tile isn't there: a 403 or 404 from
    /// anything else (a captive portal, a proxy) is an error, or it would flatten a mountain.
    /// The bucket answers a missing key with 403 AccessDenied (it can't be listed) or 404
    /// NoSuchKey, as XML, from a server named AmazonS3.
    public static func answer(status: Int, server: String?, body: Data) -> Answer {
        if status == 200 || status == 206 { return .data }
        guard status == 403 || status == 404,
              server?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("AmazonS3") == .orderedSame
        else { return .error }
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        guard text.contains("<Error>") else { return .error }
        return text.contains("<Code>NoSuchKey</Code>") || text.contains("<Code>AccessDenied</Code>") ? .sea : .error
    }
}

/// How good a position fix has to be for each thing done with it, meters.
public enum LocationQuality {
    /// Skyline matching may lock only with the view built from a fix this good: from
    /// further off, the horizon it matches against is someone else's.
    public static let matchingAccuracy = 100.0

    /// Whether a fix is good enough to start downloading around (tiles are 1° wide). With
    /// Precise Location off, fixes are a few kilometers at best.
    public static func usableForLoading(accuracy: Double, precise: Bool) -> Bool {
        accuracy >= 0 && accuracy < (precise ? 2_000 : 10_000)
    }

    /// Whether to rebuild the view for a new fix, given the accuracy the view was built
    /// with and how far the new fix is from where it was built: when the fix is much
    /// better or good enough for matching where the view's wasn't, or when you've moved
    /// further than both fixes' uncertainty.
    public static func shouldRefine(sceneAccuracy: Double, newAccuracy: Double, moved: Double) -> Bool {
        guard newAccuracy >= 0 else { return false }
        if sceneAccuracy >= matchingAccuracy, newAccuracy < matchingAccuracy { return true }
        if newAccuracy < 0.6 * sceneAccuracy, sceneAccuracy - newAccuracy > 10 { return true }
        return newAccuracy < 150 && moved > max(50, newAccuracy, sceneAccuracy)
    }
}

/// What the status pill shows, from the camera and location permissions and how loading
/// is going. Each comes from its own source, so one can't overwrite another: a camera that
/// isn't allowed stays the message until it is.
public enum AppStatus: Equatable {
    case locating
    case loading(String)
    /// The view is up; `note` is something to know about it.
    case ready(note: String?)
    /// Something stops the view, and what the pill offers to do about it.
    case problem(String, action: Action?)

    public enum Action: Equatable {
        case openSettings
        case retry
    }

    public enum Permission: Equatable {
        case undetermined
        case granted
        case denied
    }

    public enum Camera: Equatable {
        case starting
        case running
        case denied
        /// Allowed, but it didn't start.
        case failed
        /// Taken away for now (another app, a call), with why; it comes back by itself.
        case interrupted(String)
    }

    public enum Load: Equatable {
        case locating
        case loading(String)
        case ready
        case failed(String)
    }

    public static func resolve(camera: Camera, location: Permission, preciseLocation: Bool, load: Load) -> AppStatus {
        if camera == .denied {
            return .problem("Peak needs the camera to label the mountains. Allow it in Settings.", action: .openSettings)
        }
        if location == .denied {
            return .problem("Peak needs your location to know which mountains you see. Allow it in Settings.",
                            action: .openSettings)
        }
        if camera == .failed { return .problem("The camera didn't start.", action: .retry) }
        if case let .interrupted(why) = camera { return .problem(why, action: nil) }
        switch load {
        case let .failed(why):
            return .problem(why, action: .retry)
        case .locating:
            if location == .granted, !preciseLocation {
                return .problem("Precise Location is off, so Peak can't tell which mountains you see. Turn it on in Settings.",
                                action: .openSettings)
            }
            return .locating
        case let .loading(text):
            return .loading(text)
        case .ready:
            return .ready(note: preciseLocation ? nil : "Approximate location")
        }
    }
}
