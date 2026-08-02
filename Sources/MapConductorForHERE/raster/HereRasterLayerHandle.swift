import heresdk
import MapConductorCore

final class HereRasterLayerHandle {
    let dataSource: RasterDataSource
    let layer: MapLayer
    let sourceName: String
    let layerName: String
    /// `LocalTileServer` のルート ID。opacity プロキシ経由のときのみ非 nil。
    /// HERE SDK にはレイヤー単位の不透明度が無いため、opacity < 1 のときはローカル
    /// タイルサーバーでアルファ合成してから供給する（android-sdk と同一方式）。
    let routeId: String?

    init(
        dataSource: RasterDataSource,
        layer: MapLayer,
        sourceName: String,
        layerName: String,
        routeId: String?
    ) {
        self.dataSource = dataSource
        self.layer = layer
        self.sourceName = sourceName
        self.layerName = layerName
        self.routeId = routeId
    }
}
