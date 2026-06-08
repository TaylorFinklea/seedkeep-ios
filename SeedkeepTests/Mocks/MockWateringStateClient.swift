import Foundation
import os
@testable import Seedkeep

/// Test double for `WateringStateClient`. Records every `get` / `put` call
/// and returns whatever the test configured. Lets `WeatherWarningsService`
/// integration tests drive the server-coordinated watering ledger without
/// running a real `SeedkeepClient`.
final class MockWateringStateClient: WateringStateClient, @unchecked Sendable {

    struct PutCall: @unchecked Sendable, Equatable {
        let householdID: String
        let scheduledFor: Date
    }

    private struct State {
        var getResult: Result<Date?, any Error> = .success(nil)
        var putResult: Result<Date?, any Error> = .success(nil)
        var recordedGets: [String] = []
        var recordedPuts: [PutCall] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Configuration

    func setGetResult(_ result: Result<Date?, any Error>) {
        state.withLock { $0.getResult = result }
    }

    func setPutResult(_ result: Result<Date?, any Error>) {
        state.withLock { $0.putResult = result }
    }

    // MARK: - Recorders

    var recordedGets: [String] {
        state.withLock { $0.recordedGets }
    }

    var recordedPuts: [PutCall] {
        state.withLock { $0.recordedPuts }
    }

    // MARK: - WateringStateClient

    func get(householdID: String) async -> Result<Date?, any Error> {
        state.withLock { s in
            s.recordedGets.append(householdID)
            return s.getResult
        }
    }

    func put(
        householdID: String,
        scheduledFor: Date
    ) async -> Result<Date?, any Error> {
        state.withLock { s in
            s.recordedPuts.append(PutCall(
                householdID: householdID,
                scheduledFor: scheduledFor
            ))
            return s.putResult
        }
    }
}
