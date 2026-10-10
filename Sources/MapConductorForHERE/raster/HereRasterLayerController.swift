import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereRasterLayerController: RasterLayerController<HereRasterLayerHandle, HereRasterLayerOverlayRenderer> {
    private var sceneReady = false
    private var externalLayers: [String: RasterLayerState] = [:]

    override func upsert(state: RasterLayerState) async {
        externalLayers[state.id] = state
        // Installing a style can finish before HERE's initial scene load.
        // Keep its latest state until layers can be mounted on that scene.
        guard sceneReady else { return }
        await super.upsert(state: state)
    }

    override func removeById(_ id: String) async {
        externalLayers.removeValue(forKey: id)
        await super.removeById(id)
    }

    override func clear() async {
        externalLayers.removeAll()
        await super.clear()
    }

    func sceneWillLoad() { sceneReady = false }

    func sceneDidLoad() async {
        await super.clear()
        sceneReady = true
        for state in externalLayers.values.sorted(by: { $0.zIndex < $1.zIndex }) {
            await super.upsert(state: state)
        }
    }

    init(mapView: MapView?) {
        let manager = RasterLayerManager<HereRasterLayerHandle>()
        let renderer = HereRasterLayerOverlayRenderer(mapView: mapView)
        super.init(rasterLayerManager: manager, renderer: renderer)
    }

    func unbind() {
        renderer.unbind()
        destroy()
    }
}
