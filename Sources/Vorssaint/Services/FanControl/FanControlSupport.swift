// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct FanControlFanReading: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let actualRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let isManuallyControlled: Bool

    var id: Int { index }
}

enum FanControlMode: String, Codable, Sendable {
    case system
    case manual
    case curve
}

enum FanControlTemperatureSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpuProximity
    case wirelessProximity
    case ambientOutsideLid
    case ambientAirflow
    case leftAirflow
    case rightAirflow
    case leftAirflowProximity
    case rightAirflowProximity
    case topProximity
    case battery1
    case battery2
    case battery3
    case battery4
    case cpuDieAverage
    case cpuDie
    case gpuDie
    case gpuProximity
    case storageProximity1
    case storageProximity2
    case averageSoC
    case hottestSoC
    case averageCPU
    case hottestCPU
    case hottestGPU

    var id: String { rawValue }
}

struct FanControlTemperatureReading: Codable, Equatable, Sendable {
    let source: FanControlTemperatureSource
    let celsius: Double
}

struct FanControlSafetyDemand: Equatable, Sendable {
    let celsius: Double
    let coolingLevel: Int
}

struct FanControlCoolingRequest: Equatable, Sendable {
    let level: Int
    let targets: [Double]
}

struct FanControlSensorReading: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let name: String
    let celsius: Double

    var id: String { key }
}

struct FanControlCurvePoint: Codable, Equatable, Sendable {
    var temperature: Int
    var coolingLevel: Int
}

struct FanControlCurve: Codable, Equatable, Sendable {
    var sensor: FanControlTemperatureSource
    var points: [FanControlCurvePoint]
}

struct FanControlConfiguration: Codable, Equatable, Sendable {
    var mode: FanControlMode
    var manualLevel: Int
    var curves: [FanControlCurve]

    static let defaultCurve = FanControlCurve(
        sensor: .cpuProximity,
        points: [
            FanControlCurvePoint(temperature: 50, coolingLevel: 0),
            FanControlCurvePoint(temperature: 70, coolingLevel: 100),
        ]
    )

    static func manual(level: Int) -> FanControlConfiguration {
        FanControlConfiguration(mode: .manual, manualLevel: level,
                                curves: [])
    }

    static func curve(_ curves: [FanControlCurve]) -> FanControlConfiguration {
        FanControlConfiguration(mode: .curve,
                                manualLevel: FanControlPolicy.defaultCoolingLevel,
                                curves: curves)
    }

    static func encodeCurves(_ curves: [FanControlCurve]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(curves) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeCurves(_ value: String) -> [FanControlCurve]? {
        guard let data = value.data(using: .utf8),
              let curves = try? JSONDecoder().decode([FanControlCurve].self, from: data),
              FanControlPolicy.validCurves(curves) else { return nil }
        return curves
    }

    static var defaultCurvesStorage: String {
        encodeCurves([defaultCurve]) ?? "[]"
    }
}

struct FanControlSnapshot: Codable, Equatable, Sendable {
    var fans: [FanControlFanReading]
    var isCooling: Bool
    var endsAt: Date?
    var stopReason: FanControlStopReason?
    var coolingLevel: Int?
    var configuration: FanControlConfiguration?
    var temperatures: [FanControlTemperatureReading]?
    var sensors: [FanControlSensorReading]? = nil

    static let empty = FanControlSnapshot(fans: [], isCooling: false,
                                          endsAt: nil, stopReason: nil,
                                          coolingLevel: nil,
                                          configuration: nil,
                                          temperatures: nil)
}

enum FanControlStopReason: String, Codable, Equatable, Sendable {
    case timeLimit
    case appDisconnected
    case heartbeatLost
    case hardwareChanged
    case thermalPressure
    case temperatureUnavailable
    case recovery
}

enum FanControlErrorCode: String, Codable, Equatable, Error, Sendable {
    case noFans
    case unsupportedHardware
    case alreadyControlled
    case authorizationRequired
    case helperUnavailable
    case controlFailed
}

struct FanControlResponse: Codable, Equatable, Sendable {
    let succeeded: Bool
    let snapshot: FanControlSnapshot
    let error: FanControlErrorCode?

    static func success(_ snapshot: FanControlSnapshot) -> FanControlResponse {
        FanControlResponse(succeeded: true, snapshot: snapshot, error: nil)
    }

