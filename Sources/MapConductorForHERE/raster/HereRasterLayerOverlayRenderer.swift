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

        // Tiles this process draws are handed over in process. HERE fetches
        // through its own network stack and, while the device reports no
        // connectivity, does not fetch at all -- not even from 127.0.0.1 --
        // so a URL-fed source goes blank the moment the network is away. A
        // tile source is asked for bytes and answered from the same
        // providers, with no network in between.
        let dataSource: RasterDataSource
        if let localTemplate = tileSpec.localTemplate {
            dataSource = RasterDataSource(
                context: mapView.mapContext,
                name: tileSpec.sourceName,
                tileSource: LocalRasterTileSource(
                    tileServer: tileServer,
                    template: localTemplate,
                    storageLevels: tileSpec.storageLevels
                )
            )
        } else {
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
            dataSource = RasterDataSource(context: mapView.mapContext, configuration: config)
        }

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
        // The old handle is still alive while onChange builds its successor.
        // Reusing its native names makes HERE resolve the old source, then
        // remove the replacement when that old handle is released. Each
        // native instance needs its own names; the logical state id stays stable.
        let instance = UUID().uuidString
        let sourceName = "mapconductor-raster-source-\(safeId)-\(instance)"
        let layerName = "mapconductor-raster-layer-\(safeId)-\(instance)"

        switch state.source {
        case let .urlTemplate(template, tileSize, minZoom, maxZoom, _, scheme):
            // プロキシ経由ならローカルサーバーの XYZ テンプレート、そうでなければ
            // リモートのテンプレートを直接 HERE に供給する。
            guard let urlProvider = makeUrlProvider(state: state, routeId: routeId, tileSize: tileSize) else {
                return nil
            }
            let min = minZoom ?? 0
            let max = maxZoom ?? 20
            let levels = Array(min...max).map(Int32.init)
            // The proxy route is local by construction; a direct template is
            // local when it is one of the server's own.
            let localTemplate: String?
            if let routeId {
                localTemplate = tileServer.urlTemplate(
                    routeId: routeId,
                    tileSize: tileSize,
                    cacheKey: String(state.fingerPrint().hashValue)
                )
            } else if scheme != .TMS, template.hasPrefix(tileServer.baseUrl + "/") {
                localTemplate = template
            } else {
                localTemplate = nil
            }
            return TileSpec(
                urlProvider: urlProvider,
                sourceName: sourceName,
                layerName: layerName,
                storageLevels: levels,
                localTemplate: localTemplate
            )

        case .tileJson:
            NSLog("[MapConductor] HERE SDK does not support TileJson raster sources.")
            return nil

        case .arcGisService:
            let urlProvider = makeUrlProvider(
                state: state,
                routeId: routeId,
                tileSize: RasterLayerSource.defaultTileSize
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
        /// The XYZ template on this process's tile server, when the tiles come from there.
        var localTemplate: String? = nil
    }
}

/// HERE にはレイヤー不透明度が無いため、リモートタイルを取得してアルファを焼き込んだ
/// PNG を返すローカルタイルサーバー用プロバイダー。android-sdk の
/// `HereRasterTileProxyProvider` を iOS へ移植したもの。
///
/// `renderTile` はタイルサーバーの背景キューから呼ばれるため `@MainActor` にせず、
/// 生成時に必要な値（source / opacity / userAgent / extraHeaders）を不変で取り込む。
private final class HereRasterTileProxyProvider: TileProvider {
    private let source: RasterLayerSource
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

/// A HERE tile source answered from this process's tile server, with no HTTP
/// hop and no dependence on the device's connectivity.
private final class LocalRasterTileSource: RasterTileSource {
    private let tileServer: LocalTileServer
    private let template: String
    let storageLevels: [Int32]
    let tilingScheme: TilingScheme = .quadTreeMercator

    /// Renders block on the server's gate, so they run off HERE's threads --
    /// and on a few of them only. HERE asks for a screenful at once, and a
    /// thread per request parked on the gate is how a process runs out of
    /// GCD threads and stops answering touches.
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MapConductorForHERE.localTile"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 8
        return queue
    }()

    init(tileServer: LocalTileServer, template: String, storageLevels: [Int32]) {
        self.tileServer = tileServer
        self.template = template
        self.storageLevels = storageLevels
    }

    func getDataVersion(tileKey: TileKey) -> TileSourceDataVersion { Self.version }

    func addDelegate(_ delegate: any TileSourceDelegate) {}

    func removeDelegate(_ delegate: any TileSourceDelegate) {}

    func loadTile(
        tileKey: TileKey,
        completionHandler: any RasterTileSourceLoadResultHandler
    ) -> (any TileSourceLoadTileRequestHandle)? {
        // Exactly one answer per request, whatever happens. A request HERE
        // cancels is still one it is waiting on: leave it unanswered and the
        // slot is never freed, and after a few gestures HERE stops asking for
        // tiles at all -- the map keeps the last picture and looks frozen.
        let request = Request(tileKey: tileKey, handler: completionHandler)
        // HERE counts rows from the south (Tokyo at z12 is row 2483, not
        // 1612); the templates count from the north, as XYZ does.
        let row = (Int32(1) << tileKey.level) - 1 - tileKey.y
        let urlText = template
            .replacingOccurrences(of: "{z}", with: "\(tileKey.level)")
            .replacingOccurrences(of: "{x}", with: "\(tileKey.x)")
            .replacingOccurrences(of: "{y}", with: "\(row)")
        let server = tileServer
        Self.workers.addOperation {
            guard !request.isCancelled, let url = URL(string: urlText) else {
                request.answer(nil)
                return
            }
            request.answer(server.renderLocalTile(url: url) { request.isCancelled })
        }
        return request
    }

    /// One tile HERE is waiting on, answered once.
    private final class Request: TileSourceLoadTileRequestHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        private var cancelled = false
        private let tileKey: TileKey
        private let handler: any RasterTileSourceLoadResultHandler

        init(tileKey: TileKey, handler: any RasterTileSourceLoadResultHandler) {
            self.tileKey = tileKey
            self.handler = handler
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        /// A failure is a failure, never an empty tile: HERE keeps a picture
        /// and asks no more, but retries a failure.
        func answer(_ data: Data?) {
            lock.lock()
            if answered { lock.unlock(); return }
            answered = true
            lock.unlock()
            if let data {
                handler.loaded(tileKey: tileKey, data: data, metadata: LocalRasterTileSource.metadata)
            } else {
                handler.failed(tileKey)
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            // Off HERE's own cancelling thread, and off the render queue,
            // which a burst of gestures has already filled.
            DispatchQueue.global(qos: .utility).async { [self] in answer(nil) }
        }
    }

    fileprivate static let version = TileSourceDataVersion(majorVersion: 0, minorVersion: 0)
    /// Tiles drawn here change only with their URL, so they are given a long
    /// life -- but a plausible one. A date at the end of time does not
    /// survive the trip into the SDK: every tile comes back already expired,
    /// the same one is asked for again every 400 ms, and after a pinch the
    /// map stops asking for tiles at all (seen on android, same SDK core).
    fileprivate static let metadata = TileSourceTileMetadata(
        dataVersion: version,
        dataExpiryTimestamp: Date(timeIntervalSinceNow: 10 * 365 * 24 * 60 * 60)
    )

}
