import Combine
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereCircleController: CircleController<MapPolygon, HereCircleOverlayRenderer> {
    private var circleStatesById: [String: CircleState] = [:]
    private var circleSubscriptions: [String: AnyCancellable] = [:]

    init(mapView: MapView?) {
        let manager = CircleManager<MapPolygon>()
        let renderer = HereCircleOverlayRenderer(mapView: mapView)
        super.init(circleManager: manager, renderer: renderer)
    }

    func syncCircles(_ circles: [Circle]) {
        let newIds = Set(circles.map { $0.id })
        let oldIds = Set(circleStatesById.keys)
        var newStatesById: [String: CircleState] = [:]
        var shouldSyncList = oldIds != newIds

        for circle in circles {
            let state = circle.state
            if let existing = circleStatesById[state.id], existing !== state {
                circleSubscriptions[state.id]?.cancel()
                circleSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !circleManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        circleStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            circleSubscriptions[id]?.cancel()
            circleSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: circles.map { $0.state })
            }
        }

        for circle in circles {
            subscribeToCircle(circle.state)
        }
    }

    func handleTap(at position: GeoPoint) -> Bool {
        guard let hit = find(position: position) else { return false }
        dispatchClick(event: CircleEvent(state: hit.state, clicked: position))
        return true
    }

    private func subscribeToCircle(_ state: CircleState) {
        guard circleSubscriptions[state.id] == nil else { return }
        circleSubscriptions[state.id] = state.asFlow()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.circleStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        circleSubscriptions.values.forEach { $0.cancel() }
        circleSubscriptions.removeAll()
        circleStatesById.removeAll()
        renderer.unbind()
        destroy()
    }
}