    static func failure(_ error: FanControlErrorCode,
                        snapshot: FanControlSnapshot = .empty) -> FanControlResponse {
        FanControlResponse(succeeded: false, snapshot: snapshot, error: error)
    }
}

enum FanControlPolicy {
    /// Retained only for the legacy XPC entry point used by older app builds.
    static let coolingDuration: TimeInterval = 15 * 60
    static let heartbeatLimit: TimeInterval = 7
    static let verificationFailureLimit = 3
    static let temperatureFailureLimit = 3
    static let maximumFanCount = 8
    static let maximumSaneRPM = 20_000.0
    static let minimumCoolingLevel = 0
    static let maximumCoolingLevel = 100
    static let coolingLevelStep = 5
    static let defaultCoolingLevel = maximumCoolingLevel
    static let minimumCurveTemperature = 20
    static let maximumCurveTemperature = 110
    static let minimumCurvePointCount = 2
    static let maximumCurvePointCount = 2
    static let maximumCurveCount = 1
    static let minimumSensorTemperatureSpan = 8
    static let safetyCurvePoints = [
        FanControlCurvePoint(temperature: 75, coolingLevel: 25),
        FanControlCurvePoint(temperature: 85, coolingLevel: 50),
        FanControlCurvePoint(temperature: 95, coolingLevel: 100),
    ]

    static func isAutomaticMode(_ mode: UInt8) -> Bool {
        mode == 0 || mode == 3
    }

    static func fanCount(from value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard abs(value - rounded) < 0.001 else { return nil }
        let count = Int(rounded)
        return (1...maximumFanCount).contains(count) ? count : nil
    }

    static func validBounds(minimum: Double, maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite
            && minimum >= 0 && maximum > minimum && maximum <= maximumSaneRPM
    }

    static func validReading(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximumSaneRPM
    }

    static func validCoolingLevel(_ level: Int) -> Bool {
        (minimumCoolingLevel...maximumCoolingLevel).contains(level)
    }

    static func validManualCoolingLevel(_ level: Int) -> Bool {
        validCoolingLevel(level) && level.isMultiple(of: coolingLevelStep)
    }

    static func coolingTargetRPM(minimum: Double, maximum: Double,
                                 level: Int) -> Double? {
        guard validBounds(minimum: minimum, maximum: maximum),
              validCoolingLevel(level) else { return nil }
        return minimum + (maximum - minimum) * Double(level) / 100
    }

    static func sensorBasedTargetRPM(minimum: Double, maximum: Double,
                                     startTemperature: Int, maximumTemperature: Int,
                                     temperature: Double) -> Double? {
        guard validBounds(minimum: minimum, maximum: maximum),
              validTemperature(temperature),
              (minimumCurveTemperature...maximumCurveTemperature).contains(startTemperature),
              (minimumCurveTemperature...maximumCurveTemperature).contains(maximumTemperature),
              maximumTemperature - startTemperature >= minimumSensorTemperatureSpan else {
            return nil
        }
        let wholeTemperature = Int(temperature.rounded(.towardZero))
        if wholeTemperature <= startTemperature { return minimum }
        if wholeTemperature >= maximumTemperature { return maximum }
        let rpmPerDegree = Int((maximum - minimum)
            / Double(maximumTemperature - startTemperature))
        return min(maximum, max(minimum,
            minimum + Double((wholeTemperature - startTemperature) * rpmPerDegree)))
    }

    static func sensorBasedRampLimitRPM(minimum: Double, maximum: Double,
                                        startTemperature: Int,
                                        maximumTemperature: Int) -> Double? {
        guard validBounds(minimum: minimum, maximum: maximum),
              maximumTemperature - startTemperature >= minimumSensorTemperatureSpan else {
            return nil
        }
        let rpmPerDegree = Int((maximum - minimum)
            / Double(maximumTemperature - startTemperature))
        return Double(max(2, rpmPerDegree / 3 + 2))
    }

    static func rampedSensorBasedTargetRPM(current: Double, desired: Double,
                                           limit: Double) -> Double {
        guard current.isFinite, desired.isFinite, limit.isFinite, limit > 0 else {
            return desired
        }
        if desired > current { return min(desired, current + limit) }
        if desired < current { return max(desired, current - limit) }
        return desired
    }

    static func validConfiguration(_ configuration: FanControlConfiguration) -> Bool {
        switch configuration.mode {
        case .system:
            return true
        case .manual:
            return validManualCoolingLevel(configuration.manualLevel)
        case .curve:
            return validCurves(configuration.curves)
        }
    }

