import Foundation
import heresdk
import MapConductorCore
import UIKit

/// HERE の穴付きポリゴンは「ラスタタイルマスク方式」で描画する（android-for-here と同方式）。
///
/// 実機検証の結果、HERE iOS SDK の MapPolygon は
/// - `GeoPolygon(vertices:innerBoundaries:)` の穴を描画で正しく抜かない
///   （CW/CCW・開閉リングいずれも塗り潰し／崩れ）
/// - ブリッジ（keyhole）方式の凹リングも三角形ファン相当の塗りで自己重複し、
///   半透明色では穴領域が二重ブレンドされて濃く塗られる
/// ため、ベクタ塗りでは穴を表現できない。
///
/// そこで塗りはコア共通の `PolygonRasterTileRenderer` でタイル画像として生成し、
/// `RasterTileSource`（`HerePolygonMaskTileSource`）としてカスタムラスタレイヤに直結する。
/// 形状変更時はデータバージョンを上げて HERE に再取得させる（レイヤ再生成なし）。
/// 輪郭（外周・各穴）は stroke-only の MapPolygon を重ねる。
///
/// - 穴なし: MapPolygon（fill + outline）1 枚（ネイティブのみ、マスクなし）。
/// - 穴あり: ラスタマスク（塗り）＋ 外周・各穴の stroke-only MapPolygon。
@MainActor
final class HerePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<HereActualPolygon> {
    private weak var mapView: MapView?

    private struct MaskHandle {
        let source: HerePolygonMaskTileSource
        let dataSource: RasterDataSource
        let layer: MapLayer
    }

    private var masks: [String: MaskHandle] = [:]

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> HereActualPolygon? {
        guard let mapView else { return nil }
        let resolved = resolveHoles(state)

        if resolved.holes.isEmpty {
            removeMask(id: state.id)
            let polygons = buildSimplePolygon(state: resolved)
            polygons.forEach { mapView.mapScene.addMapPolygon($0) }
            return polygons.isEmpty ? nil : polygons
        }

        ensureMask(state: resolved, mapView: mapView)
        let outlines = buildOutlinePolygons(state: resolved)
        outlines.forEach { mapView.mapScene.addMapPolygon($0) }
        return outlines.isEmpty ? nil : outlines
    }

    override func updatePolygonProperties(
        polygon: HereActualPolygon,
        current: PolygonEntity<HereActualPolygon>,
        prev: PolygonEntity<HereActualPolygon>
    ) async -> HereActualPolygon? {
        guard let mapView else { return polygon }
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        let shapeChanged = finger.points != prevFinger.points
            || finger.holes != prevFinger.holes
            || finger.geodesic != prevFinger.geodesic
        let styleChanged = finger.fillColor != prevFinger.fillColor
            || finger.strokeColor != prevFinger.strokeColor
            || finger.strokeWidth != prevFinger.strokeWidth

        if shapeChanged || styleChanged {
            // 穴の有無・数で構成（マスクの要否・輪郭の枚数）が変わるため MapPolygon 群は
            // 作り直す。マスクはタイルソースの更新（データバージョン上げ）だけで追従する。
            polygon.forEach { mapView.mapScene.removeMapPolygon($0) }
            return await createPolygon(state: current.state)
        }

        if finger.zIndex != prevFinger.zIndex {
            let order = Int32(truncatingIfNeeded: current.state.zIndex)
            polygon.forEach { $0.drawOrder = order }
        }
        return polygon
    }

    override func removePolygon(entity: PolygonEntity<HereActualPolygon>) async {
        guard let mapView else { return }
        entity.polygon?.forEach { mapView.mapScene.removeMapPolygon($0) }
        removeMask(id: entity.state.id)
    }

    func unbind() {
        masks.keys.forEach { removeMask(id: $0) }
        mapView = nil
    }

    // MARK: - Mask layer

