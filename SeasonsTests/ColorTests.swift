import XCTest
import simd

final class ColorTests: XCTestCase {
    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 0.01,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: tol, file: file, line: line)
    }

    func testWhiteIsUnityInLinearP3() {
        // OKLCH L=1, C=0 is reference white → linear P3 (1,1,1)
        assertClose(oklchToLinearP3(L: 1.0, C: 0.0, H: 0.0), SIMD3(1, 1, 1))
    }

    func testBlackIsZero() {
        assertClose(oklchToLinearP3(L: 0.0, C: 0.0, H: 0.0), SIMD3(0, 0, 0))
    }

    func testMidGrayIsAchromatic() {
        let c = oklchToLinearP3(L: 0.5, C: 0.0, H: 0.0)
        XCTAssertEqual(c.x, c.y, accuracy: 0.001)
        XCTAssertEqual(c.y, c.z, accuracy: 0.001)
        XCTAssertGreaterThan(c.x, 0.0)
        XCTAssertLessThan(c.x, 1.0)
    }

    func testWarmAmberIsReddish() {
        // summer firefly base oklch(88% 0.16 95) → warm, R > B
        let c = oklchToLinearP3(L: 0.88, C: 0.16, H: 95)
        XCTAssertGreaterThan(c.x, c.z)
    }
}
