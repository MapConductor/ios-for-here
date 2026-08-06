import Foundation
import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HereRasterLayerOverlayRenderer: AbstractRasterLayerOverlayRenderer<HereRasterLayerHandle> {
    private static let defaultStorageLevels: [Int32] = Array(0...20).map(Int32.init)

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

        // HERE にはレイヤー単位の不透明度が無く、opacity はプロキシタイルへ焼き込む。
        // そのため source だけでなく opacity が変わったときもレイヤーを作り直す
        // （android-sdk の onChange と同一条件）。
        if finger.source != prevFinger.source || finger.opacity != prevFinger.opacity {
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

        // ローカルタイルサーバーへプロキシするかどうか。HERE の `RasterDataSource` は
        // レイヤー不透明度もリクエストヘッダの差し替えも受け付けないので、どちらかが
        // 要るときだけ自前で取りに行く経路に切り替える。
        let routeId: String? = needsProxy(state) ? "here-raster-\(buildSafeId(state.id))" : nil
        if let routeId {
            tileServer.register(routeId: routeId, provider: HereRasterTileProxyProvider(state: state))
        }

        guard let tileSpec = resolveTileSpec(state: state, routeId: routeId) else {
            if let routeId { tileServer.unregister(routeId: routeId) }
            NSLog("[MapConductor] HERE resolveTileSpec returned nil for id=%@", state.id)
            return nil
        }

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
                layerName: tileSpec.layerName,
                routeId: routeId
            )
        } catch {
            if let routeId { tileServer.unregister(routeId: routeId) }
            NSLog("[MapConductor] HERE raster layer creation failed: %@", String(describing: error))
            return nil
        }
    }

    private func removeHandle(_ handle: HereRasterLayerHandle) {
        handle.layer.setEnabled(false)
        if let routeId = handle.routeId {
            tileServer.unregister(routeId: routeId)
        }
    }

    private func resolveTileSpec(state: RasterLayerState, routeId: String?) -> TileSpec? {
        let safeId = buildSafeId(state.id)
        let sourceName = "mapconductor-raster-source-\(safeId)"
        let layerName = "mapconductor-raster-layer-\(safeId)"

        switch state.source {
        case let .urlTemplate(_, tileSize, minZoom, maxZoom, _, _):
            // プロキシ経由ならローカルサーバーの XYZ テンプレート、そうでなければ
            // リモートのテンプレートを直接 HERE に供給する。
            guard let urlProvider = makeUrlProvider(state: state, routeId: routeId, tileSize: tileSize) else {
                return nil
            }
            let min = minZoom ?? 0
            let max = maxZoom ?? 20
            let levels = Array(min...max).map(Int32.init)
            return TileSpec(
                urlProvider: urlProvider,
                sourceName: sourceName,
                layerName: layerName,
                storageLevels: levels
            )

        case .tileJson:
            NSLog("[MapConductor] HERE SDK does not support TileJson raster sources.")
            return nil

        case .arcGisService:
            let urlProvider = makeUrlProvider(
                state: state,
                routeId: routeId,
                tileSize: RasterSource.defaultTileSize
            )
            guard let urlProvider else { return nil }
            return TileSpec(
                urlProvider: urlProvider,
                sourceName: sourceName,
                layerName: layerName,
                storageLevels: Self.defaultStorageLevels
            )
        }
    }

    /// HERE に渡す `TileUrlRequestHandler` を作る。プロキシ経由のときはローカル
    /// タイルサーバーの XYZ テンプレート、そうでなければリモートテンプレート
    /// （XYZ は factory、TMS/その他は手動置換）を用いる。android-sdk と同一。
    private func makeUrlProvider(
        state: RasterLayerState,
        routeId: String?,
        tileSize: Int
    ) -> TileUrlRequestHandler? {
        if let routeId {
            let template = tileServer.urlTemplate(
                routeId: routeId,
                tileSize: tileSize,
                cacheKey: String(state.fingerPrint().hashValue)
            )
            return TileUrlProviderFactory.fromXyzUrlTemplate(template)
        }

        switch state.source {
        case let .urlTemplate(template, _, _, _, _, scheme):
            if scheme == .TMS {
                return { x, y, level in
                    let maxIndex = (Int32(1) << level) - 1
                    let tmsY = maxIndex - y
                    return template
                        .replacingOccurrences(of: "{x}", with: "\(x)")
                        .replacingOccurrences(of: "{y}", with: "\(tmsY)")
                        .replacingOccurrences(of: "{z}", with: "\(level)")
                }
            }
            if let factoryProvider = TileUrlProviderFactory.fromXyzUrlTemplate(template) {
                return factoryProvider
            }
            return { x, y, level in
                template
                    .replacingOccurrences(of: "{x}", with: "\(x)")
                    .replacingOccurrences(of: "{y}", with: "\(y)")
                    .replacingOccurrences(of: "{z}", with: "\(level)")
            }
        case let .arcGisService(serviceUrl):
            let base = serviceUrl.hasSuffix("/") ? String(serviceUrl.dropLast()) : serviceUrl
            return TileUrlProviderFactory.fromXyzUrlTemplate("\(base)/tile/{z}/{y}/{x}")
        case .tileJson:
            return nil
        }
    }

    /// プロキシ経由が必要か。
    ///
    /// プロキシは 1 ホップ増えるぶん確実に遅くなるので、必要なときだけ通す。
    /// `userAgent` が既定値のままなら「利用者が指定した」とは見なさない
    /// （既定値は空ではないため、これを指定扱いにすると全レイヤがプロキシ経由になる）。
    private func needsProxy(_ state: RasterLayerState) -> Bool {
        if min(max(state.opacity, 0.0), 1.0) < 0.999 { return true }
        if let headers = state.extraHeaders, !headers.isEmpty { return true }
        let ua = state.userAgent?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if let ua, !ua.isEmpty, ua != RasterLayerState.defaultUserAgent { return true }
        return false
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

/// HERE にはレイヤー不透明度が無いため、リモートタイルを取得してアルファを焼き込んだ
/// PNG を返すローカルタイルサーバー用プロバイダー。android-sdk の
/// `HereRasterTileProxyProvider` を iOS へ移植したもの。
///
/// `renderTile` はタイルサーバーの背景キューから呼ばれるため `@MainActor` にせず、
/// 生成時に必要な値（source / opacity / userAgent / extraHeaders）を不変で取り込む。
private final class HereRasterTileProxyProvider: TileProvider {
    private let source: RasterSource
    private let opacity: Double
    private let userAgent: String?
    private let extraHeaders: [String: String]?

    private let cacheLock = NSLock()
    private let fetchCache = NSCache<NSString, NSData>()

    @MainActor
    init(state: RasterLayerState) {
        self.source = state.source
        self.opacity = state.opacity
        self.userAgent = state.userAgent
        self.extraHeaders = state.extraHeaders
        fetchCache.totalCostLimit = Self.fetchCacheSizeBytes
    }

    func renderTile(request: TileRequest) -> Data? {
        guard let url = resolveUrl(request) else { return nil }
        guard let bytes = fetch(url) else { return nil }
        return applyOpacity(bytes, opacity: opacity)
    }

    private func resolveUrl(_ request: TileRequest) -> String? {
        switch source {
        case let .urlTemplate(template, _, _, _, _, scheme):
            let y = scheme == .TMS ? (1 << request.z) - 1 - request.y : request.y
            return template
                .replacingOccurrences(of: "{x}", with: "\(request.x)")
                .replacingOccurrences(of: "{y}", with: "\(y)")
                .replacingOccurrences(of: "{z}", with: "\(request.z)")
        case let .arcGisService(serviceUrl):
            let base = serviceUrl.hasSuffix("/") ? String(serviceUrl.dropLast()) : serviceUrl
            return "\(base)/tile/\(request.z)/\(request.y)/\(request.x)"
        case .tileJson:
            return nil
        }
    }

    private func fetch(_ url: String) -> Data? {
        let key = url as NSString
        cacheLock.lock()
        if let cached = fetchCache.object(forKey: key) {
            cacheLock.unlock()
            return cached as Data
        }
        cacheLock.unlock()

        guard let requestUrl = URL(string: url) else { return nil }
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 15
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        extraHeaders?.forEach { key, value in request.setValue(value, forHTTPHeaderField: key) }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let data
            else { return }
            resultData = data
        }
        task.resume()
        semaphore.wait()

        if let resultData {
            cacheLock.lock()
            fetchCache.setObject(resultData as NSData, forKey: key, cost: resultData.count)
            cacheLock.unlock()
        }
        return resultData
    }

    private func applyOpacity(_ bytes: Data, opacity: Double) -> Data? {
        let safeOpacity = min(max(opacity, 0.0), 1.0)
        if safeOpacity >= 0.999 {
            return bytes
        }
        guard let image = UIImage(data: bytes) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let output = renderer.image { _ in
            image.draw(
                in: CGRect(origin: .zero, size: image.size),
                blendMode: .normal,
                alpha: CGFloat(safeOpacity)
            )
        }
        return output.pngData()
    }

    private static let fetchCacheSizeBytes = 16 * 1024 * 1024
}
