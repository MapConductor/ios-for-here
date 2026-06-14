import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereRasterLayerOverlayRenderer: AbstractRasterLayerOverlayRenderer<HereRasterLayerHandle> {
    private static let defaultStorageLevels: [Int32] = Array(0...20).map(Int32.init)

    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    func unbind() {
        mapView = nil
    }

    override func createLayer(state: RasterLayerState) async -> HereRasterLayerHandle? {
        addLayer(state: state)
    }

    override func updateLayerProperties(
        layer: HereRasterLayerHandle,
        current: RasterLayerEntity<HereRasterLayerHandle>,
        prev: RasterLayerEntity<HereRasterLayerHandle>
    ) async -> HereRasterLayerHandle? {
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        if finger.source != prevFinger.source {
            removeHandle(layer)
            return addLayer(state: current.state)
        }
        if finger.debug != prevFinger.debug && current.state.debug {
            NSLog("[MapConductor] RasterLayer debug mode: id=%@", current.state.id)
        }
        layer.layer.setEnabled(current.state.visible)
        return layer
    }

    override func removeLayer(entity: RasterLayerEntity<HereRasterLayerHandle>) async {
        guard let handle = entity.layer else { return }
        removeHandle(handle)
    }

    private func addLayer(state: RasterLayerState) -> HereRasterLayerHandle? {
        guard let mapView else { return nil }
        guard let tileSpec = resolveTileSpec(state: state) else { return nil }

        let providerConfig = RasterDataSourceConfiguration.Provider(
            urlProvider: tileSpec.urlProvider,
            tilingScheme: .quadTreeMercator,
            storageLevels: tileSpec.storageLevels,
            hasAlphaChannel: true
        )
        let cache = RasterDataSourceConfiguration.Cache(path: cacheDirectoryPath())
        let config = RasterDataSourceConfiguration(
            name: tileSpec.sourceName,
            provider: providerConfig,
            cache: cache
        )
        let dataSource = RasterDataSource(context: mapView.mapContext, configuration: config)

        if state.debug {
            NSLog("[MapConductor] RasterLayer debug mode: id=%@", state.id)
        }
        do {
            let layer = try MapLayerBuilder()
                .withName(tileSpec.layerName)
                .withDataSource(named: tileSpec.sourceName, contentType: .rasterImage)
                .forMap(mapView.hereMap)
                .build()
            layer.setEnabled(state.visible)
            return HereRasterLayerHandle(
                dataSource: dataSource,
                layer: layer,
                sourceName: tileSpec.sourceName,
                layerName: tileSpec.layerName
            )
        } catch {
            NSLog("[MapConductor] HERE raster layer creation failed: %@", String(describing: error))
            return nil
        }
    }

    private func removeHandle(_ handle: HereRasterLayerHandle) {
        handle.layer.setEnabled(false)
    }

    private func resolveTileSpec(state: RasterLayerState) -> TileSpec? {
        let safeId = buildSafeId(state.id)
        switch state.source {
        case let .urlTemplate(template, _, minZoom, maxZoom, _, scheme):
            let urlProvider: TileUrlRequestHandler
            if scheme == .TMS {
                urlProvider = { x, y, level in
                    let max = Int32(1) << level
                    let tmsY = max - 1 - y
                    return template
                        .replacingOccurrences(of: "{x}", with: "\(x)")
                        .replacingOccurrences(of: "{y}", with: "\(tmsY)")
                        .replacingOccurrences(of: "{z}", with: "\(level)")
                }
            } else if let factoryProvider = TileUrlProviderFactory.fromXyzUrlTemplate(template) {
                urlProvider = factoryProvider
            } else {
                urlProvider = { x, y, level in
                    template
                        .replacingOccurrences(of: "{x}", with: "\(x)")
                        .replacingOccurrences(of: "{y}", with: "\(y)")
                        .replacingOccurrences(of: "{z}", with: "\(level)")
                }
            }
            let min = minZoom ?? 0
            let max = maxZoom ?? 20
            let levels = Array(min...max).map(Int32.init)
            return TileSpec(
                urlProvider: urlProvider,
                sourceName: "mapconductor-raster-source-\(safeId)",
                layerName: "mapconductor-raster-layer-\(safeId)",
                storageLevels: levels
            )

        case .tileJson:
            NSLog("[MapConductor] HERE SDK does not support TileJson raster sources.")
            return nil

        case let .arcGisService(serviceUrl):
            let base = serviceUrl.hasSuffix("/") ? String(serviceUrl.dropLast()) : serviceUrl
            let template = "\(base)/tile/{z}/{y}/{x}"
            guard let provider = TileUrlProviderFactory.fromXyzUrlTemplate(template) else { return nil }
            return TileSpec(
                urlProvider: provider,
                sourceName: "mapconductor-raster-source-\(safeId)",
                layerName: "mapconductor-raster-layer-\(safeId)",
                storageLevels: Self.defaultStorageLevels
            )
        }
    }

    private func cacheDirectoryPath() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheURL = url.appendingPathComponent("MapConductorHERERasterLayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return cacheURL.path
    }

    private func buildSafeId(_ id: String) -> String {
        var out = ""
        out.reserveCapacity(id.count)
        for ch in id {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out
    }

    private struct TileSpec {
        let urlProvider: TileUrlRequestHandler
        let sourceName: String
        let layerName: String
        let storageLevels: [Int32]
    }
}
