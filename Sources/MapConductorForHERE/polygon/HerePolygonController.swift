import Combine
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HerePolygonController: PolygonController<MapPolygon, HerePolygonOverlayRenderer> {
    private var polygonStatesById: [String: PolygonState] = [:]
    private var polygonSubscriptions: [String: AnyCancellable] = [:]

    init(mapView: MapView?) {
        let manager = PolygonManager<MapPolygon>()
        let renderer = HerePolygonOverlayRenderer(mapView: mapView)
        super.init(polygonManager: manager, renderer: renderer)
    }

    func syncPolygons(_ polygons: [Polygon]) {
        let newIds = Set(polygons.map { $0.id })
        let oldIds = Set(polygonStatesById.keys)
        var newStatesById: [String: PolygonState] = [:]
        var shouldSyncList = oldIds != newIds

        for polygon in polygons {
            let state = polygon.state
            if let existing = polygonStatesById[state.id], existing !== state {
                polygonSubscriptions[state.id]?.cancel()
                polygonSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !polygonManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        polygonStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            polygonSubscriptions[id]?.cancel()
            polygonSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: polygons.map { $0.state })
            }
        }

        for polygon in polygons {
            subscribeToPolygon(polygon.state)
        }
    }

    func handleTap(at position: GeoPoint) -> Bool {
        guard let hit = find(position: position) else { return false }
        dispatchClick(event: PolygonEvent(state: hit.state, clicked: position))
        return true
    }

    private func subscribeToPolygon(_ state: PolygonState) {
        guard polygonSubscriptions[state.id] == nil else { return }
        polygonSubscriptions[state.id] = state.asFlow()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.polygonStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        polygonSubscriptions.values.forEach { $0.cancel() }
        polygonSubscriptions.removeAll()
        polygonStatesById.removeAll()
        renderer.unbind()
        destroy()
    }
}
