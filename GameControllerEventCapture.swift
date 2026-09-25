import GameController
import SwiftUI
import UIKit

/// iPadOS 26 can use a game controller to navigate the system UI. A window
/// only gets raw controller input through GameController once a view in it
/// declares that it handles gamepad events with `GCEventInteraction`.
struct GameControllerEventCapture: UIViewRepresentable {
    func makeUIView(context: Context) -> CaptureView {
        CaptureView()
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {}

    final class CaptureView: UIView {
        private let interaction: GCEventInteraction = {
            let interaction = GCEventInteraction()
            interaction.handledEventTypes = .gamepad
            return interaction
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            // Attach to the window so the whole screen claims controller input,
            // not just this invisible background view.
            interaction.view?.removeInteraction(interaction)
            window?.addInteraction(interaction)
        }
    }
}
