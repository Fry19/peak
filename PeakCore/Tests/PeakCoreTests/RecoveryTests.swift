import XCTest
@testable import PeakCore

final class BackoffTests: XCTestCase {
    func testDoublesUpToTheCapAndResets() {
        var b = Backoff(initial: 5, maximum: 60)
        XCTAssertEqual((0..<6).map { _ in b.next() }, [5, 10, 20, 40, 60, 60])
        b.reset()
        XCTAssertEqual(b.next(), 5)
    }

    func testManyTriesDontOverflow() {
        var b = Backoff(initial: 5, maximum: 300)
        for _ in 0..<1_000 { _ = b.next() }
        XCTAssertEqual(b.next(), 300)
    }
}

final class CopernicusBucketTests: XCTestCase {
    private let noSuchKey = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>
    """.utf8)
    private let accessDenied = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied</Message><RequestId>X</RequestId></Error>
    """.utf8)

    func testS3SayingThereIsNoTileIsSea() {
        XCTAssertEqual(CopernicusBucket.answer(status: 404, server: "AmazonS3", body: noSuchKey), .sea)
        XCTAssertEqual(CopernicusBucket.answer(status: 403, server: "AmazonS3", body: accessDenied), .sea)
    }

    func testTilesAreData() {
        XCTAssertEqual(CopernicusBucket.answer(status: 206, server: "AmazonS3", body: Data([1, 2])), .data)
        XCTAssertEqual(CopernicusBucket.answer(status: 200, server: nil, body: Data()), .data)
    }

    func testAnyoneElsesRefusalIsAnError() {
        // A captive portal or proxy answering for the bucket.
        XCTAssertEqual(CopernicusBucket.answer(status: 403, server: "nginx", body: Data("<html>Log in</html>".utf8)), .error)
        XCTAssertEqual(CopernicusBucket.answer(status: 404, server: nil, body: noSuchKey), .error)
        XCTAssertEqual(CopernicusBucket.answer(status: 403, server: "AmazonS3", body: Data("<html></html>".utf8)), .error)
        XCTAssertEqual(CopernicusBucket.answer(status: 403, server: "AmazonS3",
                                               body: Data("<Error><Code>SlowDown</Code></Error>".utf8)), .error)
        XCTAssertEqual(CopernicusBucket.answer(status: 500, server: "AmazonS3", body: noSuchKey), .error)
        XCTAssertEqual(CopernicusBucket.answer(status: 0, server: nil, body: Data()), .error)
    }
}

final class LocationQualityTests: XCTestCase {
    func testLoadingNeedsAFixGoodEnoughForTheTiles() {
        XCTAssertTrue(LocationQuality.usableForLoading(accuracy: 65, precise: true))
        XCTAssertFalse(LocationQuality.usableForLoading(accuracy: 3_000, precise: true))
        XCTAssertTrue(LocationQuality.usableForLoading(accuracy: 3_000, precise: false))
        XCTAssertFalse(LocationQuality.usableForLoading(accuracy: -1, precise: false))
    }

    func testARoughSceneIsRefinedByAMuchBetterFix() {
        // Built from a rough first fix; a 65 m fix at a hut window refines it.
        XCTAssertTrue(LocationQuality.shouldRefine(sceneAccuracy: 1_500, newAccuracy: 65, moved: 20))
        XCTAssertTrue(LocationQuality.shouldRefine(sceneAccuracy: 200, newAccuracy: 65, moved: 0))
        // Just good enough to match where the view's fix wasn't.
        XCTAssertTrue(LocationQuality.shouldRefine(sceneAccuracy: 120, newAccuracy: 90, moved: 0))
        // About as good: not worth a rebuild.
        XCTAssertFalse(LocationQuality.shouldRefine(sceneAccuracy: 65, newAccuracy: 60, moved: 20))
        XCTAssertFalse(LocationQuality.shouldRefine(sceneAccuracy: 1_500, newAccuracy: 1_200, moved: 400))
    }

    func testMovingFurtherThanTheUncertaintyRebuilds() {
        XCTAssertTrue(LocationQuality.shouldRefine(sceneAccuracy: 10, newAccuracy: 10, moved: 80))
        XCTAssertFalse(LocationQuality.shouldRefine(sceneAccuracy: 10, newAccuracy: 10, moved: 30))
        XCTAssertTrue(LocationQuality.shouldRefine(sceneAccuracy: 65, newAccuracy: 65, moved: 120))
        XCTAssertFalse(LocationQuality.shouldRefine(sceneAccuracy: 65, newAccuracy: 65, moved: 60))
    }
}

final class AppStatusTests: XCTestCase {
    func testCameraDeniedStaysWhateverLoadingDoes() {
        for load: AppStatus.Load in [.locating, .loading("Getting terrain…"), .ready, .failed("x")] {
            let s = AppStatus.resolve(camera: .denied, location: .granted, preciseLocation: true, load: load)
            guard case .problem(_, .openSettings) = s else { return XCTFail("\(load): \(s)") }
        }
    }

    func testLocationDeniedOffersSettings() {
        let s = AppStatus.resolve(camera: .running, location: .denied, preciseLocation: true, load: .locating)
        guard case let .problem(text, .openSettings) = s else { return XCTFail("\(s)") }
        XCTAssertTrue(text.contains("location"))
    }

    func testFailuresOfferRetry() {
        guard case .problem(_, .retry) = AppStatus.resolve(camera: .failed, location: .granted, preciseLocation: true, load: .ready)
        else { return XCTFail() }
        guard case .problem(_, .retry) = AppStatus.resolve(camera: .running, location: .granted, preciseLocation: true,
                                                           load: .failed("Couldn't download the terrain."))
        else { return XCTFail() }
    }

    func testInterruptionIsExplainedWithNothingToDo() {
        XCTAssertEqual(AppStatus.resolve(camera: .interrupted("In use"), location: .granted, preciseLocation: true, load: .ready),
                       .problem("In use", action: nil))
    }

    func testApproximateLocation() {
        guard case .problem(_, .openSettings) = AppStatus.resolve(camera: .running, location: .granted, preciseLocation: false,
                                                                  load: .locating)
        else { return XCTFail() }
        XCTAssertEqual(AppStatus.resolve(camera: .running, location: .granted, preciseLocation: false, load: .ready),
                       .ready(note: "Approximate location"))
    }

    func testNormalProgress() {
        XCTAssertEqual(AppStatus.resolve(camera: .starting, location: .undetermined, preciseLocation: true, load: .locating), .locating)
        XCTAssertEqual(AppStatus.resolve(camera: .running, location: .granted, preciseLocation: true, load: .loading("a")), .loading("a"))
        XCTAssertEqual(AppStatus.resolve(camera: .running, location: .granted, preciseLocation: true, load: .ready), .ready(note: nil))
    }
}
