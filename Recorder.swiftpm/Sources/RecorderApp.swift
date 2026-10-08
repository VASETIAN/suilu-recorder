import SwiftUI

@main
@MainActor
struct RecorderApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderLaunchView()
                .preferredColorScheme(.dark)
                .tint(.red)
        }
    }
}

@MainActor
private struct RecorderLaunchView: View {
    // Construct after SwiftUI mounts the launch view. Static Xcode previews
    // stay opt-in, while a running app opens the camera directly.
    @State private var recorder: RecorderController? = nil

    var body: some View {
        Group {
            if let recorder = recorder {
                ContentView(recorder: recorder)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                        Button("预览相机") { recorder = RecorderController() }.buttonStyle(.borderedProminent)
                    } else { ProgressView("正在打开相机…").tint(.white) }
                }
            }
        }
        .task {
            if recorder == nil && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                recorder = RecorderController()
            }
            handleLaunchRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecorderLaunchRequest.notification)) { _ in
            handleLaunchRequest()
        }
    }

    private func handleLaunchRequest() {
        if RecorderLaunchRequest.consume(), recorder == nil { recorder = RecorderController() }
    }
}
