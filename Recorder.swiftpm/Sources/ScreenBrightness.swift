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

// Covers this app window synchronously before the system captures its switcher
// snapshot. Foreground screenshots are untouched; no screenshot API is hooked.
@MainActor
struct ScreenPrivacyAnchor: UIViewRepresentable {
    let enabled: Bool
    func makeUIView(context: Context) -> PrivacyAnchorView { PrivacyAnchorView() }
    func updateUIView(_ view: PrivacyAnchorView, context: Context) {
        view.enabled = enabled
        view.reconcile()
    }
    static func dismantleUIView(_ view: PrivacyAnchorView, coordinator: ()) { view.removeCover() }
}

@MainActor
final class PrivacyAnchorView: UIView {
    var enabled = true
    private var cover: UIVisualEffectView?
    private var observers: [NSObjectProtocol] = []
    private var active = UIApplication.shared.applicationState == .active
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = false; self?.reconcile() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = true; self?.reconcile() }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func didMoveToWindow() { super.didMoveToWindow(); reconcile() }
    func reconcile() {
        guard ScreenPrivacyState.shouldCover(enabled: enabled, active: active), let window = window else {
            removeCover(); return
        }
        if let cover = cover, cover.superview === window { window.bringSubviewToFront(cover); return }
        removeCover()
        let surface = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
        surface.frame = window.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.94)
        let label = UILabel()
        label.text = "畅游 · 内容已隐藏"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.frame = surface.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.contentView.addSubview(label)
        window.addSubview(surface)
        cover = surface
    }
    func removeCover() { cover?.removeFromSuperview(); cover = nil }
}
