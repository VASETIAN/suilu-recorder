import SwiftUI

extension View {
    @ViewBuilder
    func recorderGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
        #else
        // Older Playgrounds SDKs use the system material they can compile.
        background(.ultraThinMaterial, in: shape)
        #endif
    }
}

@MainActor @ViewBuilder
func recorderGlassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 8) { content() }
    } else {
        content()
    }
    #else
    content()
    #endif
}
