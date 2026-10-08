import SwiftUI
import UIKit

@MainActor
final class ScreenBrightness: ObservableObject {
    private var previous: CGFloat?
    func dim() {
        if previous == nil { previous = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
    }
    func restore() {
        guard let previous = previous else { return }
        UIScreen.main.brightness = previous
        self.previous = nil
    }
}
