// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct FanControlSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = FanControlService.shared
    @AppStorage(DefaultsKey.fanControlMode) private var modeRaw = FanControlMode.system.rawValue
    @AppStorage(DefaultsKey.fanControlCoolingLevel) private var coolingLevel =
        FanControlPolicy.defaultCoolingLevel
    @AppStorage(DefaultsKey.fanControlCurves) private var curvesStorage =
        FanControlConfiguration.defaultCurvesStorage
    @AppStorage(DefaultsKey.temperatureUnit) private var temperatureUnit =
        TemperatureUnit.celsius.rawValue
    var collapsible = true

    private var strings: FanControlFeatureStrings {
        FeatureStrings.fanControl(l10n.language)
    }

    var body: some View {
        PanelSection(.fanControl, title: strings.title, collapsible: collapsible) {
            FanControlCardContent(strings: strings,
                                  betaLabel: l10n.s.betaBadge,
                                  snapshot: service.snapshot,
                                  accessState: service.accessState,
                                  error: service.error,
                                  isWorking: service.isWorking,
                                  mode: modeBinding,
                                  coolingLevel: $coolingLevel,
                                  curves: curvesBinding,
                                  temperatureUnit: displayTemperatureUnit,
                                  authorize: service.authorize,
                                  applyConfiguration: service.applyConfiguration,
                                  stopCooling: service.restoreAutomatic)
                .panelCard()
                .onAppear { service.panelDidAppear() }
                .onDisappear { service.panelDidDisappear() }
        }
    }

    private var modeBinding: Binding<FanControlMode> {
        Binding(
            get: { FanControlMode(rawValue: modeRaw) ?? .system },
            set: { modeRaw = $0.rawValue }
        )
    }

    private var curvesBinding: Binding<[FanControlCurve]> {
        Binding(
            get: {
                FanControlConfiguration.decodeCurves(curvesStorage)
                    ?? [FanControlConfiguration.defaultCurve]
            },
            set: { curves in
                if let encoded = FanControlConfiguration.encodeCurves(curves) {
                    curvesStorage = encoded
                }
            }
        )
    }

    private var displayTemperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnit) ?? .celsius
    }
}

struct FanControlCardContent: View {
    @State private var sensorsExpanded = true

    let strings: FanControlFeatureStrings
    let betaLabel: String
    let snapshot: FanControlSnapshot
    let accessState: FanControlService.AccessState
    let error: FanControlErrorCode?
    let isWorking: Bool
    @Binding var mode: FanControlMode
    @Binding var coolingLevel: Int
    @Binding var curves: [FanControlCurve]
    let temperatureUnit: TemperatureUnit
    let authorize: () -> Void
    let applyConfiguration: (FanControlConfiguration) -> Void
    let stopCooling: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader

            if !snapshot.fans.isEmpty { fanRows }

            if let sensors = snapshot.sensors, !sensors.isEmpty {
                sensorRows(sensors)
            }

