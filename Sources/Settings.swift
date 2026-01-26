import Foundation
import ServiceManagement

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private enum Keys {
        static let defaultPort = "defaultPort"
        static let persistServers = "persistServers"
        static let checkForUpdates = "checkForUpdates"
        static let launchAtLogin = "launchAtLogin"
    }
    
    @Published var defaultPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(defaultPort), forKey: Keys.defaultPort) }
    }
    
    @Published var persistServers: Bool {
        didSet { UserDefaults.standard.set(persistServers, forKey: Keys.persistServers) }
    }
    
    @Published var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: Keys.checkForUpdates) }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }
    
    private init() {
        let storedPort = UserDefaults.standard.integer(forKey: Keys.defaultPort)
        self.defaultPort = storedPort > 0 ? UInt16(storedPort) : 8080
        
        if UserDefaults.standard.object(forKey: Keys.persistServers) == nil {
            self.persistServers = true
        } else {
            self.persistServers = UserDefaults.standard.bool(forKey: Keys.persistServers)
        }
        
        if UserDefaults.standard.object(forKey: Keys.checkForUpdates) == nil {
            self.checkForUpdates = true
        } else {
            self.checkForUpdates = UserDefaults.standard.bool(forKey: Keys.checkForUpdates)
        }
        
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }
    
    private func updateLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }
    
    func syncLoginItemState() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            let isEnabled = status == .enabled
            if launchAtLogin != isEnabled {
                launchAtLogin = isEnabled
            }
        }
    }
}
