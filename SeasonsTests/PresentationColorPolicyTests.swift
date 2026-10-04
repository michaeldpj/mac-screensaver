import XCTest
import simd

final class PresentationColorPolicyTests: XCTestCase {
    func testUltraLiteAlwaysUsesSRGBEncodedBGRA8DisplayP3AndDisablesEDR() {
        let ordinary = PresentationColorPolicy.plan(ultraLite: true, edrRequested: false)
        let attemptedEDR = PresentationColorPolicy.plan(ultraLite: true, edrRequested: true)

        for plan in [ordinary, attemptedEDR] {
            XCTAssertEqual(plan.pixelEncoding, .bgra8UnormSRGB)
            XCTAssertEqual(plan.colorSpace, .displayP3)
            XCTAssertFalse(plan.extendedDynamicRange)
        }
    }

    func testStandardSDRRetainsTenBitXRPresentation() {
        let plan = PresentationColorPolicy.plan(ultraLite: false, edrRequested: false)

        XCTAssertEqual(plan.pixelEncoding, .bgra10XRSRGB)
        XCTAssertEqual(plan.colorSpace, .displayP3)
        XCTAssertFalse(plan.extendedDynamicRange)
    }

    func testEDRIsIsolatedToExplicitStandardPresentation() {
        let plan = PresentationColorPolicy.plan(ultraLite: false, edrRequested: true)

        XCTAssertEqual(plan.pixelEncoding, .rgba16Float)
        XCTAssertEqual(plan.colorSpace, .extendedLinearDisplayP3)
        XCTAssertTrue(plan.extendedDynamicRange)
    }

    func testSRGBTransferMatchesReferenceValues() {
        XCTAssertEqual(SDRColorMath.srgbEncode(0), 0, accuracy: 1e-7)
        XCTAssertEqual(SDRColorMath.srgbEncode(0.0031308), 0.040449936, accuracy: 1e-6)
        XCTAssertEqual(SDRColorMath.srgbEncode(0.5), 0.73535698, accuracy: 1e-6)
        XCTAssertEqual(SDRColorMath.srgbEncode(1), 1, accuracy: 1e-7)

        XCTAssertEqual(SDRColorMath.srgbDecode(0), 0, accuracy: 1e-7)
        XCTAssertEqual(SDRColorMath.srgbDecode(0.04045), 0.0031308, accuracy: 1e-6)
        XCTAssertEqual(SDRColorMath.srgbDecode(0.5), 0.21404114, accuracy: 1e-6)
        XCTAssertEqual(SDRColorMath.srgbDecode(1), 1, accuracy: 1e-7)
    }

    func testSRGBTransferRoundTripsRepresentativeValues() {
        for value: Float in [0, 0.001, 0.02, 0.18, 0.5, 0.9, 1] {
            let roundTrip = SDRColorMath.srgbDecode(SDRColorMath.srgbEncode(value))
            XCTAssertEqual(roundTrip, value, accuracy: 2e-6)
        }
    }

    func testLinearSRGBToLinearP3MatchesReferencePrimaries() {
        let red = SDRColorMath.linearSRGBToLinearP3(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(red.x, 0.82246197, accuracy: 1e-6)
        XCTAssertEqual(red.y, 0.03319420, accuracy: 1e-6)
        XCTAssertEqual(red.z, 0.01708263, accuracy: 1e-6)

        let blue = SDRColorMath.linearSRGBToLinearP3(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(blue.x, 0, accuracy: 1e-6)
        XCTAssertEqual(blue.y, 0, accuracy: 1e-6)
        XCTAssertEqual(blue.z, 0.91051993, accuracy: 1e-6)
    }

    func testLinearSRGBToLinearP3PreservesNeutralAxis() {
        for value: Float in [0, 0.18, 0.5, 1] {
            let converted = SDRColorMath.linearSRGBToLinearP3(SIMD3<Float>(repeating: value))
            XCTAssertEqual(converted.x, value, accuracy: 1e-6)
            XCTAssertEqual(converted.y, value, accuracy: 1e-6)
            XCTAssertEqual(converted.z, value, accuracy: 1e-6)
        }
    }

    func testVividProfileRaisesImageOpacityButDoesNotRewriteProceduralOpacity() {
        let profile = VividSDRProfile.standard

        XCTAssertGreaterThan(profile.effectiveOpacity(configured: 0.6, isImage: true), 0.6)
        XCTAssertEqual(profile.effectiveOpacity(configured: 0.6, isImage: true),
                       profile.imageOpacity, accuracy: 1e-6)
        XCTAssertEqual(profile.effectiveOpacity(configured: 0.6, isImage: false), 0.6,
                       accuracy: 1e-6)
    }

    func testVividProfileIsImageOnly() {
        let profile = VividSDRProfile.standard
        let source = SIMD3<Float>(0.28, 0.08, 0.025)

        let vivid = profile.apply(to: source, isImage: true)
        let procedural = profile.apply(to: source, isImage: false)

        XCTAssertEqual(procedural, source)
        XCTAssertGreaterThan(vivid.maxComponent - vivid.minComponent,
                             source.maxComponent - source.minComponent)
        XCTAssertGreaterThan(vivid.maxComponent, source.maxComponent)
    }

    func testVividProfileProducesFiniteBoundedSDRColorForExtremeInput() {
        let profile = VividSDRProfile.standard
        let inputs = [
            SIMD3<Float>(2.0, -1.0, 0.5),
            SIMD3<Float>(10_000, 0.0001, -10_000),
            SIMD3<Float>(Float.infinity, Float.nan, -Float.infinity)
        ]

        for input in inputs {
            let output = profile.apply(to: input, isImage: true)
            for component in [output.x, output.y, output.z] {
                XCTAssertTrue(component.isFinite)
                XCTAssertGreaterThanOrEqual(component, 0)
                XCTAssertLessThanOrEqual(component, 1)
            }
        }
    }

    func testVividProfilePreservesExactBlack() {
        XCTAssertEqual(VividSDRProfile.standard.apply(to: .zero, isImage: true), .zero)
        XCTAssertEqual(SDRColorMath.linearSRGBToLinearP3(.zero), .zero)
        XCTAssertEqual(SDRColorMath.srgbEncode(0), 0)
    }
}

private extension SIMD3 where Scalar == Float {
    var maxComponent: Float { Swift.max(x, Swift.max(y, z)) }
    var minComponent: Float { Swift.min(x, Swift.min(y, z)) }
}
