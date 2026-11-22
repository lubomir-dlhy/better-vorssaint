// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import os

/// The complete production hardware class is generated inside this namespace.
/// Only SMC transport, sensor discovery and elapsed time are replaced; no test
/// opens AppleSMC or changes the machine's fan modes.
enum FanControlHardwareContract {
    static let fanControlHardwareLog = Logger(subsystem: "com.vorssaint.tests", category: "FanControlHardware")

    enum ProcessInfo {
        static let processInfo = Clock()
        final class Clock { var systemUptime: TimeInterval = 100 }
    }

    enum Thread {
        static var waits: [TimeInterval] = []
        static func sleep(forTimeInterval interval: TimeInterval) {
            waits.append(interval)
            ProcessInfo.processInfo.systemUptime += interval
        }
    }

    enum TemperatureSensorSelector {
        static let minimumChipTemperature = 10.0
        static var modelIdentifier: String? { SMCClient.current.modelIdentifier }
        static func currentPlatform() -> CPUTemperaturePlatform { .generic }
        static func isCPUTemperatureKey(_ name: String, platform: CPUTemperaturePlatform) -> Bool {
            name.hasPrefix("TC")
        }
    }

    struct Write {
        let key: String
        let value: Double
    }

    final class State {
        var modelIdentifier: String?
        var values: [String: Double] = ["FNum": 2]
        var bytes: [String: [UInt8]] = [:]
        var writes: [Write] = []
        var reads: [String: Int] = [:]
        var rejectWrite: ((Write) -> Bool)?
        var failAfterApplying: ((Write) -> Bool)?
        var readValue: ((String, Int, Double?) -> Double?)?

        init() {
            for index in 0..<2 {
                values["F\(index)Ac"] = 2_000
                values["F\(index)Mn"] = 1_200
                values["F\(index)Mx"] = 5_800
                values["F\(index)Tg"] = 0
                bytes["F\(index)md"] = [0]
            }
        }

        var automatic: Bool { (0..<2).allSatisfy { bytes["F\($0)md"] == [0] } }
    }

    final class SMCClient {
        enum Failure: Error { case write }
        struct Key {
            let name: String
            let dataSize: UInt32
            let dataType: String
        }
        static var current = State()
        let state: State
        init?() { state = Self.current }

        func key(named name: String) -> Key? {
            if state.bytes[name] != nil { return Key(name: name, dataSize: 1, dataType: "ui8 ") }
            if state.values[name] != nil { return Key(name: name, dataSize: 4, dataType: "flt ") }
            return nil
        }
        func keys(where filter: (String) -> Bool) -> [Key] {
            state.values.keys.filter(filter).sorted().compactMap { key(named: $0) }
        }
        func readValue(_ key: Key) -> Double? {
            state.reads[key.name, default: 0] += 1
            if let readValue = state.readValue {
                return readValue(key.name, state.reads[key.name]!, state.values[key.name])
            }
            return state.values[key.name]
        }
        func readBytes(_ key: Key) -> [UInt8]? { state.bytes[key.name] }
        func writeValue(_ value: Double, to key: Key) throws {
            let write = Write(key: key.name, value: value)
            try record(write)
            state.values[key.name] = value
            if state.failAfterApplying?(write) == true { throw Failure.write }
        }
        func writeBytes(_ bytes: [UInt8], to key: Key) throws {
            let write = Write(key: key.name, value: Double(bytes[0]))
            try record(write)
            state.bytes[key.name] = bytes
            if state.failAfterApplying?(write) == true { throw Failure.write }
        }
        private func record(_ write: Write) throws {
            state.writes.append(write)
            if state.rejectWrite?(write) == true { throw Failure.write }
        }
    }

    private static func fresh() -> (FanControlHardware, State) {
        SMCClient.current = State()
        Thread.waits = []
        ProcessInfo.processInfo.systemUptime = 100
        return (FanControlHardware()!, SMCClient.current)
    }

    private static func request(_ hardware: FanControlHardware, level: Int) -> FanControlCoolingRequest? {
        (try? hardware.coolingRequest(for: .manual(level: level))) ?? nil
    }

    private static func start(_ hardware: FanControlHardware, level: Int) throws -> [FanControlFanReading] {
        guard let request = request(hardware, level: level) else {
            throw FanControlHardwareError.operationFailed
        }
        return try hardware.startCooling(request)
    }

    private static func update(_ hardware: FanControlHardware, level: Int) throws -> [FanControlFanReading] {
        guard let request = request(hardware, level: level) else {
            throw FanControlHardwareError.operationFailed
        }
        return try hardware.updateCooling(request)
    }

