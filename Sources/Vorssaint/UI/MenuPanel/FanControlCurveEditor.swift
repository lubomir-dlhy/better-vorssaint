// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct FanControlCurveEditor: View {
    let strings: FanControlFeatureStrings
    @Binding var curves: [FanControlCurve]
    let temperatures: [FanControlTemperatureReading]
    let temperatureUnit: TemperatureUnit
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Picker(strings.sensor, selection: sensorBinding) {
                    ForEach(sourceOptions) { source in
                        Label(sourceName(source), systemImage: sourceIcon(source)).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(disabled)

                Spacer(minLength: 4)

                if let temperature = temperature(for: normalizedCurve.sensor) {
                    Text(formattedTemperature(temperature))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

            }

            FanControlCurveGraph(points: .constant(normalizedCurve.points),
                                 accessibilityLabel: strings.curveGraph,
                                 disabled: true)
                .frame(height: 92)

            thresholdRow(
                title: "Fan speed starts increasing at",
                value: startTemperatureBinding,
                range: FanControlPolicy.minimumCurveTemperature ... max(
                    FanControlPolicy.minimumCurveTemperature,
                    maximumTemperature - FanControlPolicy.minimumSensorTemperatureSpan
                )
            )
            thresholdRow(
                title: "Maximum fan speed at",
                value: maximumTemperatureBinding,
                range: min(
                    FanControlPolicy.maximumCurveTemperature,
                    startTemperature + FanControlPolicy.minimumSensorTemperatureSpan
                ) ... FanControlPolicy.maximumCurveTemperature
            )

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                Text("Below the first temperature the fan uses its hardware minimum. Between the two temperatures RPM rises linearly; at the maximum temperature it uses the hardware maximum.")
            }
            .font(.system(size: 9.25))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { persistNormalizedCurve() }
    }

    private func thresholdRow(title: String, value: Binding<Int>,
                              range: ClosedRange<Int>) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10.5))
            Spacer(minLength: 8)
            Text(formattedTemperature(Double(value.wrappedValue)))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
            Stepper(title, value: value, in: range)
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityValue(formattedTemperature(Double(value.wrappedValue)))
                .disabled(disabled)
        }
    }

    private var normalizedCurve: FanControlCurve {
        guard let stored = curves.first else { return FanControlConfiguration.defaultCurve }
        let sorted = stored.points.sorted { $0.temperature < $1.temperature }
        let start = min(FanControlPolicy.maximumCurveTemperature
                            - FanControlPolicy.minimumSensorTemperatureSpan,
                        max(FanControlPolicy.minimumCurveTemperature,
                            sorted.first?.temperature
                                ?? FanControlConfiguration.defaultCurve.points[0].temperature))
        let maximum = min(FanControlPolicy.maximumCurveTemperature,
                          max(start + FanControlPolicy.minimumSensorTemperatureSpan,
                              sorted.last?.temperature
                                ?? FanControlConfiguration.defaultCurve.points[1].temperature))
        return FanControlCurve(
            sensor: stored.sensor,
            points: [
                FanControlCurvePoint(temperature: start, coolingLevel: 0),
                FanControlCurvePoint(temperature: maximum, coolingLevel: 100),
            ]
        )
    }

    private func persistNormalizedCurve() {
        let normalized = normalizedCurve
        if curves != [normalized] { curves = [normalized] }
    }

    private var sensorBinding: Binding<FanControlTemperatureSource> {
        Binding(
            get: { normalizedCurve.sensor },
            set: { sensor in
                var updated = normalizedCurve
                updated.sensor = sensor
                curves = [updated]
            }
        )
    }

    private var startTemperatureBinding: Binding<Int> {
        Binding(
            get: { startTemperature },
            set: { value in
                var updated = normalizedCurve
                updated.points[0].temperature = value
                curves = [updated]
            }
        )
    }

    private var maximumTemperatureBinding: Binding<Int> {
        Binding(
            get: { maximumTemperature },
            set: { value in
                var updated = normalizedCurve
                updated.points[1].temperature = value
                curves = [updated]
            }
        )
    }

    private var startTemperature: Int {
        normalizedCurve.points[0].temperature
    }

    private var maximumTemperature: Int {
        normalizedCurve.points[1].temperature
    }

    private var sourceOptions: [FanControlTemperatureSource] {
        let current = normalizedCurve.sensor
        let detected = Set(temperatures.map(\.source))
        return FanControlTemperatureSource.allCases.filter {
            $0 == current || detected.isEmpty || detected.contains($0)
        }
    }

    private func temperature(for source: FanControlTemperatureSource) -> Double? {
        temperatures.first { $0.source == source }?.celsius
    }

    private func formattedTemperature(_ celsius: Double) -> String {
        MetricFormat.temperature(celsius, unit: temperatureUnit)
    }

    private func sourceName(_ source: FanControlTemperatureSource) -> String {
        switch source {
        case .cpuProximity: return "CPU Proximity"
        case .wirelessProximity: return "Wireless Proximity"
        case .ambientOutsideLid: return "Ambient outside lid"
        case .ambientAirflow: return "Ambient airflow"
        case .leftAirflow: return "Left airflow"
        case .rightAirflow: return "Right airflow"
        case .leftAirflowProximity: return "Left airflow proximity"
        case .rightAirflowProximity: return "Right airflow proximity"
        case .topProximity: return "Top proximity"
        case .battery1: return "Battery 1"
        case .battery2: return "Battery 2"
        case .battery3: return "Battery 3"
        case .battery4: return "Battery 4"
        case .cpuDieAverage: return "CPU die average"
        case .cpuDie: return "CPU die"
        case .gpuDie: return "GPU die"
        case .gpuProximity: return "GPU proximity"
        case .storageProximity1: return "Storage proximity 1"
        case .storageProximity2: return "Storage proximity 2"
        case .averageSoC: return strings.averageSoC
        case .hottestSoC: return strings.hottestSoC
        case .averageCPU: return strings.averageCPU
        case .hottestCPU: return strings.hottestCPU
        case .hottestGPU: return strings.hottestGPU
        }
    }

    private func sourceIcon(_ source: FanControlTemperatureSource) -> String {
        switch source {
        case .cpuProximity, .cpuDieAverage, .cpuDie, .averageCPU, .hottestCPU: return "cpu"
        case .gpuDie, .gpuProximity, .hottestGPU: return "rectangle.3.group"
        case .wirelessProximity: return "wifi"
        case .ambientOutsideLid, .ambientAirflow, .leftAirflow, .rightAirflow,
             .leftAirflowProximity, .rightAirflowProximity, .topProximity: return "wind"
        case .battery1, .battery2, .battery3, .battery4: return "battery.75percent"
        case .storageProximity1, .storageProximity2: return "internaldrive"
        case .averageSoC, .hottestSoC: return "cpu.fill"
        }
    }
}

