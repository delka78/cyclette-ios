//
//  ContentView.swift — Cyclette
//

import SwiftUI

/// Indirizzo della web app (GitHub Pages). Gli aggiornamenti si fanno sempre caricando index.html su GitHub:
/// l'app iPhone non va ricompilata.
enum AppConfig {
    static let url = URL(string: "https://delka78.github.io/")!
}

struct ContentView: View {
    @StateObject private var ble = BLEBridge()

    var body: some View {
        WebView(url: AppConfig.url, ble: ble)
            .ignoresSafeArea()
            .background(Color(red: 0.043, green: 0.059, blue: 0.078).ignoresSafeArea())
            .sheet(isPresented: $ble.pickerVisible, onDismiss: { ble.pickerDismissed() }) {
                DevicePicker(ble: ble)
            }
            .preferredColorScheme(.dark)
    }
}
