import XCTest

final class FrameActivityPolicyTests: XCTestCase {
    func testUnauthorizedSurfaceUsesBlackPathWithoutGPUWork() {
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: false,
                                       animationRequested: true,
                                       reduceMotion: false,
                                       hasPresentedStaticFrame: false),
            .showBlackWithoutGPU
        )
    }

    func testActiveAuthorizedSurfaceAnimates() {
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: true,
                                       reduceMotion: false,
                                       hasPresentedStaticFrame: false),
            .animate
        )
    }

    func testOffRendersOneStaticFrameThenIdles() {
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: false,
                                       reduceMotion: false,
                                       hasPresentedStaticFrame: false),
            .renderStaticOnce
        )
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: false,
                                       reduceMotion: false,
                                       hasPresentedStaticFrame: true),
            .idle
        )
    }

    func testReduceMotionRendersOneStaticFrameThenIdles() {
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: true,
                                       reduceMotion: true,
                                       hasPresentedStaticFrame: false),
            .renderStaticOnce
        )
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: true,
                                       reduceMotion: true,
                                       hasPresentedStaticFrame: true),
            .idle
        )
    }

    func testAnimationResumesAfterStaticStateClears() {
        XCTAssertEqual(
            FrameActivityPolicy.action(surfaceAuthorized: true,
                                       animationRequested: true,
                                       reduceMotion: false,
                                       hasPresentedStaticFrame: true),
            .animate
        )
    }
}