    static func validCurves(_ curves: [FanControlCurve]) -> Bool {
        guard curves.count == maximumCurveCount else { return false }
        return curves.allSatisfy(validCurve)
    }

    static func validCurve(_ curve: FanControlCurve) -> Bool {
        guard curve.points.count == minimumCurvePointCount,
              curve.points[0].coolingLevel == minimumCoolingLevel,
              curve.points[1].coolingLevel == maximumCoolingLevel,
              curve.points[1].temperature - curve.points[0].temperature
                >= minimumSensorTemperatureSpan else {
            return false
        }
        for (index, point) in curve.points.enumerated() {
            guard (minimumCurveTemperature...maximumCurveTemperature).contains(point.temperature),
                  validCoolingLevel(point.coolingLevel) else { return false }
            if index > 0 {
                let previous = curve.points[index - 1]
                guard point.temperature > previous.temperature,
                      point.coolingLevel >= previous.coolingLevel else { return false }
            }
        }
        return true
    }

    static func curveCoolingLevel(curves: [FanControlCurve],
                                  temperatures: [FanControlTemperatureReading],
                                  previousLevel: Int? = nil) -> Int? {
        // Macs Fan Control's sensor mode follows the selected sensor only.
        // Safety is handled independently by the helper watchdog and macOS
        // thermal pressure, never by silently substituting a different sensor.
        configuredCurveCoolingLevel(curves: curves, temperatures: temperatures)
    }

    static func configuredCurveCoolingLevel(
        curves: [FanControlCurve],
        temperatures: [FanControlTemperatureReading]
    ) -> Int? {
        guard validCurves(curves) else { return nil }
        let values = Dictionary(temperatures.map { ($0.source, $0.celsius) },
                                uniquingKeysWith: { _, newest in newest })
        guard let curve = curves.first,
              let temperature = values[curve.sensor], validTemperature(temperature) else {
            return nil
        }
        return interpolatedCoolingLevel(points: curve.points, temperature: temperature)
    }

    static func safetyCoolingLevel(
        temperatures: [FanControlTemperatureReading]
    ) -> Int? {
        safetyDemand(temperatures: temperatures)?.coolingLevel
    }

    static func safetyDemand(
        temperatures: [FanControlTemperatureReading]
    ) -> FanControlSafetyDemand? {
        let dieSources: Set<FanControlTemperatureSource> = [
            .hottestSoC, .hottestCPU, .hottestGPU,
        ]
        guard let hottest = temperatures.lazy
            .filter({ dieSources.contains($0.source) && validTemperature($0.celsius) })
            .map(\.celsius)
            .max(),
            hottest >= Double(safetyCurvePoints[0].temperature) else { return nil }
        return FanControlSafetyDemand(
            celsius: hottest,
            coolingLevel: interpolatedCoolingLevel(points: safetyCurvePoints,
                                                    temperature: hottest)
        )
    }

    static func interpolatedCoolingLevel(points: [FanControlCurvePoint],
                                         temperature: Double) -> Int {
        guard let first = points.first, let last = points.last else {
            return minimumCoolingLevel
        }
        if temperature <= Double(first.temperature) { return first.coolingLevel }
        if temperature >= Double(last.temperature) { return last.coolingLevel }
        for index in 1..<points.count {
            let upper = points[index]
            guard temperature <= Double(upper.temperature) else { continue }
            let lower = points[index - 1]
            // Macs Fan Control evaluates whole Celsius degrees and truncates
            // the linear step. This avoids the old upward 5% bias.
            let wholeTemperature = temperature.rounded(.towardZero)
            let wholeProgress = (wholeTemperature - Double(lower.temperature))
                / Double(upper.temperature - lower.temperature)
            let raw = Double(lower.coolingLevel)
                + Double(upper.coolingLevel - lower.coolingLevel) * wholeProgress
            return min(maximumCoolingLevel,
                       max(minimumCoolingLevel, Int(raw.rounded(.down))))
        }
        return last.coolingLevel
    }

    static func validTemperature(_ value: Double) -> Bool {
        value.isFinite && value >= 1 && value < 125
    }

