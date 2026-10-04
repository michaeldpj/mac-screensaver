import XCTest

final class SeasonCatalogTests: XCTestCase {
    func testSeasonByMonthMatchesWebEngine() {
        // web: Dec/Jan/Feb winter, Mar-May spring, Jun-Aug summer, else autumn (months 0-indexed)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(11), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(0), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(1), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(3), .spring)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(6), .summer)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(9), .autumn)
    }

    func testResolveOverride() {
        XCTAssertEqual(SeasonCatalog.resolve(.fixed(.winter), month: 6), .winter)
        XCTAssertEqual(SeasonCatalog.resolve(.auto, month: 6), .summer)
    }

    func testResolveOffReturnsNil() {
        XCTAssertNil(SeasonCatalog.resolveActive(.off, month: 6))
    }
}
