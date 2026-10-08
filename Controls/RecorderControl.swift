import AppIntents
import SwiftUI
import WidgetKit

@main
struct RecorderControls: WidgetBundle {
    var body: some Widget { RecorderCameraControl() }
}

struct RecorderCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.tians.recorder.openCamera") {
            ControlWidgetButton(action: OpenCameraControlIntent()) {
                Label("开启相机", systemImage: "camera.fill")
            }
        }
        .displayName("畅游相机")
        .description("打开畅游的拍摄界面。")
    }
}
