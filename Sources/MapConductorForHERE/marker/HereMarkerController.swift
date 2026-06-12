import Combine
import CoreGraphics
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereMarkerController: AbstractMarkerController<MapMarker, HereMarkerRenderer> {
    private weak var mapView: MapView?
    private var markerStatesById: [String: MarkerState] = [:]
    private var markerSubscriptions: [String: AnyCancellable] = [:]

    init(mapView: MapView?) {
        self.mapView = mapView
        let markerManager = MarkerManager<MapMarker>.defaultManager()
        let renderer = HereMarkerRenderer(mapView: mapView)
        super.init(markerManager: markerManager, renderer: renderer)
    }

    func syncMarkers(_ markers: [Marker]) {
        let newIds = Set(markers.map { $0.id })
        let oldIds = Set(markerStatesById.keys)
        var newStatesById: [String: MarkerState] = [:]
        var shouldSyncList = oldIds != newIds

        for marker in markers {
            let state = marker.state
            if let existing = markerStatesById[state.id], existing !== state {
                markerSubscriptions[state.id]?.cancel()
                markerSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !markerManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        markerStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            markerSubscriptions[id]?.cancel()
            markerSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: markers.map { $0.state })
            }
        }

        for marker in markers {
            subscribeToMarker(marker.state)
        }
    }

    func handleTap(at screenPoint: CGPoint) -> Bool {
        guard let mapView else { return false }
        var bestState: MarkerState?
        var bestDistance = CGFloat.infinity
        let hitRadius: CGFloat = 44.0

        for entity in markerManager.allEntities() where entity.state.clickable {
            guard let point = mapView.geoToViewCoordinates(geoCoordinates: entity.state.position.toGeoCoordinates()) else { continue }
            let distance = hypot(screenPoint.x - CGFloat(point.x), screenPoint.y - CGFloat(point.y))
            if distance < hitRadius, distance < bestDistance {
                bestDistance = distance
                bestState = entity.state
            }
        }

        guard let bestState else { return false }
        dispatchClick(state: bestState)
        return true
    }

    private func subscribeToMarker(_ state: MarkerState) {
        guard markerSubscriptions[state.id] == nil else { return }
        markerSubscriptions[state.id] = state.asFlow()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.markerStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        markerSubscriptions.values.forEach { $0.cancel() }
        markerSubscriptions.removeAll()
        markerStatesById.removeAll()
        renderer.unbind()
        mapView = nil
        destroy()
    }
}
