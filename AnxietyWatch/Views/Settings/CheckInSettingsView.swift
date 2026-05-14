import SwiftUI

struct CheckInSettingsView: View {
    @State private var checkInsEnabled = RandomCheckInManager.isEnabled
    @State private var checkInFrequency = RandomCheckInManager.frequencyPerDay
    @State private var activeHoursStart = RandomCheckInManager.activeHoursStart
    @State private var activeHoursEnd = RandomCheckInManager.activeHoursEnd

    var body: some View {
        Form {
            Section {
                Toggle("Enable Check-Ins", isOn: $checkInsEnabled)
                    .onChange(of: checkInsEnabled) { _, newValue in
                        RandomCheckInManager.isEnabled = newValue
                        if newValue {
                            RandomCheckInManager.ensureAuthorization()
                            RandomCheckInManager.scheduleNextCheckIn()
                        } else {
                            RandomCheckInManager.cancelAll()
                        }
                    }

                if checkInsEnabled {
                    Stepper("Times per day: \(checkInFrequency)", value: $checkInFrequency, in: 1...4)
                        .onChange(of: checkInFrequency) { _, newValue in
                            RandomCheckInManager.frequencyPerDay = newValue
                            RandomCheckInManager.cancelAll()
                            RandomCheckInManager.isEnabled = true
                            RandomCheckInManager.scheduleNextCheckIn()
                        }

                    HStack {
                        Text("Active hours")
                        Spacer()
                        Picker("Start", selection: $activeHoursStart) {
                            ForEach(5..<13, id: \.self) { hour in
                                Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                    .tag(hour)
                            }
                        }
                        .labelsHidden()
                        Text("–")
                        Picker("End", selection: $activeHoursEnd) {
                            ForEach(18..<24, id: \.self) { hour in
                                Text("\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")")
                                    .tag(hour)
                            }
                        }
                        .labelsHidden()
                    }
                    .onChange(of: activeHoursStart) { _, newValue in
                        RandomCheckInManager.activeHoursStart = newValue
                        RandomCheckInManager.cancelAll()
                        RandomCheckInManager.isEnabled = true
                        RandomCheckInManager.scheduleNextCheckIn()
                    }
                    .onChange(of: activeHoursEnd) { _, newValue in
                        RandomCheckInManager.activeHoursEnd = newValue
                        RandomCheckInManager.cancelAll()
                        RandomCheckInManager.isEnabled = true
                        RandomCheckInManager.scheduleNextCheckIn()
                    }
                }
            } footer: {
                if checkInsEnabled {
                    let plural = checkInFrequency == 1 ? "" : "s"
                    let startHour = activeHoursStart % 12 == 0 ? 12 : activeHoursStart % 12
                    let startMeridiem = activeHoursStart < 12 ? "AM" : "PM"
                    let endHour = activeHoursEnd % 12 == 0 ? 12 : activeHoursEnd % 12
                    let endMeridiem = activeHoursEnd < 12 ? "AM" : "PM"
                    Text(
                        "You'll get \(checkInFrequency) random check-in\(plural) between " +
                        "\(startHour) \(startMeridiem) and \(endHour) \(endMeridiem)."
                    )
                } else {
                    Text("Random check-ins capture your state at unpredictable moments so trends aren't biased toward bad days.")
                }
            }
        }
        .navigationTitle("Random Check-Ins")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        CheckInSettingsView()
    }
}
#endif
