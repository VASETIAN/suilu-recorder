import AppIntents
import Foundation

// App shortcut registration requires an independently installed application.
// A Swift Playgrounds preview cannot register its own control-center app entry.
enum RecorderLaunchRequest {
    static let notification = Notification.Name("Recorder.openCamera")
    static func consume() -> Bool {
        let defaults = UserDefaults.standard
        let value = defaults.bool(forKey: "Recorder.openCamera.requested")
        defaults.removeObject(forKey: "Recorder.openCamera.requested")
        return value
    }
}

struct OpenRecorderCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "开启随心记相机"
    static var description = IntentDescription("在前台打开随心记的拍摄界面。")
    static var openAppWhenRun: Bool = true
    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "Recorder.openCamera.requested")
        NotificationCenter.default.post(name: RecorderLaunchRequest.notification, object: nil)
        return .result()
    }
}

struct RecorderAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenRecorderCameraIntent(),
                    phrases: ["开启\(.applicationName)相机", "打开\(.applicationName)"],
                    shortTitle: "开启相机", systemImageName: "camera.fill")
    }
}
