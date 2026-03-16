import SwiftUI

// Delegate для обработки жизненного цикла приложения
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Делаем приложение активным, чтобы оно перехватывало фокус и события клавиатуры,
        // так как оно запускается как raw executable (без .app бандла)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct VideoFastenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Можно добавить кастомные команды меню здесь
        }
    }
}
