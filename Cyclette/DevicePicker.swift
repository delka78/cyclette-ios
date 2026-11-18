//
//  DevicePicker.swift — Cyclette
//  La finestra "Scegli il dispositivo" che compare quando tocchi Connetti Cyclette / Connetti Fascia Cardio.
//

import SwiftUI

struct DevicePicker: View {
    @ObservedObject var ble: BLEBridge

    private var list: [FoundDevice] {
        ble.found
            .filter { ble.showAll ? true : $0.matches }
            .sorted { ($0.matches ? 1 : 0, $0.rssi) > ($1.matches ? 1 : 0, $1.rssi) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let msg = ble.bluetoothMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                }
                Section {
                    if list.isEmpty {
                        Text("Nessun dispositivo per ora…")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(list) { d in
                        Button {
                            ble.choose(d)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: d.matches ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(d.matches ? Color.green : Color.secondary)
                                Text(d.name.isEmpty ? "Dispositivo senza nome" : d.name)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                SignalBars(rssi: d.rssi)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Ricerca in corso…")
                    }
                } footer: {
                    Text(ble.showAll
                         ? "Sono mostrati tutti i dispositivi Bluetooth vicini."
                         : "Se la cyclette o la fascia non compaiono: pedala qualche secondo, inumidisci gli elettrodi della fascia, oppure attiva «Mostra tutti i dispositivi».")
                }
                Section {
                    Toggle("Mostra tutti i dispositivi", isOn: $ble.showAll)
                }
            }
            .navigationTitle("Scegli il dispositivo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { ble.cancelPicker() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Tacche del segnale (più tacche = più vicino)
struct SignalBars: View {
    let rssi: Int
    private var level: Int { rssi >= -60 ? 4 : rssi >= -70 ? 3 : rssi >= -80 ? 2 : 1 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .frame(width: 4, height: CGFloat(4 + i * 3))
                    .opacity(i <= level ? 1 : 0.25)
            }
        }
        .foregroundStyle(Color.secondary)
    }
}
