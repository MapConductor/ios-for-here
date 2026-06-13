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
    private var draggingMarkerId: String?
    private let defaultIcon: any MarkerIconProtocol = DefaultMarkerIcon()

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
    
    private func hitTest(at screenPoint: CGPoint) -> MarkerState? {
        guard let mapView else { return nil }
        let pixelScale = CGFloat(mapView.pixelScale)
        // Minimum hit target: 44pt expressed in physical pixels.
        let minHitPx: CGFloat = 44.0 * pixelScale
        
        var bestState: MarkerState?
        var bestDistance = CGFloat.infinity
        for entity in markerManager.allEntities() where entity.state.clickable {
            guard let p = mapView.geoToViewCoordinates(geoCoordinates: entity.state.position.toGeoCoordinates()) else { continue }

            let icon: any MarkerIconProtocol = entity.state.icon ?? defaultIcon
            // Rendered size in physical pixels: iconSize (pts) × scale × pixelScale.
            // Icons are square canvases; anchor is normalized (0–1).
            let renderedPx = max(icon.iconSize * icon.scale * pixelScale, minHitPx)

            let left = CGFloat(p.x) - icon.anchor.x * renderedPx
            let top  = CGFloat(p.y) - icon.anchor.y * renderedPx
            let hitRect = CGRect(x: left, y: top, width: renderedPx, height: renderedPx)

            guard hitRect.contains(screenPoint) else { continue }

            // Among overlapping markers prefer the one whose anchor is closest to the tap.
            let distance = hypot(screenPoint.x - CGFloat(p.x), screenPoint.y - CGFloat(p.y))
            if distance < bestDistance {
                bestDistance = distance
                bestState = entity.state
            }
        }
        return bestState
    }

    func handleTap(at screenPoint: CGPoint) -> Bool {
        guard let mapView else { return false }
        let bestState = hitTest(at: screenPoint)
        
        guard let bestState else { return false }
        dispatchClick(state: bestState)
        return true
    }
    

    /// Handles the HERE long-press gesture for marker dragging.
    /// Drag starts when the user long-presses a draggable marker (.begin),
    /// continues while the finger moves (.update), and ends on release (.end).
    func handleLongPress(state gestureState: GestureState, origin: Point2D) -> Bool {
        guard let mapView else { return false }

        switch gestureState {
        case .begin:
            guard let state = draggableMarkerState(at: origin) else { return false }
            draggingMarkerId = state.id
            mapView.gestures.disableDefaultAction(forGesture: .pan)
            dispatchDragStart(state: state)
            return true

        case .update:
            guard let markerId = draggingMarkerId,
                  let state = markerManager.getEntity(markerId)?.state,
                  let point = mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() else {
                return false
            }
            state.position = point
            dispatchDrag(state: state)
            return true

        case .end:
            guard let markerId = draggingMarkerId,
                  let state = markerManager.getEntity(markerId)?.state else {
                draggingMarkerId = nil
                return false
            }
            if let point = mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() {
                state.position = point
            }
            dispatchDragEnd(state: state)
            draggingMarkerId = nil
            mapView.gestures.enableDefaultAction(forGesture: .pan)
            return true

        case .cancel:
            let wasDragging = draggingMarkerId != nil
            draggingMarkerId = nil
            mapView.gestures.enableDefaultAction(forGesture: .pan)
            return wasDragging

        @unknown default:
            return draggingMarkerId != nil
        }
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
        draggingMarkerId = nil
        renderer.unbind()
        mapView = nil
        destroy()
    }

    private func draggableMarkerState(at origin: Point2D) -> MarkerState? {
        return hitTest(at: CGPoint(x: origin.x, y: origin.y))
    }
}