private struct FanControlCurveGraph: View {
    @Binding var points: [FanControlCurvePoint]
    let accessibilityLabel: String
    let disabled: Bool
    @State private var draggedPoint: Int?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

                ForEach(0..<5, id: \.self) { index in
                    let fraction = CGFloat(index) / 4
                    Path { path in
                        path.move(to: CGPoint(x: 6, y: 6 + fraction * (geometry.size.height - 12)))
                        path.addLine(to: CGPoint(x: geometry.size.width - 6,
                                                 y: 6 + fraction * (geometry.size.height - 12)))
                    }
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 0.5)
                }

                Path { path in
                    for (index, point) in points.enumerated() {
                        let position = position(for: point, in: geometry.size)
                        index == 0 ? path.move(to: position) : path.addLine(to: position)
                    }
                }
                .stroke(Color.cyan,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.cyan)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        .frame(width: draggedPoint == index ? 10 : 8,
                               height: draggedPoint == index ? 10 : 8)
                        .position(position(for: points[index], in: geometry.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if draggedPoint == nil {
                        draggedPoint = nearestPoint(to: value.location, in: geometry.size)
                    }
                    guard let draggedPoint else { return }
                    movePoint(at: draggedPoint, to: value.location, in: geometry.size)
                }
                .onEnded { _ in draggedPoint = nil })
            .allowsHitTesting(!disabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func position(for point: FanControlCurvePoint, in size: CGSize) -> CGPoint {
        let width = max(1, size.width - 12)
        let height = max(1, size.height - 12)
        let x = Double(point.temperature - FanControlPolicy.minimumCurveTemperature)
            / Double(FanControlPolicy.maximumCurveTemperature
                     - FanControlPolicy.minimumCurveTemperature)
        let y = 1 - Double(point.coolingLevel) / Double(FanControlPolicy.maximumCoolingLevel)
        return CGPoint(x: 6 + CGFloat(x) * width, y: 6 + CGFloat(y) * height)
    }

    private func nearestPoint(to location: CGPoint, in size: CGSize) -> Int? {
        points.indices.min { left, right in
            squaredDistance(position(for: points[left], in: size), location)
                < squaredDistance(position(for: points[right], in: size), location)
        }
    }

    private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }

    private func movePoint(at index: Int, to location: CGPoint, in size: CGSize) {
        guard points.indices.contains(index) else { return }
        let width = max(1, size.width - 12)
        let height = max(1, size.height - 12)
        let x = min(1, max(0, (location.x - 6) / width))
        let y = min(1, max(0, (location.y - 6) / height))
        let temperatureRange = FanControlPolicy.maximumCurveTemperature
            - FanControlPolicy.minimumCurveTemperature
        var temperature = FanControlPolicy.minimumCurveTemperature
            + Int((x * CGFloat(temperatureRange)).rounded())
        var level = Int(((1 - y) * CGFloat(FanControlPolicy.maximumCoolingLevel)
                         / CGFloat(FanControlPolicy.coolingLevelStep)).rounded())
            * FanControlPolicy.coolingLevelStep

        if index > 0 {
            temperature = max(temperature, points[index - 1].temperature + 1)
            level = max(level, points[index - 1].coolingLevel)
        }
        if index + 1 < points.count {
            temperature = min(temperature, points[index + 1].temperature - 1)
            level = min(level, points[index + 1].coolingLevel)
        }
        temperature = min(FanControlPolicy.maximumCurveTemperature,
                          max(FanControlPolicy.minimumCurveTemperature, temperature))
        level = min(FanControlPolicy.maximumCoolingLevel,
                    max(FanControlPolicy.minimumCoolingLevel, level))
        points[index] = FanControlCurvePoint(temperature: temperature, coolingLevel: level)
    }
}
