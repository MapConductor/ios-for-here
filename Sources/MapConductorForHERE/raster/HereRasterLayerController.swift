import Combine
import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereRasterLayerController: RasterLayerController<HereRasterLayerHandle, HereRasterLayerOverlayRenderer> {
    private var rasterSubscriptions: [String: AnyCancellable] = [:]
    private var rasterStatesById: [String: RasterLayerState] = [:]

    init(mapView: MapView?) {
        let manager = RasterLayerManager<HereRasterLayerHandle>()
        let renderer = HereRasterLayerOverlayRenderer(mapView: mapView)
        super.init(rasterLayerManager: manager, renderer: renderer)
    }

    func syncRasterLayers(_ layers: [RasterLayer]) {
        let newIds = Set(layers.map { $0.id })
        let oldIds = Set(rasterStatesById.keys)
        var newStatesById: [String: RasterLayerState] = [:]
        var shouldSyncList = oldIds != newIds

        for layer in layers {
            let state = layer.state
            if let existing = rasterStatesById[state.id], existing !== state {
                rasterSubscriptions[state.id]?.cancel()
                rasterSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !rasterLayerManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        rasterStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            rasterSubscriptions[id]?.cancel()
            rasterSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: layers.map { $0.state })
            }
        }

        for layer in layers {
            subscribeToRasterLayer(layer.state)
        }
    }

    private func subscribeToRasterLayer(_ state: RasterLayerState) {
        guard rasterSubscriptions[state.id] == nil else { return }
        rasterSubscriptions[state.id] = state.asFlow()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.rasterStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        rasterSubscriptions.values.forEach { $0.cancel() }
        rasterSubscriptions.removeAll()
        rasterStatesById.removeAll()
        renderer.unbind()
        destroy()
    }
}
