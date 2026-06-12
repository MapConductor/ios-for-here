import Combine
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HerePolylineController: PolylineController<MapPolyline, HerePolylineOverlayRenderer> {
    private var polylineStatesById: [String: PolylineState] = [:]
    private var polylineSubscriptions: [String: AnyCancellable] = [:]

    init(mapView: MapView?) {
        let manager = PolylineManager<MapPolyline>()
        let renderer = HerePolylineOverlayRenderer(mapView: mapView)
        super.init(polylineManager: manager, renderer: renderer)
    }

    func syncPolylines(_ polylines: [Polyline]) {
        let newIds = Set(polylines.map { $0.id })
        let oldIds = Set(polylineStatesById.keys)
        var newStatesById: [String: PolylineState] = [:]
        var shouldSyncList = oldIds != newIds

        for polyline in polylines {
            let state = polyline.state
            if let existing = polylineStatesById[state.id], existing !== state {
                polylineSubscriptions[state.id]?.cancel()
                polylineSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !polylineManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        polylineStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            polylineSubscriptions[id]?.cancel()
            polylineSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: polylines.map { $0.state })
            }
        }

        for polyline in polylines {
            subscribeToPolyline(polyline.state)
        }
    }

    func handleTap(at position: GeoPoint) -> Bool {
        guard let hit = findWithClosestPoint(position: position) else { return false }
        dispatchClick(event: PolylineEvent(state: hit.entity.state, clicked: hit.closestPoint))
        return true
    }

    private func subscribeToPolyline(_ state: PolylineState) {
        guard polylineSubscriptions[state.id] == nil else { return }
        polylineSubscriptions[state.id] = state.asFlow()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.polylineStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        polylineSubscriptions.values.forEach { $0.cancel() }
        polylineSubscriptions.removeAll()
        polylineStatesById.removeAll()
        renderer.unbind()
        destroy()
    }
}
