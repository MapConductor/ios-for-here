import CoreGraphics
import heresdk
import MapConductorCore

@MainActor
protocol HereMarkerEventControllerProtocol: AnyObject {
    func handleTap(at screenPoint: CGPoint) -> Bool
    func handleLongPress(state: GestureState, origin: Point2D) -> Bool
}

@MainActor
final class DefaultHereMarkerEventController: HereMarkerEventControllerProtocol {
    private weak var markerController: HereMarkerController?

    init(markerController: HereMarkerController) {
        self.markerController = markerController
    }

    func handleTap(at screenPoint: CGPoint) -> Bool {
        markerController?.handleTap(at: screenPoint) ?? false
    }

    func handleLongPress(state: GestureState, origin: Point2D) -> Bool {
        markerController?.handleLongPress(state: state, origin: origin) ?? false
    }
}
