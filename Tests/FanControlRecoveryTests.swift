// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Runs the helper's production watchdog and recovery methods against doubles.
/// It exercises session transitions without opening SMC or starting a timer.
enum FanControlRecoveryContract {
    enum ProcessInfo {
        static let processInfo = Clock()
        struct Clock {
            let systemUptime: TimeInterval = 100
            let thermalState: Foundation.ProcessInfo.ThermalState = .nominal
        }
    }

    final class FanControlHardware {
        enum Failure: Error { case write }
        var failUpdate = false
        var restoreResults = [true]
        var updates: [Int] = []
        var restores = 0
        var checks = 0
        var isManual = true
        var controlIntact = true
        var request: FanControlCoolingRequest? = .init(level: 50, targets: [3_500, 3_500])
        private(set) var activeCoolingTargets: [Double] = []

        func coolingRequest(for configuration: FanControlConfiguration) throws -> FanControlCoolingRequest? {
            request
        }

        func updateCooling(_ request: FanControlCoolingRequest) throws -> [FanControlFanReading] {
            updates.append(request.level)
            if failUpdate { throw Failure.write }
            activeCoolingTargets = request.targets
            isManual = true
            return []
        }

        func restoreAutomatic() -> Bool {
            restores += 1
            let succeeded = restoreResults.count > 1 ? restoreResults.removeFirst() : restoreResults[0]
            if succeeded {
                isManual = false
                activeCoolingTargets = []
            }
            return succeeded
        }

        func coolingIsIntact() -> Bool {
            checks += 1
            return controlIntact
        }
    }

    final class Ownership {
        var isHeld = true
        var marker = true
        var canRemoveMarker = true
        func acquire() -> Bool { isHeld = true; return true }
        func markerExists() -> Bool { marker }
        func removeMarker() -> Bool {
            if canRemoveMarker { marker = false }
            return canRemoveMarker
        }
        func release() { isHeld = false }
    }