    private static func operationFails(_ operation: () throws -> [FanControlFanReading]) -> Bool {
        do {
            _ = try operation()
            return false
        } catch FanControlHardwareError.operationFailed {
            return true
        } catch {
            return false
        }
    }

    static func run(_ suite: TestSuite) {
        let (healthy, healthyState) = fresh()
        let started = try? start(healthy, level: 50)
        suite.expect(started?.count == 2 && started?.allSatisfy(\.isManuallyControlled) == true
                        && healthyState.values["F0Tg"] == 3_500
                        && healthyState.values["F1Tg"] == 3_500 && healthy.coolingIsIntact()
                        && healthy.activeCoolingTargets == [3_500, 3_500],
                     "direct manual control writes and verifies the requested target on both fans")
        let firstTarget = healthyState.writes.firstIndex { $0.key.hasSuffix("Tg") } ?? -1
        let lastModeWrite = healthyState.writes.lastIndex { $0.key.hasSuffix("md") && $0.value == 1 } ?? .max
        suite.expect(lastModeWrite < firstTarget,
                     "manual mode is engaged and verified on every fan before any target is written")
        let updated = try? update(healthy, level: 80)
        suite.expect(updated?.count == 2 && healthyState.values["F0Tg"] == 4_880
                        && healthyState.values["F1Tg"] == 4_880 && healthy.coolingIsIntact(),
                     "an active cooling update preserves manual mode at the new targets")
        suite.expect(healthy.restoreAutomatic() && healthyState.automatic
                        && !healthy.coolingIsIntact() && healthy.activeCoolingTargets.isEmpty,
                     "successful restoration returns every fan to firmware and forgets active targets")

        let (tolerant, tolerantState) = fresh()
        tolerantState.failAfterApplying = { $0.key.hasSuffix("Tg") || $0.key.hasSuffix("md") }
        suite.expect((try? start(tolerant, level: 50))?.count == 2
                        && tolerantState.values["F0Tg"] == 3_500 && tolerant.coolingIsIntact(),
                     "an SMC write that reports an error after applying its value is accepted by readback")

        for index in 0..<2 {
            let (starting, startingState) = fresh()
            startingState.rejectWrite = { $0.key == "F\(index)Tg" }
            suite.expect(operationFails { try start(starting, level: 50) }
                            && !startingState.writes.contains { $0.key.hasSuffix("Tg") && $0.value == 0 },
                         "a target that never reads back on fan \(index) fails the start for the helper to restore")

            let (hardware, state) = fresh()
            suite.expect((try? start(hardware, level: 50)) != nil,
                         "the write-failure fixture starts a real manual session")
            state.rejectWrite = { $0.key == "F\(index)Tg" }
            suite.expect(operationFails { try update(hardware, level: 75) }
                            && hardware.activeCoolingTargets == [3_500, 3_500],
                         "a failed update on fan \(index) keeps the last verified targets for the watchdog")
        }

        let (unverified, unverifiedState) = fresh()
        suite.expect((try? start(unverified, level: 50)) != nil,
                     "the stale-mode fixture starts manual control")
        unverifiedState.bytes["F1md"] = [0]
        suite.expect(operationFails { try update(unverified, level: 75) }
                        && !unverifiedState.writes.contains { $0.key.hasSuffix("Tg") && $0.value == 4_650 },
                     "an update refuses to write targets once a fan has left manual mode")

        let (outOfBounds, outOfBoundsState) = fresh()
        suite.expect(operationFails {
                        try outOfBounds.startCooling(.init(level: 50, targets: [3_500, 9_000]))
                     }
                        && outOfBoundsState.writes.isEmpty,
                     "a target outside the reported fan bounds cannot begin a manual write")

        let (noForceTest, noForceTestState) = fresh()
        noForceTestState.rejectWrite = { $0.key.hasSuffix("md") && $0.value == 1 }
        suite.expect(operationFails { try start(noForceTest, level: 50) }
                        && !noForceTestState.writes.contains { $0.key.hasSuffix("Tg") },
                     "rejected manual mode without Ftst fails closed before any target write")

        let (forced, forcedState) = fresh()
        forcedState.bytes["Ftst"] = [0]
        forcedState.rejectWrite = { [unowned forcedState] in
            $0.key.hasSuffix("md") && $0.value == 1 && forcedState.bytes["Ftst"] != [1]
        }
        suite.expect((try? start(forced, level: 50))?.count == 2
                        && forcedState.bytes["Ftst"] == [1]
                        && forcedState.values["F0Tg"] == 3_500 && forcedState.values["F1Tg"] == 3_500
                        && Thread.waits.contains(3)
                        && !forcedState.writes.contains { $0.key.hasSuffix("Tg") && $0.value == 5_800 },
                     "Ftst unlocks manual mode after a settling wait, then writes only the requested target")
        forcedState.rejectWrite = nil
        suite.expect(forced.restoreAutomatic() && forcedState.automatic && forcedState.bytes["Ftst"] == [0],
                     "Ftst restoration clears automatic mode and the force-test flag")

        let (forcedFailure, forcedFailureState) = fresh()
        forcedFailureState.bytes["Ftst"] = [0]
        forcedFailureState.rejectWrite = { $0.value == 1 }
        suite.expect(operationFails { try start(forcedFailure, level: 50) }
                        && forcedFailureState.bytes["Ftst"] == [0]
                        && !forcedFailureState.writes.contains { $0.key.hasSuffix("Tg") },
                     "a present force-test key that rejects activation fails closed")

        let (recovering, recoveryState) = fresh()
        suite.expect((try? start(recovering, level: 50)) != nil,
                     "the restoration-failure fixture starts manual control")
        recoveryState.rejectWrite = { $0.key == "F0md" && $0.value == 0 }
        suite.expect(!recovering.restoreAutomatic()
                        && recoveryState.bytes["F0md"] == [1] && recoveryState.bytes["F1md"] == [0],
                     "a failed restore is reported and still attempts the other fan")
        suite.expect(recoveryState.values["F0Tg"] == 3_500
                        && !recoveryState.writes.contains { $0.key == "F0Tg" && $0.value == 0 },
                     "a fan that rejects automatic mode keeps its safe target instead of receiving zero RPM")
        recoveryState.rejectWrite = nil
        suite.expect(recovering.restoreAutomatic() && recoveryState.automatic,
                     "a later restoration attempt recovers the fan left in manual mode")

        let (firmware, firmwareState) = fresh()
        suite.expect((try? start(firmware, level: 50)) != nil,
                     "the firmware-mode fixture starts manual control")
        firmwareState.bytes["F0md"] = [3]
        firmwareState.bytes["F1md"] = [3]
        firmwareState.rejectWrite = { $0.key.hasSuffix("md") && $0.value == 0 }
        suite.expect(firmware.restoreAutomatic() && firmwareState.bytes["F0md"] == [3]
                        && firmwareState.bytes["F1md"] == [3]
                        && firmwareState.values["F0Tg"] == 3_500 && firmwareState.values["F1Tg"] == 3_500,
                     "firmware mode three is accepted as automatic even when it rejects mode zero")

        let (unreadable, unreadableState) = fresh()
        suite.expect((try? start(unreadable, level: 50)) != nil,
                     "the unreadable-mode fixture starts manual control")
        unreadableState.bytes.removeValue(forKey: "F0md")
        unreadableState.rejectWrite = { $0.key == "F0md" }
        suite.expect(!unreadable.restoreAutomatic() && unreadableState.bytes["F1md"] == [0]
                        && unreadableState.values["F0Tg"] == 3_500,
                     "an unreadable mode preserves the last target and does not block recovery of the other fan")

        let (stuckForceTest, stuckForceState) = fresh()
        stuckForceState.bytes["Ftst"] = [0]
        suite.expect((try? start(stuckForceTest, level: 50)) != nil,
                     "the stuck force-test fixture starts manual control")
        stuckForceState.bytes["Ftst"] = [1]
        stuckForceState.rejectWrite = { $0.key == "Ftst" && $0.value == 0 }
        suite.expect(!stuckForceTest.restoreAutomatic() && stuckForceState.automatic
                        && stuckForceState.bytes["Ftst"] == [1]
                        && stuckForceState.values["F0Tg"] == 3_500 && stuckForceState.values["F1Tg"] == 3_500,
                     "a force-test flag that rejects automatic mode preserves targets and leaves recovery pending")
        stuckForceState.rejectWrite = nil
        suite.expect(stuckForceTest.restoreAutomatic() && stuckForceState.bytes["Ftst"] == [0],
                     "a later retry clears the force-test flag before reporting automatic recovery")

        for forceTest in [false, true] {
            let (owned, ownedState) = fresh()
            if forceTest { ownedState.bytes["Ftst"] = [1] }
            else { ownedState.bytes["F0md"] = [1] }
            var alreadyControlled = false
            do { _ = try start(owned, level: 50) }
            catch FanControlHardwareError.alreadyControlled { alreadyControlled = true }
            catch {}
            suite.expect(alreadyControlled && ownedState.writes.isEmpty,
                         "preexisting control is rejected without writing or restoring another owner's fans")
        }

        for value in [Double.nan, Double.infinity, -Double.infinity] {
            for key in ["F0Mn", "F1Mx"] {
                let (invalid, invalidState) = fresh()
                invalidState.values[key] = value
                suite.expect(request(invalid, level: 50) == nil
                                && (try? invalid.startCooling(.init(level: 50, targets: [3_500, 3_500]))) == nil
                                && invalidState.writes.isEmpty && invalidState.automatic,
                             "non-finite \(key) is rejected before any manual-mode or target write")
            }
        }
        let (invalidLevel, invalidLevelState) = fresh()
        suite.expect(operationFails {
                        try invalidLevel.startCooling(.init(level: 101, targets: [3_500, 3_500]))
                     }
                        && invalidLevelState.writes.isEmpty,
                     "an invalid cooling level cannot begin a manual write")

        let (sensing, sensingState) = fresh()
        sensingState.modelIdentifier = "MacBookPro18,3"
        sensingState.values["TC0P"] = 45
        sensingState.values["Tg04"] = 0
        sensingState.values["Tg05"] = 9.2
        sensingState.values["Tg0C"] = 0
        sensingState.values["Tg0D"] = 9.2
        let sleeping = try? sensing.readOnlySnapshot()
        suite.expect(sleeping?.gpuPoweredDown == true
                        && sleeping?.temperatures?.contains { $0.source == .hottestGPU } == false
                        && sleeping?.temperatures?.first { $0.source == .hottestSoC }?.celsius == 45,
                     "a sleeping M1 Pro GPU remains distinct from measured GPU and SoC temperatures")
        sensingState.readValue = { key, _, value in key == "Tg05" ? nil : value }
        let failedReading = sensing.readTemperatures()
        suite.expect(!failedReading.gpuPoweredDown
                        && !failedReading.readings.contains { $0.source == .hottestGPU },
                     "a GPU sensor that fails to answer still leaves the GPU source unavailable")
        sensingState.readValue = nil
        sensingState.values["Tg05"] = 52
        let awake = try? sensing.snapshot(isCooling: true, endsAt: nil, stopReason: nil)
        suite.expect(awake?.gpuPoweredDown == false
                        && awake?.temperatures?.first { $0.source == .hottestGPU }?.celsius == 52,
                     "an active session reports the new GPU measurement as soon as the GPU wakes")

        let (alternateM1, alternateState) = fresh()
        alternateState.modelIdentifier = "MacBookPro17,1"
        alternateState.values["Tg1b"] = 0
        alternateState.values["Tg4b"] = 0
        let unavailable = alternateM1.readTemperatures()
        let gpuCurve = FanControlCurve(sensor: .hottestGPU, points: FanControlConfiguration.defaultCurve.points)
        suite.expect(!unavailable.gpuPoweredDown
                        && FanControlPolicy.curveCoolingLevel(curves: [gpuCurve], temperatures: unavailable.readings,
                                                             gpuPoweredDown: unavailable.gpuPoweredDown) == nil,
                     "zero readings on the alternate M1 layout cannot start or sustain a GPU-only curve")

        let (idleGPU, idleGPUState) = fresh()
        idleGPUState.modelIdentifier = "MacBookPro18,3"
        idleGPUState.values["TC0P"] = 45
        idleGPUState.values["Tg04"] = 0
        idleGPUState.values["Tg05"] = 9.2
        idleGPUState.values["Tg0C"] = 0
        idleGPUState.values["Tg0D"] = 9.2
        let idleRequest = try? idleGPU.coolingRequest(for: .curve([gpuCurve]))
        suite.expect(idleRequest?.level == gpuCurve.points[0].coolingLevel
                        && idleRequest?.targets == [1_200, 1_200],
                     "a sleeping M1 Pro GPU drives a GPU sensor curve to the fans' minimum")
        idleGPUState.readValue = { key, _, value in key == "Tg05" ? nil : value }
        let missingGPURequest: FanControlCoolingRequest?? = { do { return .some(try idleGPU.coolingRequest(for: .curve([gpuCurve]))) } catch { return nil } }()
        suite.expect(missingGPURequest == .some(nil),
                     "a GPU key that fails to answer cannot produce a sensor-based GPU request")
    }
}
