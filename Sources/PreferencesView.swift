import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var portText: String = ""
    
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            } header: {
                Text("General")
            }
            
            Section {
                HStack {
                    Text("Default Port:")
                    TextField("8080", text: $portText)
                        .frame(width: 80)
                        .multilineTextAlignment(.center)
                        .onAppear {
                            portText = String(settings.defaultPort)
                        }
                        .onChange(of: portText) { newValue in
                            // Strip non-numeric characters
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue {
                                portText = filtered
                            }
                            // Validate range
                            if let port = UInt16(filtered), port >= 1024 {
                                settings.defaultPort = port
                            }
                        }
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Text("(1024–65535)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Toggle("Persist directory servers between restarts", isOn: $settings.persistServers)
            } header: {
                Text("Server")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 350)
        .onAppear {
            settings.syncLoginItemState()
        }
    }
}

#Preview {
    PreferencesView()
}
