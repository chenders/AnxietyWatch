import SwiftUI

struct CPAPDetailView: View {
    let session: CPAPSession
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]

    private var daySnapshot: HealthSnapshot? {
        let sessionDate = Calendar.current.startOfDay(for: session.date)
        return snapshots.first { $0.date == sessionDate }
    }

    private var dayEntries: [AnxietyEntry] {
        let start = Calendar.current.startOfDay(for: session.date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return entries.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: session.date.formatted(.dateTime.weekday(.wide).month().day().year()))
                LabeledContent("Source", value: session.importSource)
            }

            Section("Key Metrics") {
                HStack {
                    Text("AHI")
                    Spacer()
                    Text(String(format: "%.1f events/hr", session.ahi))
                        .foregroundStyle(ahiColor)
                        .fontWeight(.semibold)
                }
                LabeledContent("Usage", value: usageString)
                if let leak = session.leakRate95th {
                    LabeledContent("Leak (95th %ile)", value: String(format: "%.1f L/min", leak))
                }
            }

            Section("Events") {
                LabeledContent("Obstructive", value: "\(session.obstructiveEvents)")
                LabeledContent("Central", value: "\(session.centralEvents)")
                LabeledContent("Hypopnea", value: "\(session.hypopneaEvents)")
            }

            Section("Pressure (cmH\u{2082}O)") {
                LabeledContent("Min", value: String(format: "%.1f", session.pressureMin))
                LabeledContent("Mean", value: String(format: "%.1f", session.pressureMean))
                LabeledContent("Max", value: String(format: "%.1f", session.pressureMax))
            }

            if daySnapshot != nil || !dayEntries.isEmpty {
                Section("That Day's Context") {
                    if let snap = daySnapshot {
                        if let hrv = snap.hrvAvg {
                            LabeledContent("HRV", value: String(format: "%.0f ms", hrv))
                        }
                        if let rhr = snap.restingHR {
                            LabeledContent("Resting HR", value: String(format: "%.0f bpm", rhr))
                        }
                        if let sleep = snap.sleepDurationMin {
                            LabeledContent("Sleep", value: "\(sleep / 60)h \(sleep % 60)m")
                        }
                    }
                    ForEach(dayEntries) { entry in
                        LabeledContent(
                            "Anxiety @ \(entry.timestamp.formatted(.dateTime.hour().minute()))",
                            value: "\(entry.severity)/10"
                        )
                    }
                }
            }
        }
        .navigationTitle("CPAP Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var usageString: String {
        let h = session.totalUsageMinutes / 60
        let m = session.totalUsageMinutes % 60
        return "\(h)h \(m)m"
    }

    private var ahiColor: Color {
        switch session.ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }
}