    final class Timer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    /// Accepts the helper's `Logger` interpolations, privacy included, and
    /// keeps the rendered text so a test can read why a session ended.
    struct LogMessage: ExpressibleByStringInterpolation {
        enum Privacy { case `public`, `private` }
        struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ literal: String) { text += literal }
            mutating func appendInterpolation<Value>(_ value: Value, privacy: Privacy = .private) {
                text += "\(value)"
            }
        }
        let text: String
        init(stringLiteral value: String) { text = value }
        init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    }

    final class Log {
        var notices: [String] = []
        var errors: [String] = []
        func info(_ message: LogMessage) {}
        func notice(_ message: LogMessage) { notices.append(message.text) }
        func error(_ message: LogMessage) { errors.append(message.text) }
    }

    class Fixture {
        let log = Log()
        let ownership = Ownership()
        var hardware: FanControlHardware? = FanControlHardware()
        var owner: UUID? = UUID()
        var isCooling = true
        var isRecovering = false
        var endsAt: Date?
        var endsAtUptime: TimeInterval?
        var lastHeartbeatUptime: TimeInterval = 100
        var verificationFailures = 0
        var temperatureFailures = 0
        var lastStopReason: FanControlStopReason?
        var coolingLevel: Int? = 0
        var activeConfiguration: FanControlConfiguration? = .curve([FanControlConfiguration.defaultCurve])
        var timer: Timer? = Timer()
        var exitChecks = 0
        func startWatchdog() {
            if timer == nil { timer = Timer() }
        }
        func scheduleExitIfIdle() { exitChecks += 1 }
    }

    static func run(_ suite: TestSuite) {
        let healthy = Controller()
        let healthyOwner = healthy.owner
        healthy.watchdogTick()
        suite.expect(healthy.hardware?.updates == [50] && healthy.coolingLevel == 50
                        && healthy.isCooling && !healthy.isRecovering
                        && healthy.owner == healthyOwner && healthy.ownership.marker
                        && healthy.hardware?.restores == 0 && healthy.timer != nil,
                     "a successful sensor write keeps the active session and ownership")
        healthy.watchdogTick()
        suite.expect(healthy.hardware?.updates == [50] && healthy.hardware?.checks == 1,
                     "unchanged sensor targets verify control without rewriting the fans")
        healthy.hardware?.request = .init(level: 50, targets: [3_600, 3_600])
        healthy.watchdogTick()
        suite.expect(healthy.hardware?.updates == [50, 50]
                        && healthy.hardware?.activeCoolingTargets == [3_600, 3_600],
                     "a ramped target at the same cooling level is still written")

        let failed = Controller()
        failed.hardware?.failUpdate = true
        let failedTimer = failed.timer
        failed.watchdogTick()
        suite.expect(failed.isCooling && failed.verificationFailures == 1
                        && failed.hardware?.restores == 0,
                     "a failed sensor write counts as a verification failure and retries")
        failed.watchdogTick()
        failed.watchdogTick()
        suite.expect(failed.hardware?.updates == [50, 50, 50] && failed.hardware?.restores == 1
                        && failed.hardware?.isManual == false && !failed.isCooling
                        && !failed.isRecovering && failed.owner == nil
                        && failed.activeConfiguration == nil && failed.coolingLevel == nil
                        && !failed.ownership.marker && !failed.ownership.isHeld
                        && failed.lastStopReason == .hardwareChanged
                        && failedTimer?.cancelled == true && failed.timer == nil,
                     "repeated failed sensor writes restore firmware control at the verification limit")
        suite.expect(failed.log.notices.last?.hasSuffix("hardwareChanged") == true,
                     "the reason the session ended reaches the log")
        failed.hardware?.failUpdate = false
        failed.watchdogTick()
        suite.expect(failed.hardware?.updates == [50, 50, 50] && failed.hardware?.restores == 1,
                     "a later tick cannot restart manual control after the watchdog restored firmware")

        let transientWrite = Controller()
        transientWrite.hardware?.failUpdate = true
        transientWrite.watchdogTick()
        transientWrite.hardware?.failUpdate = false
        transientWrite.watchdogTick()
        suite.expect(transientWrite.isCooling && transientWrite.verificationFailures == 0
                        && transientWrite.hardware?.restores == 0
                        && transientWrite.hardware?.activeCoolingTargets == [3_500, 3_500],
                     "one transient write failure recovers on the next tick without dropping control")

        let missingSensor = Controller()
        missingSensor.hardware?.request = nil
        missingSensor.watchdogTick()
        missingSensor.watchdogTick()
        suite.expect(missingSensor.isCooling && missingSensor.temperatureFailures == 2,
                     "a briefly missing sensor keeps control within the temperature tolerance")
        missingSensor.watchdogTick()
        suite.expect(!missingSensor.isCooling && missingSensor.hardware?.restores == 1
                        && missingSensor.lastStopReason == .temperatureUnavailable,
                     "a sensor that stays unavailable returns the fans to firmware control")

        let recovering = Controller()
        recovering.hardware?.failUpdate = true
        recovering.hardware?.restoreResults = [false, false, true]
        recovering.watchdogTick()
        recovering.watchdogTick()
        recovering.watchdogTick()
        suite.expect(recovering.isRecovering && !recovering.isCooling
                        && recovering.owner == nil && recovering.activeConfiguration == nil
                        && recovering.coolingLevel == nil && recovering.ownership.isHeld
                        && recovering.ownership.marker && recovering.timer != nil
                        && recovering.lastStopReason == .hardwareChanged
                        && recovering.log.errors.last?.hasSuffix("hardwareChanged") == true,
                     "failed restoration retains the marker and watchdog but ends manual control ownership")
        recovering.hardware?.failUpdate = false
        recovering.watchdogTick()
        suite.expect(recovering.hardware?.updates == [50, 50, 50] && recovering.hardware?.restores == 2
                        && recovering.isRecovering && recovering.ownership.marker,
                     "recovery retries automatic mode without reapplying the curve")
        recovering.watchdogTick()
        suite.expect(recovering.hardware?.updates == [50, 50, 50] && recovering.hardware?.restores == 3
                        && recovering.hardware?.isManual == false && !recovering.isRecovering
                        && !recovering.ownership.marker && !recovering.ownership.isHeld
                        && recovering.timer == nil && recovering.exitChecks == 1
                        && recovering.lastStopReason == .hardwareChanged
                        && recovering.log.notices.last?.hasSuffix("hardwareChanged") == true,
                     "successful automatic recovery releases ownership and stops retrying")

        let requested = Controller()
        requested.hardware?.restoreResults = [false, true]
        _ = requested.performRestore(reason: nil)
        requested.watchdogTick()
        suite.expect(!requested.isRecovering && requested.lastStopReason == nil
                        && requested.log.notices.last?.hasSuffix("requested") == true,
                     "an explicit restore retains its requested reason across recovery")

        let markerFailure = Controller()
        markerFailure.hardware?.controlIntact = false
        markerFailure.activeConfiguration = .manual(level: 50)
        markerFailure.ownership.canRemoveMarker = false
        markerFailure.watchdogTick()
        markerFailure.watchdogTick()
        markerFailure.watchdogTick()
        suite.expect(markerFailure.hardware?.isManual == false && markerFailure.isRecovering
                        && !markerFailure.isCooling && markerFailure.ownership.marker,
                     "a failed marker removal stays in recovery even after the fans return to automatic")
        markerFailure.ownership.canRemoveMarker = true
        markerFailure.watchdogTick()
        suite.expect(markerFailure.hardware?.updates.isEmpty == true && !markerFailure.isRecovering
                        && !markerFailure.ownership.marker,
                     "marker cleanup retries never restart manual control")

        let transientRead = Controller()
        transientRead.activeConfiguration = .manual(level: 50)
        transientRead.hardware?.controlIntact = false
        transientRead.watchdogTick()
        suite.expect(transientRead.isCooling && transientRead.verificationFailures == 1
                        && transientRead.hardware?.restores == 0,
                     "a read-only verification failure retains the existing watchdog tolerance")
        transientRead.hardware?.controlIntact = true
        transientRead.watchdogTick()
        suite.expect(transientRead.isCooling && transientRead.verificationFailures == 0
                        && transientRead.hardware?.restores == 0,
                     "healthy verification clears a transient read failure without stopping cooling")
    }
}
