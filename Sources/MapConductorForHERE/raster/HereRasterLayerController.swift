import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereRasterLayerController: RasterLayerController<HereRasterLayerHandle, HereRasterLayerOverlayRenderer> {
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
