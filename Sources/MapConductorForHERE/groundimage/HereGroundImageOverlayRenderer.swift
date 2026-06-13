import Foundation
import heresdk
import MapConductorCore

@MainActor
final class HereGroundImageOverlayRenderer: AbstractGroundImageOverlayRenderer<HereGroundImageHandle> {
    private static let storageLevels: [Int32] = Array(0...22).map(Int32.init)

    private weak var mapView: MapView?
    private let tileServer: LocalTileServer

    init(mapView: MapView?) {
        self.mapView = mapView
        self.tileServer = TileServerRegistry.get()
        super.init()
    }

    func unbind() {
        mapView = nil
    }

    override func createGroundImage(state: GroundImageState) async -> HereGroundImageHandle? {
        createGroundImageSync(state: state)
    }

    override func updateGroundImageProperties(
        groundImage: HereGroundImageHandle,
        current: GroundImageEntity<HereGroundImageHandle>,
        prev: GroundImageEntity<HereGroundImageHandle>
    ) async -> HereGroundImageHandle? {
        updateGroundImageSync(groundImage: groundImage, current: current, prev: prev)
    }

    override func removeGroundImage(entity: GroundImageEntity<HereGroundImageHandle>) async {
        removeGroundImageSync(entity: entity)
    }

    func createGroundImageSync(state: GroundImageState) -> HereGroundImageHandle? {
        let routeId = buildSafeRouteId(state.id)
        let provider = GroundImageTileProvider(tileSize: state.tileSize)
        provider.update(state: state, opacity: state.opacity)
        tileServer.register(routeId: routeId, provider: provider)

        guard let handle = createHandle(
            routeId: routeId,
            generation: 0,
            cacheKey: tileCacheKey(state),
            provider: provider
        ) else {
            tileServer.unregister(routeId: routeId)
            return nil
        }

        handle.layer.setEnabled(true)
        return handle
    }

    func updateGroundImageSync(
        groundImage: HereGroundImageHandle,
        current: GroundImageEntity<HereGroundImageHandle>,
        prev: GroundImageEntity<HereGroundImageHandle>
    ) -> HereGroundImageHandle? {
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        let tileNeedsRefresh = finger.bounds != prevFinger.bounds
            || finger.image != prevFinger.image
            || finger.opacity != prevFinger.opacity
            || finger.tileSize != prevFinger.tileSize

        guard tileNeedsRefresh else { return groundImage }

        let provider: GroundImageTileProvider
        if finger.tileSize != prevFinger.tileSize {
            provider = GroundImageTileProvider(tileSize: current.state.tileSize)
            tileServer.register(routeId: groundImage.routeId, provider: provider)
        } else {
            provider = groundImage.tileProvider
        }
        provider.update(state: current.state, opacity: current.state.opacity)

        let nextGeneration = groundImage.generation + 1
        removeHandle(groundImage)
        guard let nextHandle = createHandle(
            routeId: groundImage.routeId,
            generation: nextGeneration,
            cacheKey: tileCacheKey(current.state),
            provider: provider
        ) else {
            groundImage.layer.setEnabled(true)
            return groundImage
        }

        nextHandle.layer.setEnabled(true)
        return nextHandle
    }

    func removeGroundImageSync(entity: GroundImageEntity<HereGroundImageHandle>) {
        guard let handle = entity.groundImage else { return }
        removeHandle(handle)
        tileServer.unregister(routeId: handle.routeId)
    }

    private func createHandle(
        routeId: String,
        generation: Int64,
        cacheKey: String,
        provider: GroundImageTileProvider
    ) -> HereGroundImageHandle? {
        guard let mapView else { return nil }

        let tileTemplate = tileServer.urlTemplate(routeId: routeId, tileSize: provider.tileSize, cacheKey: cacheKey)
        guard let urlProvider = TileUrlProviderFactory.fromXyzUrlTemplate(tileTemplate) else { return nil }

        let providerConfig = RasterDataSourceConfiguration.Provider(
            urlProvider: urlProvider,
            tilingScheme: .quadTreeMercator,
            storageLevels: Self.storageLevels,
            hasAlphaChannel: true
        )
        let cache = RasterDataSourceConfiguration.Cache(path: cacheDirectoryPath())

        let sourceName = "mapconductor-groundimage-source-\(routeId)-\(generation)"
        let layerName = "mapconductor-groundimage-layer-\(routeId)-\(generation)"
        let config = RasterDataSourceConfiguration(name: sourceName, provider: providerConfig, cache: cache)
        let dataSource = RasterDataSource(context: mapView.mapContext, configuration: config)

        do {
            let layer = try MapLayerBuilder()
                .withName(layerName)
                .withDataSource(named: sourceName, contentType: .rasterImage)
                .forMap(mapView.hereMap)
                .build()

            return HereGroundImageHandle(
                routeId: routeId,
                generation: generation,
                cacheKey: cacheKey,
                sourceName: sourceName,
                layerName: layerName,
                dataSource: dataSource,
                layer: layer,
                tileProvider: provider
            )
        } catch {
            NSLog("[MapConductor] HERE ground image layer creation failed: %@", String(describing: error))
            return nil
        }
    }

    private func removeHandle(_ handle: HereGroundImageHandle) {
        handle.layer.setEnabled(false)
    }

    private func cacheDirectoryPath() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheURL = url.appendingPathComponent("MapConductorHEREGroundImage", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return cacheURL.path
    }

    private func buildSafeRouteId(_ id: String) -> String {
        var out = "groundimage-"
        for ch in id {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out
    }

    private func tileCacheKey(_ state: GroundImageState) -> String {
        let finger = state.fingerPrint()
        return "\(finger.bounds)-\(finger.image)-\(finger.opacity)-\(finger.tileSize)-\(finger.extra)"
    }
}
