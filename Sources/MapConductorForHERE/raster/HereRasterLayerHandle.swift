import heresdk
import MapConductorCore

final class HereRasterLayerHandle {
    let dataSource: RasterDataSource
    let layer: MapLayer
    let sourceName: String
    let layerName: String

    init(dataSource: RasterDataSource, layer: MapLayer, sourceName: String, layerName: String) {
        self.dataSource = dataSource
        self.layer = layer
        self.sourceName = sourceName
        self.layerName = layerName
    }
}