    private static let hardwareSensorMetadata: [(key: String, name: String)] = [
        ("TAOL", "Ambient outside lid"),
        ("TA0P", "Ambient airflow"),
        ("TaLP", "Left airflow"),
        ("TaRF", "Right airflow"),
        ("TaLW", "Left airflow proximity"),
        ("TaRW", "Right airflow proximity"),
        ("TaTP", "Top proximity"),
        ("TB0T", "Battery 1"),
        ("TB1T", "Battery 2"),
        ("TB2T", "Battery 3"),
        ("TB3T", "Battery 4"),
        ("TCMb", "CPU die average"),
        ("TC0D", "CPU die"),
        ("TCHP", "CPU proximity"),
        ("TC0P", "CPU proximity"),
        ("TG0D", "GPU die"),
        ("TG0P", "GPU proximity"),
        ("Ts0P", "Storage proximity 1"),
        ("Ts1P", "Storage proximity 2"),
        ("TW0P", "Wireless proximity"),
    ]

    static let hardwareSensorKeys = Set(hardwareSensorMetadata.map(\.key))

    static func hardwareSensorReadings(
        _ readings: [(key: String, value: Double)]
    ) -> [FanControlSensorReading] {
        let values = Dictionary(readings.map { ($0.key, $0.value) },
                                uniquingKeysWith: { _, newest in newest })
        return hardwareSensorMetadata.compactMap { sensor in
            guard let value = values[sensor.key], value.isFinite,
                  value >= -20, value < 125 else { return nil }
            return FanControlSensorReading(key: sensor.key,
                                           name: sensor.name,
                                           celsius: value)
        }
    }

    static func cpuProximityReading(
        _ readings: [(key: String, value: Double)]
    ) -> FanControlTemperatureReading? {
        let values = Dictionary(readings.map { ($0.key, $0.value) },
                                uniquingKeysWith: { _, newest in newest })
        let proximity = ["TCHP", "TC0P"].compactMap { values[$0] }
            .filter(validTemperature)
            .max()
        return proximity.map {
            FanControlTemperatureReading(source: .cpuProximity, celsius: $0)
        }
    }

    static func rawControlTemperatureReadings(
        _ readings: [(key: String, value: Double)]
    ) -> [FanControlTemperatureReading] {
        let values = Dictionary(readings.map { ($0.key, $0.value) },
                                uniquingKeysWith: { _, newest in newest })
        let mappings: [(FanControlTemperatureSource, [String])] = [
            (.wirelessProximity, ["TW0P"]),
            (.ambientOutsideLid, ["TAOL"]),
            (.ambientAirflow, ["TA0P"]),
            (.leftAirflow, ["TaLP"]),
            (.rightAirflow, ["TaRF"]),
            (.leftAirflowProximity, ["TaLW"]),
            (.rightAirflowProximity, ["TaRW"]),
            (.topProximity, ["TaTP"]),
            (.battery1, ["TB0T"]),
            (.battery2, ["TB1T"]),
            (.battery3, ["TB2T"]),
            (.battery4, ["TB3T"]),
            (.cpuDieAverage, ["TCMb"]),
            (.cpuDie, ["TC0D"]),
            (.gpuDie, ["TG0D"]),
            (.gpuProximity, ["TG0P"]),
            (.storageProximity1, ["Ts0P"]),
            (.storageProximity2, ["Ts1P"]),
        ]
        return mappings.compactMap { source, keys in
            guard let value = keys.compactMap({ values[$0] })
                .filter(validTemperature).max() else { return nil }
            return FanControlTemperatureReading(source: source, celsius: value)
        }
    }

    static func temperaturesIncludingDieSafety(
        _ temperatures: [FanControlTemperatureReading],
        hardwareReadings: [(key: String, value: Double)]
    ) -> [FanControlTemperatureReading] {
        let dieTemperature = hardwareReadings.lazy
            .filter { $0.key == "TCMb" || $0.key == "TC0D" }
            .map(\.value)
            .filter(validTemperature)
            .max()
        guard let dieTemperature else { return temperatures }

        var merged = temperatures
        for source in [FanControlTemperatureSource.hottestSoC, .hottestCPU] {
            if let index = merged.firstIndex(where: { $0.source == source }) {
                if dieTemperature > merged[index].celsius {
                    merged[index] = .init(source: source, celsius: dieTemperature)
                }
            } else {
                merged.append(.init(source: source, celsius: dieTemperature))
            }
        }
        return merged
    }

