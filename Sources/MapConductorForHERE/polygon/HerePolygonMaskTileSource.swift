import Foundation
import heresdk
import MapConductorCore
import UIKit

/// 穴付きポリゴンの「塗り」をラスタタイルとして供給する HERE 用カスタムタイルソース。
///
/// HERE SDK は MapPolygon の inner boundaries（穴）を確実に描画しないため
/// （android-for-here と同じ判断）、塗りはコア共通の `PolygonRasterTileRenderer` で
/// タイル画像として生成し、`RasterTileSource` として HERE のカスタムラスタレイヤに直結する。
/// Android のローカル HTTP タイルサーバ + URL キャッシュバスティング方式と異なり、
/// 形状変更時は `TileSourceDelegate.onDataVersionChanged` でデータバージョンを上げて
/// HERE に再取得させる（レイヤ・データソースの再生成が不要でリークもちらつきもない）。
final class HerePolygonMaskTileSource: NSObject, RasterTileSource {
    private let renderer: PolygonRasterTileRenderer

    private let lock = NSLock()
    private var delegates: [any TileSourceDelegate] = []
    private var version: Int32 = 0

    init(tileSize: Int = 256) {
        self.renderer = PolygonRasterTileRenderer(tileSize: tileSize)
        super.init()
    }

    /// マスクの形状・塗り色を更新し、データバージョンを上げて再取得を促す。
    func update(points: [GeoPointProtocol], holes: [[GeoPointProtocol]], fillColor: UIColor, geodesic: Bool) {
        renderer.update(points: points, holes: holes, fillColor: fillColor, geodesic: geodesic)
        lock.lock()
        version += 1
        let newVersion = TileSourceDataVersion(majorVersion: version, minorVersion: 0)
        let currentDelegates = delegates
        lock.unlock()
        currentDelegates.forEach { $0.onDataVersionChanged(newVersion) }
    }

    // MARK: - RasterTileSource

    var tilingScheme: TilingScheme { .quadTreeMercator }

    var storageLevels: [Int32] { Array(0...20) }

    func getDataVersion(tileKey: TileKey) -> TileSourceDataVersion {
        lock.lock()
        defer { lock.unlock() }
        return TileSourceDataVersion(majorVersion: version, minorVersion: 0)
    }

    func addDelegate(_ delegate: any TileSourceDelegate) {
        lock.lock()
        defer { lock.unlock() }
        delegates.append(delegate)
    }

    func removeDelegate(_ delegate: any TileSourceDelegate) {
        lock.lock()
        defer { lock.unlock() }
        delegates.removeAll { $0 === delegate }
    }

    func loadTile(
        tileKey: TileKey,
        completionHandler: any RasterTileSourceLoadResultHandler
    ) -> (any TileSourceLoadTileRequestHandle)? {
        // HERE の quadTreeMercator TileKey は y 原点が南（TMS 系）。コアのタイルレンダラは
        // XYZ（y 原点が北）なので反転する（反転しないとマスクが南北鏡像の緯度に描かれる）。
        let worldTileCount = 1 << Int(tileKey.level)
        let xyzY = worldTileCount - 1 - Int(tileKey.y)
        let request = TileRequest(x: Int(tileKey.x), y: xyzY, z: Int(tileKey.level))
        guard let data = renderer.renderTile(request: request) else {
            completionHandler.failed(tileKey)
            return HerePolygonMaskTileRequestHandle()
        }
        lock.lock()
        let currentVersion = TileSourceDataVersion(majorVersion: version, minorVersion: 0)
        lock.unlock()
        completionHandler.loaded(
            tileKey: tileKey,
            data: data,
            metadata: TileSourceTileMetadata(
                dataVersion: currentVersion,
                dataExpiryTimestamp: Date.distantFuture
            )
        )
        return HerePolygonMaskTileRequestHandle()
    }
}

private final class HerePolygonMaskTileRequestHandle: TileSourceLoadTileRequestHandle {
    // タイル生成は同期的に完了するためキャンセルは何もしない。
    func cancel() {}
}