            if let message = stateMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canConfigure {
                modePicker
                switch mode {
                case .system:
                    EmptyView()
                case .manual:
                    manualControl
                case .curve:
                    FanControlCurveEditor(strings: strings,
                                          curves: $curves,
                                          temperatures: snapshot.temperatures ?? [],
                                          temperatureUnit: temperatureUnit,
                                          disabled: isWorking)
                    if !curveCanRun {
                        Text(strings.curveUnavailable)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            action

            if controlsCanAppear {
                Text(strings.safetyCaption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondary.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modePicker: some View {
        Picker(strings.mode, selection: $mode) {
            Text(strings.systemControl).tag(FanControlMode.system)
            Text(strings.manualControl).tag(FanControlMode.manual)
            Text(strings.customCurve).tag(FanControlMode.curve)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .disabled(isWorking)
    }

    private var manualControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(strings.coolingIntensity)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedCoolingLevel)%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            Slider(value: coolingLevelBinding,
                   in: Double(FanControlPolicy.minimumCoolingLevel)...Double(FanControlPolicy.maximumCoolingLevel),
                   step: Double(FanControlPolicy.coolingLevelStep))
                .controlSize(.small)
                .disabled(isWorking)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.isCooling ? "fanblades.fill" : "fanblades")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(snapshot.isCooling ? AnyShapeStyle(Color.cyan)
                                                     : AnyShapeStyle(Color.secondary))
                .symbolEffect(.variableColor.iterative, options: .repeating,
                              isActive: snapshot.isCooling)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(strings.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(betaLabel)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }
                Text(statusText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(snapshot.isCooling ? Color.cyan : Color.secondary)
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    private var fanRows: some View {
        VStack(spacing: 5) {
            ForEach(snapshot.fans) { fan in
                HStack(spacing: 6) {
                    Text(String(format: strings.fanNameFormat, fan.index + 1))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: strings.currentRPMFormat,
                                    Int(fan.actualRPM.rounded())))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        if fan.isManuallyControlled {
                            Text(String(format: strings.targetRPMFormat,
                                        Int(fan.targetRPM.rounded())))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func sensorRows(_ sensors: [FanControlSensorReading]) -> some View {
        VStack(spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { sensorsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sensorsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.secondary)
                    Text(headlineTemperature(in: sensors)?.name ?? strings.temperature)
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    if let headline = headlineTemperature(in: sensors) {
                        Text(MetricFormat.temperature(headline.celsius, unit: temperatureUnit))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(sensors.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(sensorsExpanded ? "Expanded" : "Collapsed")

            if sensorsExpanded {
                VStack(spacing: 5) {
                    ForEach(sensors) { sensor in
                        HStack(spacing: 8) {
                            sensorIcon(sensor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sensor.name)
                                    .font(.system(size: 10.5))
                                Text(sensor.key)
                                    .font(.system(size: 8.5).monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(MetricFormat.temperature(sensor.celsius, unit: temperatureUnit))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        }
                    }
                }
                .padding(.top, 5)
            }
        }
    }

    private func headlineTemperature(
        in sensors: [FanControlSensorReading]
    ) -> (name: String, celsius: Double)? {
        if let proximity = snapshot.temperatures?.first(where: { $0.source == .cpuProximity }) {
            return ("CPU proximity", proximity.celsius)
        }
        if let hottestSoC = snapshot.temperatures?.first(where: { $0.source == .hottestSoC }) {
            return ("Hottest SoC", hottestSoC.celsius)
        }
        if let hottest = sensors.max(by: { $0.celsius < $1.celsius }) {
            return (hottest.name, hottest.celsius)
        }
        return nil
    }

    private func sensorIcon(_ sensor: FanControlSensorReading) -> some View {
        let presentation = sensorIconPresentation(sensor)
        return Image(systemName: presentation.name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(presentation.color)
            .frame(width: 15)
            .accessibilityHidden(true)
    }

    private func sensorIconPresentation(
        _ sensor: FanControlSensorReading
    ) -> (name: String, color: Color) {
        if sensor.key.hasPrefix("TB") {
            return ("battery.75percent", .green)
        }
        if sensor.key.hasPrefix("TC") {
            return ("cpu", .green)
        }
        if sensor.key.hasPrefix("TG") {
            return ("rectangle.3.group", .purple)
        }
        if sensor.key.hasPrefix("Ts") {
            return ("internaldrive", .secondary)
        }
        if sensor.key.hasPrefix("TW") {
            return ("wifi", .blue)
        }
        if sensor.key.hasPrefix("TA") || sensor.key.hasPrefix("Ta") {
            return ("wind", .cyan)
        }
        return ("thermometer.medium", .orange)
    }

    @ViewBuilder
    private var action: some View {
        if error == .noFans || error == .unsupportedHardware || error == .alreadyControlled {
            EmptyView()
        } else if accessState == .notRegistered, !snapshot.fans.isEmpty {
            Button(strings.allowControl, action: authorize)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if accessState == .requiresApproval, !snapshot.fans.isEmpty {
            Button(strings.openSettings, action: authorize)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if accessState == .enabled, controlsCanAppear {
            switch mode {
            case .system:
                if snapshot.isCooling {
                    Button(strings.returnToSystem, action: stopCooling)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isWorking)
                        .frame(maxWidth: .infinity)
                }
            case .manual:
                Button(strings.applyManual) {
                    coolingLevel = selectedCoolingLevel
                    applyConfiguration(.manual(level: selectedCoolingLevel))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking)
                .frame(maxWidth: .infinity)
            case .curve:
                Button(strings.applyCurve) {
                    applyConfiguration(.curve(curves))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking || !curveCanRun)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusText: String {
        guard snapshot.isCooling else { return strings.systemControl }
        let level = snapshot.coolingLevel ?? FanControlPolicy.defaultCoolingLevel
        let target = snapshot.fans
            .filter(\.isManuallyControlled)
            .map(\.targetRPM)
            .first
            .map { String(format: strings.targetRPMFormat, Int($0.rounded())) }
        switch snapshot.configuration?.mode ?? .manual {
        case .system:
            return strings.systemControl
        case .manual:
            return "\(strings.manualControl) · \(target ?? "\(level)%")"
        case .curve:
            let activeCurves = snapshot.configuration?.curves ?? []
            let temperature = activeCurves.count == 1
                ? snapshot.temperatures?.first { $0.source == activeCurves[0].sensor }?.celsius
                : nil
            if let temperature {
                return "\(strings.customCurve) · \(MetricFormat.temperature(temperature, unit: temperatureUnit)) · \(target ?? "\(level)%")"
            }
            return "\(strings.customCurve) · \(target ?? "\(level)%")"
        }
    }

    private var stateMessage: String? {
        if error == .noFans { return strings.noFans }
        if accessState == .unavailable { return strings.unsupported }
        switch error {
        case .alreadyControlled: return strings.alreadyControlled
        case .unsupportedHardware: return strings.unsupported
        case .helperUnavailable, .controlFailed: return strings.failed
        case .authorizationRequired: return strings.approvalCaption
        case .noFans, .none: break
        }
        if accessState == .notRegistered, !snapshot.fans.isEmpty { return strings.approvalCaption }
        if accessState == .requiresApproval { return strings.approvalCaption }
        switch snapshot.stopReason {
        case .temperatureUnavailable: return strings.temperatureUnavailable
        case .timeLimit, .appDisconnected, .heartbeatLost, .hardwareChanged,
             .thermalPressure, .recovery:
            return strings.safetyStopped
        case .none:
            return nil
        }
    }

    private var messageIsError: Bool {
        switch error {
        case .alreadyControlled, .unsupportedHardware, .helperUnavailable, .controlFailed:
            return true
        default:
            return false
        }
    }

    private var controlsCanAppear: Bool {
        !snapshot.fans.isEmpty
            && (error == nil || error == .controlFailed || snapshot.isCooling)
    }

    private var canConfigure: Bool {
        controlsCanAppear && accessState == .enabled
    }

    private var selectedCoolingLevel: Int {
        let clamped = min(max(coolingLevel, FanControlPolicy.minimumCoolingLevel),
                          FanControlPolicy.maximumCoolingLevel)
        let remainder = clamped % FanControlPolicy.coolingLevelStep
        return remainder == 0 ? clamped : clamped + FanControlPolicy.coolingLevelStep - remainder
    }

    private var coolingLevelBinding: Binding<Double> {
        Binding(
            get: { Double(selectedCoolingLevel) },
            set: { coolingLevel = Int($0.rounded()) }
        )
    }

    private var curveCanRun: Bool {
        guard FanControlPolicy.validCurves(curves) else { return false }
        let available = Set((snapshot.temperatures ?? []).map(\.source))
        return curves.allSatisfy { available.contains($0.sensor) }
    }
}