    static func aggregatedTemperatures(
        cpuReadings: [(key: String, value: Double)],
        gpuReadings: [Double],
        platform: CPUTemperaturePlatform
    ) -> [FanControlTemperatureReading] {
        let validCPU = cpuReadings.filter {
            $0.value >= TemperatureSensorSelector.minimumChipTemperature
                && validTemperature($0.value)
        }
        let preferredCPU = validCPU.filter {
            TemperatureSensorSelector.isCPUCoreKey($0.key, platform: platform)
        }
        let cpu = (preferredCPU.isEmpty ? validCPU : preferredCPU).map(\.value)
        let gpu = gpuReadings.filter {
            $0 >= TemperatureSensorSelector.minimumChipTemperature && validTemperature($0)
        }
        let soc = cpu + gpu

        var readings: [FanControlTemperatureReading] = []
        if !soc.isEmpty {
            readings.append(.init(source: .averageSoC,
                                  celsius: soc.reduce(0, +) / Double(soc.count)))
            if let hottest = soc.max() {
                readings.append(.init(source: .hottestSoC, celsius: hottest))
            }
        }
        if !cpu.isEmpty {
            readings.append(.init(source: .averageCPU,
                                  celsius: cpu.reduce(0, +) / Double(cpu.count)))
            if let hottest = cpu.max() {
                readings.append(.init(source: .hottestCPU, celsius: hottest))
            }
        }
        if let hottest = gpu.max() {
            readings.append(.init(source: .hottestGPU, celsius: hottest))
        }
        return readings
    }

    static func telemetryReadings(expectedCount: Int,
                                  readings: [Double?]) -> [Double]? {
        guard (1...maximumFanCount).contains(expectedCount),
              readings.count == expectedCount else { return nil }
        let values = readings.compactMap { $0 }
        guard values.count == expectedCount,
              values.allSatisfy(validReading) else { return nil }
        return values
    }

    static func menuBarValue(for speeds: [Double]) -> String? {
        guard !speeds.isEmpty, speeds.allSatisfy(validReading) else { return nil }
        return speeds.map { String(Int($0.rounded())) }.joined(separator: "/")
    }

    static func menuBarWidthUnits(fanCount: Int) -> Int {
        guard (1...maximumFanCount).contains(fanCount) else { return 0 }
        return 7 + fanCount * 5 + (fanCount - 1)
    }

    static func restoreReason(now: Date,
                              endsAt: Date?,
                              heartbeatAge: TimeInterval,
                              verificationFailures: Int,
                              temperatureFailures: Int = 0,
                              thermalState: ProcessInfo.ThermalState) -> FanControlStopReason? {
        if let endsAt, now >= endsAt { return .timeLimit }
        if heartbeatAge > heartbeatLimit { return .heartbeatLost }
        if verificationFailures >= verificationFailureLimit { return .hardwareChanged }
        if temperatureFailures >= temperatureFailureLimit { return .temperatureUnavailable }
        if thermalState == .serious || thermalState == .critical {
            return .thermalPressure
        }
        return nil
    }

    static func shouldRestoreForWorkspaceSleep(
        recoveryNeeded: Bool,
        keepAwakeActive: Bool,
        clamshellActive: Bool
    ) -> Bool {
        recoveryNeeded && !(keepAwakeActive && clamshellActive)
    }
}

enum SMCValueCodec {
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2" where bytes.count == 2:
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "sp78" where bytes.count == 2:
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256.0
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(UInt32(bytes[0]) << 24
                          | UInt32(bytes[1]) << 16
                          | UInt32(bytes[2]) << 8
                          | UInt32(bytes[3]))
        case "ioft" where bytes.count == 8:
            var raw: UInt64 = 0
            for (offset, byte) in bytes.enumerated() {
                raw |= UInt64(byte) << UInt64(offset * 8)
            }
            return Double(raw) / 65_536.0
        default:
            return nil
        }
    }

    static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        switch type {
        case "flt " where size == 4:
            let float = Float32(value)
            guard float.isFinite else { return nil }
            let bits = float.bitPattern
            return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                    UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2" where size == 2:
            let scaled = (value * 4).rounded()
            guard scaled <= Double(UInt16.max) else { return nil }
            let raw = UInt16(scaled)
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui8 " where size == 1:
            guard value.rounded() == value, value <= Double(UInt8.max) else { return nil }
            return [UInt8(value)]
        case "ui16" where size == 2:
            guard value.rounded() == value, value <= Double(UInt16.max) else { return nil }
            let raw = UInt16(value)
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui32" where size == 4:
            guard value.rounded() == value, value <= Double(UInt32.max) else { return nil }
            let raw = UInt32(value)
            return [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                    UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        default:
            return nil
        }
    }
}
