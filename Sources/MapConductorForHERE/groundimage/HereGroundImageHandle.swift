import heresdk
import MapConductorCore

public final class HereGroundImageHandle {
    let routeId: String
    let generation: Int64
    let cacheKey: String
    let sourceName: String
    let layerName: String
    let dataSource: RasterDataSource
    let layer: MapLayer
    let tileProvider: GroundImageTileProvider

    init(
        routeId: String,
        generation: Int64,
        cacheKey: String,
        sourceName: String,
        layerName: String,
        dataSource: RasterDataSource,
        layer: MapLayer,
        tileProvider: GroundImageTileProvider
    ) {
        self.routeId = routeId
        self.generation = generation
        self.cacheKey = cacheKey
        self.sourceName = sourceName
        self.layerName = layerName
        self.dataSource = dataSource
        self.layer = layer
        self.tileProvider = tileProvider
    }
}
