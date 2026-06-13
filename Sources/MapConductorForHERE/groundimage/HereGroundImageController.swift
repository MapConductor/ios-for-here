import Combine
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereGroundImageController: GroundImageController<HereGroundImageHandle, HereGroundImageOverlayRenderer> {
    private var groundImageStatesById: [String: GroundImageState] = [:]
    private var groundImageSubscriptions: [String: AnyCancellable] = [:]

    init(mapView: MapView?) {
        let manager = GroundImageManager<HereGroundImageHandle>()
        let renderer = HereGroundImageOverlayRenderer(mapView: mapView)
        super.init(groundImageManager: manager, renderer: renderer)
    }

    func syncGroundImages(_ groundImages: [GroundImage]) {
        let newIds = Set(groundImages.map { $0.id })
        let oldIds = Set(groundImageStatesById.keys)
        var newStatesById: [String: GroundImageState] = [:]
        var shouldSyncList = false

        for groundImage in groundImages {
            let state = groundImage.state
            if let existingState = groundImageStatesById[state.id], existingState !== state {
                groundImageSubscriptions[state.id]?.cancel()
                groundImageSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !groundImageManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        if oldIds != newIds {
            shouldSyncList = true
        }

        groundImageStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            groundImageSubscriptions[id]?.cancel()
            groundImageSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: groundImages.map { $0.state })
            }
        }

        for groundImage in groundImages {
            subscribeToGroundImage(groundImage.state)
        }
    }

    func handleTap(at point: GeoPoint) -> Bool {
        guard let hit = find(position: point) else { return false }
        let event = GroundImageEvent(state: hit.state, clicked: point)
        dispatchClick(event: event)
        return true
    }

    private func subscribeToGroundImage(_ state: GroundImageState) {
        guard groundImageSubscriptions[state.id] == nil else { return }
        groundImageSubscriptions[state.id] = state.asFlow()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.groundImageStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.update(state: state)
                }
            }
    }

    func unbind() {
        groundImageSubscriptions.values.forEach { $0.cancel() }
        groundImageSubscriptions.removeAll()
        groundImageStatesById.removeAll()
        renderer.unbind()
        destroy()
    }
}
