import SwiftData
import SwiftUI

struct AddCPAPSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date.now
    @State private var ahi: Double = 0
    @State private var usageHours: Int = 7
    @State private var usageMinutes: Int = 0
    @State private var leakRate: Double = 0
    @State private var pressureMin: Double = 8
    @State private var pressureMax: Double = 12
    @State private var pressureMean: Double = 10
    @State private var obstructiveEvents: Int = 0
    @State private var centralEvents: Int = 0
    @State private var hypopneaEvents: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Session Date", selection: $date, displayedComponents: .date)
                }

                Section("Key Metrics") {
                    HStack {
                        Text("AHI")
                        Spacer()
                        TextField("", value: $ahi, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Usage")
                        Spacer()
                        Picker("Hours", selection: $usageHours) {
                            ForEach(0..<24) { Text("\($0)h").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 60)
                        Picker("Minutes", selection: $usageMinutes) {
                            ForEach(0..<60) { Text("\($0)m").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 60)
                    }
                    HStack {
                        Text("Leak 95th %ile (L/min)")
                        Spacer()
                        TextField("", value: $leakRate, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Pressure (cmH₂O)") {
                    numberRow("Min", value: $pressureMin)
                    numberRow("Max", value: $pressureMax)
                    numberRow("Mean", value: $pressureMean)
                }

                Section("Events") {
                    Stepper("Obstructive: \(obstructiveEvents)", value: $obstructiveEvents, in: 0...999)
                    Stepper("Central: \(centralEvents)", value: $centralEvents, in: 0...999)
                    Stepper("Hypopnea: \(hypopneaEvents)", value: $hypopneaEvents, in: 0...999)
                }
            }
            .navigationTitle("Add CPAP Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func numberRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }

    private func save() {
        let session = CPAPSession(
            date: date,
            ahi: ahi,
            totalUsageMinutes: usageHours * 60 + usageMinutes,
            leakRate95th: leakRate,
            pressureMin: pressureMin,
            pressureMax: pressureMax,
            pressureMean: pressureMean,
            obstructiveEvents: obstructiveEvents,
            centralEvents: centralEvents,
            hypopneaEvents: hypopneaEvents,
            importSource: "manual"
        )
        modelContext.insert(session)
        dismiss()
    }
}
