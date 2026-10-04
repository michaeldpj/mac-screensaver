import XCTest

final class SeasonTests: XCTestCase {
    func testDecodeAutumnJSON() throws {
        let json = """
        {"name":"autumn","glyphType":"image","spriteSet":"leaves","spriteCount":5,
         "count":600,"sizeMin":12,"sizeMax":26,"vyMin":25,"vyMax":55,"vxMin":0,"vxMax":0,
         "swayAmp":32,"swayPeriodMin":4,"swayPeriodMax":8,
         "rotate":true,"rotateSpeed":0.7,"tumble":true,"tumbleSpeed":0.9,
         "glow":false,"pulse":false,"spriteOpacity":0.6,
         "color":{"L":0.72,"C":0.14,"H":50,"alpha":0.7},
         "tint":{"L":0.25,"C":0.04,"H":50,"alpha":0.15},
         "depthMin":0.6,"depthMax":1.0,
         "bloomThreshold":1.0,"bloomIntensity":0.4,"dofStrength":0.3,"edrHeadroom":1.0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertEqual(s.name, "autumn")
        XCTAssertEqual(s.glyphType, .image)
        XCTAssertEqual(s.spriteSet, "leaves")
        XCTAssertEqual(s.count, 600)
        XCTAssertTrue(s.tumble)
        XCTAssertEqual(s.colorP3.w, 0.7, accuracy: 0.001)   // alpha preserved
        XCTAssertGreaterThan(s.colorP3.x, s.colorP3.z)       // warm: R>B
    }

    func testGlowSeasonHasNoSpriteSet() throws {
        let json = """
        {"name":"summer","glyphType":"glow","spriteCount":0,
         "count":400,"sizeMin":1.4,"sizeMax":2.6,"vyMin":-15,"vyMax":15,"vxMin":-15,"vxMax":15,
         "swayAmp":18,"swayPeriodMin":3,"swayPeriodMax":6,
         "rotate":false,"rotateSpeed":0,"tumble":false,"tumbleSpeed":0,
         "glow":true,"pulse":true,"spriteOpacity":1.0,
         "color":{"L":0.88,"C":0.16,"H":95,"alpha":0.65},
         "tint":{"L":0.25,"C":0.04,"H":95,"alpha":0.15},
         "depthMin":0.6,"depthMax":1.0,
         "bloomThreshold":0.8,"bloomIntensity":0.9,"dofStrength":0.2,"edrHeadroom":2.0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertEqual(s.glyphType, .glow)
        XCTAssertNil(s.spriteSet)
        XCTAssertTrue(s.glow)
    }

    func testLightGradeBlocksAbsentDecodeNil() throws {
        let json = """
        {"name":"x","glyphType":"glow","spriteCount":0,"count":1,"sizeMin":1,"sizeMax":2,
         "vyMin":0,"vyMax":1,"vxMin":0,"vxMax":0,"swayAmp":0,"swayPeriodMin":1,"swayPeriodMax":2,
         "rotate":false,"rotateSpeed":0,"tumble":false,"tumbleSpeed":0,"glow":true,"pulse":false,
         "spriteOpacity":1,"color":{"L":0.5,"C":0,"H":0,"alpha":1},"tint":{"L":0.5,"C":0,"H":0,"alpha":1},
         "depthMin":0.6,"depthMax":1,"bloomThreshold":1,"bloomIntensity":0,"dofStrength":0,"edrHeadroom":1}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertNil(s.light)
        XCTAssertNil(s.grade)
    }

    func testLightGradeBlocksDecodePartially() throws {
        let json = """
        {"name":"x","glyphType":"glow","spriteCount":0,"count":1,"sizeMin":1,"sizeMax":2,
         "vyMin":0,"vyMax":1,"vxMin":0,"vxMax":0,"swayAmp":0,"swayPeriodMin":1,"swayPeriodMax":2,
         "rotate":false,"rotateSpeed":0,"tumble":false,"tumbleSpeed":0,"glow":true,"pulse":false,
         "spriteOpacity":1,"color":{"L":0.5,"C":0,"H":0,"alpha":1},"tint":{"L":0.5,"C":0,"H":0,"alpha":1},
         "depthMin":0.6,"depthMax":1,"bloomThreshold":1,"bloomIntensity":0,"dofStrength":0,"edrHeadroom":1,
         "light":{"rimIntensity":0.7,"keyDir":[0,1,0]},
         "grade":{"exposure":1.4,"bloomMix":[0.6,0.25,0.15],
                  "highlightTint":{"L":0.95,"C":0.03,"H":80,"alpha":1}}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertEqual(s.light?.rimIntensity, 0.7)
        XCTAssertEqual(s.light?.keyDir, [0, 1, 0])
        XCTAssertNil(s.light?.keyIntensity)              // absent field stays nil
        XCTAssertEqual(s.grade?.exposure, 1.4)
        XCTAssertEqual(s.grade?.bloomMix, [0.6, 0.25, 0.15])
        XCTAssertNotNil(s.grade?.highlightTintP3)
        XCTAssertNil(s.grade?.vignette)
    }

    func testMotionModelDecodesWithGenericDefault() throws {
        let base = """
        {"name":"x","glyphType":"glow","spriteCount":0,"count":1,"sizeMin":1,"sizeMax":2,
         "vyMin":0,"vyMax":1,"vxMin":0,"vxMax":0,"swayAmp":0,"swayPeriodMin":1,"swayPeriodMax":2,
         "rotate":false,"rotateSpeed":0,"tumble":false,"tumbleSpeed":0,"glow":true,"pulse":false,
         "spriteOpacity":1,"color":{"L":0.5,"C":0,"H":0,"alpha":1},"tint":{"L":0.5,"C":0,"H":0,"alpha":1},
         "depthMin":0.6,"depthMax":1,"bloomThreshold":1,"bloomIntensity":0,"dofStrength":0,"edrHeadroom":1
        """
        let plain = try JSONDecoder().decode(Season.self, from: (base + "}").data(using: .utf8)!)
        XCTAssertEqual(plain.motionModel, .generic)
        XCTAssertEqual(plain.aeroResolved.flutterAmp, 0.55, accuracy: 0.001)

        let leaf = try JSONDecoder().decode(Season.self, from:
            (base + #","motionModel":"leaf","aero":{"tumbleChance":0.3,"flashInterval":[2,4]}}"#).data(using: .utf8)!)
        XCTAssertEqual(leaf.motionModel, .leaf)
        XCTAssertEqual(leaf.motionModel.raw, 1)
        XCTAssertEqual(leaf.aeroResolved.tumbleChance, 0.3)
        XCTAssertEqual(leaf.aeroResolved.flashIntervalMin, 2)
        XCTAssertEqual(leaf.aeroResolved.flutterFreq, 0.55, accuracy: 0.001)  // default kept
    }

    func testSelectionRoundTrips() {
        XCTAssertEqual(SeasonSelection(storage: "auto"), .auto)
        XCTAssertEqual(SeasonSelection(storage: "off"), .off)
        XCTAssertEqual(SeasonSelection(storage: "winter"), .fixed(.winter))
        XCTAssertEqual(SeasonSelection.auto.storage, "auto")
        XCTAssertEqual(SeasonSelection.fixed(.summer).storage, "summer")
        XCTAssertEqual(SeasonSelection(storage: "garbage"), .auto)  // safe default
    }
}
