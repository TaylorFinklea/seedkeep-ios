import Foundation
import os
@testable import Seedkeep

/// Test double for `PlantingEventQuery`. Returns whatever count the test
/// configures. Used to drive the `.noActivePlantings` early-return path in
/// `WeatherWarningsService` without spinning up SwiftData.
final class StubPlantingEventQuery: PlantingEventQuery, @unchecked Sendable {

    private let state: OSAllocatedUnfairLock<Int>

    init(activeCount: Int = 1) {
        self.state = OSAllocatedUnfairLock(initialState: activeCount)
    }

    func setActiveCount(_ count: Int) {
        state.withLock { $0 = count }
    }

    func activeCount() async -> Int {
        state.withLock { $0 }
    }
}