    private func ensureMask(state: PolygonState, mapView: MapView) {
        if let handle = masks[state.id] {
            handle.source.update(
                points: state.points,
                holes: state.holes,
                fillColor: state.fillColor,
                geodesic: state.geodesic
            )
            return
        }

        let source = HerePolygonMaskTileSource()
        source.update(
            points: state.points,
            holes: state.holes,
            fillColor: state.fillColor,
            geodesic: state.geodesic
        )
        // レイヤ名・ソース名は再作成時の衝突を避けるため一意化する。
        let unique = UUID().uuidString
        let sourceName = "mc-polygon-mask-source-\(unique)"
        let layerName = "mc-polygon-mask-layer-\(unique)"
        let dataSource = RasterDataSource(context: mapView.mapContext, name: sourceName, tileSource: source)
        do {
            let layer = try MapLayerBuilder()
                .withName(layerName)
                .withDataSource(named: sourceName, contentType: .rasterImage)
                .forMap(mapView.hereMap)
                .build()
            layer.setEnabled(true)
            masks[state.id] = MaskHandle(source: source, dataSource: dataSource, layer: layer)
        } catch {
            NSLog("[MapConductor][HERE] polygon mask layer creation failed: %@", String(describing: error))
        }
    }

    private func removeMask(id: String) {
        guard let handle = masks.removeValue(forKey: id) else { return }
        // HERE iOS の MapLayer に destroy はないため無効化のみ（データソースは解放される）。
        handle.layer.setEnabled(false)
    }

    // MARK: - Polygon building

    /// 複数の穴が重なっている場合は結合（union）して重複を解消する
    /// （他プロバイダと同じ `unionHoles`。マスクタイルは union 済みでなくても正しく抜けるが、
    /// 輪郭線は結合後の外形に沿わせる）。
    private func resolveHoles(_ state: PolygonState) -> PolygonState {
        state.holes.count > 1 ? state.unionHoles() : state
    }

    private func buildSimplePolygon(state: PolygonState) -> [MapPolygon] {
        let outerRing = makeRing(points: state.points, geodesic: state.geodesic)
        let vertices = ensureCounterClockwise(outerRing).map { $0.toGeoCoordinates() }
        guard vertices.count >= 4, let geometry = try? GeoPolygon(vertices: vertices) else { return [] }
        let polygon = MapPolygon(
            geometry: geometry,
            color: state.fillColor,
            outlineColor: state.strokeColor,
            outlineWidthInPixels: state.strokeWidth
        )
        polygon.drawOrder = Int32(truncatingIfNeeded: state.zIndex)
        return [polygon]
    }

    /// 輪郭のみ（透明 fill）: 外周 + 各穴。塗りはラスタマスクが担当する。
    private func buildOutlinePolygons(state: PolygonState) -> [MapPolygon] {
        let order = Int32(truncatingIfNeeded: state.zIndex)
        let rings = [makeRing(points: state.points, geodesic: state.geodesic)]
            + state.holes.map { makeRing(points: $0, geodesic: state.geodesic) }

        var polygons: [MapPolygon] = []
        for ring in rings {
            let vertices = ensureCounterClockwise(ring).map { $0.toGeoCoordinates() }
            guard vertices.count >= 4, let geometry = try? GeoPolygon(vertices: vertices) else { continue }
            let outline = MapPolygon(
                geometry: geometry,
                color: .clear,
                outlineColor: state.strokeColor,
                outlineWidthInPixels: state.strokeWidth
            )
            outline.drawOrder = order
            polygons.append(outline)
        }
        return polygons
    }

    private func makeRing(points: [GeoPointProtocol], geodesic: Bool) -> [GeoPointProtocol] {
        var ring = (geodesic ? createInterpolatePoints(points) : createLinearInterpolatePoints(points))
            .map { $0.normalize() }
        if let first = ring.first, let last = ring.last,
           !(GeoPoint.from(position: first) == GeoPoint.from(position: last)) {
            ring.append(first)
        }
        return ring
    }
}
