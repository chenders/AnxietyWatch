import SwiftUI

/// Compact single-line row replacing the old full-width "Last Medication"
/// MetricCard. Renders nothing if no dose recorded.
struct LastMedicationRowView: View {
    let lastDose: MedicationDose?

    var body: some View {
        if let dose = lastDose {
            HStack {
                Image(systemName: "pills.fill").foregroundStyle(.secondary)
                Text("Last medication").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(dose.medicationName) \(String(format: "%.0fmg", dose.doseMg)) · \(dose.timestamp.formatted(.relative(presentation: .named)))")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Last medication: \(dose.medicationName) \(String(format: "%.0f", dose.doseMg)) milligrams, " +
                "\(dose.timestamp.formatted(.relative(presentation: .named)))"
            )
        }
    }
}
