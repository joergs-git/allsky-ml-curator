import XCTest
@testable import AllskyMLCurator

/// Placeholder test target. The real test matrix grows with each phase:
///
/// - Phase 1: EphemerisTests (sun/moon alt/az/phase accuracy)
/// - Phase 2: SkyDiskMaskTests (embedding stability under overlay),
///   EmbeddingPipelineTests (throughput)
/// - Phase 4: ClassifierEngineTests (retrain latency, clear-sky boost)
/// - Phase 5: AutonomousRaterTests (confirmation-bias bounds)
final class AllskyMLCuratorTests: XCTestCase {

    func testBundleLoads() {
        // Sanity check that the test host bundle links against the app.
        XCTAssertNotNil(AppSettings.shared)
    }
}
