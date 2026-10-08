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
    // Opening a playground renders its preview immediately. Do not construct a
    // capture session or request protected resources until the user starts it.
    @State private var recorder: RecorderController? = nil

    var body: some View {
        Group {
            if let recorder = recorder {
                ContentView(recorder: recorder)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "video.circle.fill")
                        .font(.system(size: 80)).foregroundColor(.red)
                    Text("随录").font(.largeTitle.bold())
                    Text("拍照 · Live Photo · 录像 · 内置图库").foregroundColor(.secondary)
                    Button {
                        recorder = RecorderController()
                    } label: {
                        Label("开启相机", systemImage: "camera.fill")
                            .font(.headline).padding(.horizontal, 24).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("开启后按提示授权，即可拍摄。内容先保存在内置图库。")
                        .font(.footnote).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .onAppear { handleLaunchRequest() }
        .onReceive(NotificationCenter.default.publisher(for: RecorderLaunchRequest.notification)) { _ in
            handleLaunchRequest()
        }
    }

    private func handleLaunchRequest() {
        if RecorderLaunchRequest.consume(), recorder == nil { recorder = RecorderController() }
    }
}
