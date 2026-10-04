import XCTest

final class ShotResourcePolicyTests: XCTestCase {
    func testParsesLegacyCountAsDeprecatedCompatibilityArgument() throws {
        let parsed = try ShotArguments.parse([
            "seasons-shot", "spring.json", "Resources/sprites", "10",
            "/tmp/out.png", "1280", "800", "150"
        ])

        XCTAssertEqual(parsed.spriteBaseDirectory, "Resources/sprites")
        XCTAssertEqual(parsed.deprecatedSpriteCount, 10)
        XCTAssertEqual(parsed.width, 1280)
        XCTAssertEqual(parsed.height, 800)
        XCTAssertEqual(parsed.frames, 150)
    }

    func testRejectsMalformedLegacyCountRatherThanTreatingItAsZero() {
        XCTAssertThrowsError(try ShotArguments.parse([
            "seasons-shot", "spring.json", "Resources/sprites", "many",
            "/tmp/out.png", "1280", "800", "150"
        ]))
    }

    func testRejectsDimensionsThatCouldExhaustHeadlessMemory() {
        XCTAssertThrowsError(try ShotArguments.parse([
            "seasons-shot", "spring.json", "Resources/sprites", "0",
            "/tmp/out.png", "100000", "100000", "1"
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("pixel budget"))
            XCTAssertTrue(String(describing: error).contains("8192"))
        }
    }

    func testAllowsFiveKWithinHeadlessMemoryBudget() throws {
        let parsed = try ShotArguments.parse([
            "seasons-shot", "spring.json", "Resources/sprites", "0",
            "/tmp/out.png", "5120", "2880", "1"
        ])
        XCTAssertEqual(parsed.width, 5120)
        XCTAssertEqual(parsed.height, 2880)
    }

    func testRejectsSixKThatExceedsHeadlessMemoryBudget() {
        XCTAssertThrowsError(try ShotArguments.parse([
            "seasons-shot", "spring.json", "Resources/sprites", "0",
            "/tmp/out.png", "6720", "3780", "1"
        ]))
    }

    func testParsesCompletePanoramaEnvironment() throws {
        let parsed = try XCTUnwrap(ShotPanoramaConfiguration.parse(environment: [
            "SEASONS_PANORAMA_WORLD": "9000,3000",
            "SEASONS_PANORAMA_CAMERA": "3000,0,3000,1800",
            "SEASONS_PANORAMA_WIND": "12.5,-3",
            "SEASONS_PANORAMA_SEED": "42"
        ]))
        XCTAssertEqual(parsed.worldSize, SIMD2(9000, 3000))
        XCTAssertEqual(parsed.cameraOrigin, SIMD2(3000, 0))
        XCTAssertEqual(parsed.cameraSize, SIMD2(3000, 1800))
        XCTAssertEqual(parsed.windOrigin, SIMD2(12.5, -3))
        XCTAssertEqual(parsed.worldSeed, 42)
    }

    func testRejectsPartialOrMalformedPanoramaEnvironment() {
        XCTAssertThrowsError(try ShotPanoramaConfiguration.parse(environment: [
            "SEASONS_PANORAMA_WORLD": "9000,3000"
        ]))
        XCTAssertThrowsError(try ShotPanoramaConfiguration.parse(environment: [
            "SEASONS_PANORAMA_WORLD": "9000,nan",
            "SEASONS_PANORAMA_CAMERA": "0,0,3000,1800"
        ]))
        XCTAssertThrowsError(try ShotPanoramaConfiguration.parse(environment: [
            "SEASONS_PANORAMA_WORLD": "9000,3000",
            "SEASONS_PANORAMA_CAMERA": "0,0,3000,1800",
            "SEASONS_PANORAMA_WIND": "1"
        ]))
        XCTAssertThrowsError(try ShotPanoramaConfiguration.parse(environment: [
            "SEASONS_PANORAMA_WORLD": "9000,3000",
            "SEASONS_PANORAMA_CAMERA": "0,0,3000,1800",
            "SEASONS_PANORAMA_SEED": "-1"
        ]))
    }

    func testWorldOriginDefaultsToZeroAndRejectsMalformedValues() throws {
        XCTAssertEqual(try ShotWorldOriginPolicy.parse(environment: [:]), .zero)
        XCTAssertEqual(try ShotWorldOriginPolicy.parse(environment: [
            "SEASONS_WORLD_ORIGIN": "3840,-120"
        ]), SIMD2(3840, -120))
        XCTAssertThrowsError(try ShotWorldOriginPolicy.parse(environment: [
            "SEASONS_WORLD_ORIGIN": "3840"
        ]))
        XCTAssertThrowsError(try ShotWorldOriginPolicy.parse(environment: [
            "SEASONS_WORLD_ORIGIN": "nan,0"
        ]))
    }

    func testResolvesEveryImageSpeciesUnderSharedBaseDirectory() throws {
        let requirements = [
            ShotSpriteRequirement(set: "petals", count: 2, imageBacked: true),
            ShotSpriteRequirement(set: "blossom", count: 1, imageBacked: true)
        ]

        let plans = try ShotResourcePolicy.resolve(
            baseDirectoryArgument: "/project/Resources/sprites",
            requirements: requirements,
            canLoad: { _ in true }
        )

        XCTAssertEqual(plans[0]?.directory.path, "/project/Resources/sprites/petals")
        XCTAssertEqual(plans[0]?.imageURLs.map(\.lastPathComponent), ["1.png", "2.png"])
        XCTAssertEqual(plans[1]?.directory.path, "/project/Resources/sprites/blossom")
    }

    func testRejectsSkippedSpriteDirectoryForImageSpecies() {
        XCTAssertThrowsError(try ShotResourcePolicy.resolve(
            baseDirectoryArgument: "-",
            requirements: [ShotSpriteRequirement(set: "snow", count: 1, imageBacked: true)],
            canLoad: { _ in true }
        ))
    }

    func testReportsMissingOrUnloadableImageByExactPath() {
        let missing = "/project/Resources/sprites/snow/2.png"

        XCTAssertThrowsError(try ShotResourcePolicy.resolve(
            baseDirectoryArgument: "/project/Resources/sprites",
            requirements: [ShotSpriteRequirement(set: "snow", count: 2, imageBacked: true)],
            canLoad: { $0.path != missing }
        )) { error in
            XCTAssertTrue(String(describing: error).contains(missing))
        }
    }

    func testRejectsSpriteSetThatEscapesSharedBaseDirectory() {
        XCTAssertThrowsError(try ShotResourcePolicy.resolve(
            baseDirectoryArgument: "/project/Resources/sprites",
            requirements: [ShotSpriteRequirement(set: "../secrets", count: 1,
                                                   imageBacked: true)],
            canLoad: { _ in true }
        )) { error in
            XCTAssertTrue(String(describing: error).contains("invalid spriteSet"))
        }
    }

    func testGlowSpeciesDoesNotRequireSpriteFiles() throws {
        let plans = try ShotResourcePolicy.resolve(
            baseDirectoryArgument: "-",
            requirements: [ShotSpriteRequirement(set: nil, count: 0, imageBacked: false)],
            canLoad: { _ in false }
        )

        XCTAssertNil(plans[0])
    }
}
