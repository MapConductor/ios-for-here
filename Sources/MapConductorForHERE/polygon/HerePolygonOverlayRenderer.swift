import Foundation
import heresdk
import MapConductorCore
import UIKit

/// HERE の穴付きポリゴンは「分割方式」で描画する。
///
/// 実機検証の結果、HERE iOS SDK の MapPolygon は
/// - `GeoPolygon(vertices:innerBoundaries:)` の穴を描画で正しく抜かない
///   （CW/CCW・開閉リングいずれも塗り潰し／崩れ）
/// - ブリッジ（keyhole）方式の凹リングも三角形ファン相当の塗りで自己重複し、
///   半透明色では穴領域が二重ブレンドされて濃く塗られる
/// ため、穴を持つ 1 枚のリングでは表現できない。
///
/// そこでコア共通の `splitPolygonWithHolesIntoSimpleRings`（TomTom Orbis iOS 向けに
/// 作られた分割方式）で「穴を持たない単純リング群」へ分割し、1 リング 1 枚の
/// MapPolygon として塗る。ピースは互いに素なので半透明でも二重に塗られない。
/// 輪郭（外周・各穴）は stroke-only の MapPolygon を重ねる。
///
/// - 穴なし: MapPolygon（fill + outline）1 枚。
/// - 穴あり: 分割ピースごとの fill-only MapPolygon ＋ 外周・各穴の stroke-only MapPolygon。
///
/// 以前は塗りをタイル画像へ焼き、カスタムラスタレイヤへ直結する「ラスタマスク方式」だった。
/// 分割方式に置き換えたのは、ベクタのまま描けるため拡大時にぼけず、タイルソース／レイヤ
/// 生成の機構も要らなくなるため。焼き付けに使っていたコアの `PolygonRasterTileRenderer` と
/// `HerePolygonMaskTileSource` は利用者がここだけだったので、あわせて削除した。
@MainActor
final class HerePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<HereActualPolygon> {
    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> HereActualPolygon? {
        guard let mapView else { return nil }
        let resolved = await resolveHoles(state)

        if resolved.holes.isEmpty {
            let polygons = buildSimplePolygon(state: resolved)
            polygons.forEach { mapView.mapScene.addMapPolygon($0) }
            return polygons.isEmpty ? nil : polygons
        }

        // 塗り（穴なしの単純リング群）→ 輪郭 の順に足す。輪郭が塗りの上に来るように。
        let polygons = buildSplitFillPolygons(state: resolved) + buildOutlinePolygons(state: resolved)
        polygons.forEach { mapView.mapScene.addMapPolygon($0) }
        return polygons.isEmpty ? nil : polygons
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
            // 穴の有無・数で構成（分割ピース数・輪郭の枚数）が変わるため MapPolygon 群は
            // 作り直す。
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
    }

    func unbind() {
        mapView = nil
    }

    // MARK: - Polygon building

    /// 複数の穴が重なっている場合は結合（union）して重複を解消する。
    /// 他プロバイダ（ArcGIS/Mapbox/MapLibre）と同じ `unionHoles()` を用いる。
    ///
    /// 穴が重なったままだと分割の橋どうしが交差して破綻するうえ、輪郭も穴リングごとに
    /// `MapPolygon` を作るため、結合しないと重なり部分に内側の線が残る。
    /// コンポーネント層（`Polygon`）のユニオンは state 1 インスタンスにつき 1 回きりで
    /// 頂点ドラッグ後の `state.holes` 差し替えには追従しないため、android-for-here と同じく
    /// ジオメトリを組み立てるここでも結合する。
    ///
    /// android-for-here が `withContext(Dispatchers.Default)` で逃がしているのと同じく、
    /// 平面アレンジメント（辺数に対して O(n²)）は MainActor の外で回す。
    private func resolveHoles(_ state: PolygonState) async -> PolygonState {
        guard state.holes.count > 1 else { return state }
        return await state.unionHolesInBackground()
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

    /// 塗り（分割方式）: 外周＋穴を「穴を持たない単純リング群」へ分割し、1 リング 1 枚で塗る。
    ///
    /// HERE の `GeoPolygon(vertices:innerBoundaries:)` は API としては存在するが実機で
    /// 穴を抜けない。keyhole ブリッジも三角形ファン相当の塗りで自己重複し、半透明色では
    /// 穴の位置が二重ブレンドで濃くなる。分割方式は keyhole も自己接触も作らず、
    /// 出力ピースが互いに素なので半透明でも二重に塗られない
    /// （`PolygonHoleSplitTests` が「面積の合計 = 外周 - 穴」で担保している）。
    /// HERE 自身のドキュメントも、複雑な形状は複数のポリゴンに分けるよう案内している。
    ///
    /// 輪郭は付けない。ピース境界には分割のために引いた橋が含まれるので、線を引くと
    /// 実在しない切れ目が見えてしまう。輪郭は ``buildOutlinePolygons`` が別に描く。
    private func buildSplitFillPolygons(state: PolygonState) -> [MapPolygon] {
        let outerRing = makeRing(points: state.points, geodesic: state.geodesic)
        let holeRings = state.holes.map { makeRing(points: $0, geodesic: state.geodesic) }
        let pieces = splitPolygonWithHolesIntoSimpleRings(outer: outerRing, holes: holeRings)
        let order = Int32(truncatingIfNeeded: state.zIndex)

        var polygons: [MapPolygon] = []
        for piece in pieces {
            // 分割の出力は開リング。GeoPolygon へ渡す前に既存経路と同じく閉じる。
            var ring = piece
            if let first = ring.first, let last = ring.last,
               !(GeoPoint.from(position: first) == GeoPoint.from(position: last)) {
                ring.append(first)
            }
            let vertices = ring.map { $0.toGeoCoordinates() }
            guard vertices.count >= 4, let geometry = try? GeoPolygon(vertices: vertices) else { continue }
            let fill = MapPolygon(geometry: geometry, color: state.fillColor)
            fill.drawOrder = order
            polygons.append(fill)
        }
        return polygons
    }

    /// 輪郭のみ（透明 fill）: 外周 + 各穴。塗りは ``buildSplitFillPolygons`` が担当する。
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
        var ring = (geodesic ? WGS84Geodesic.createInterpolatePoints(points) : Planar.createInterpolatePoints(points))
            .map { $0.normalize() }
        if let first = ring.first, let last = ring.last,
           !(GeoPoint.from(position: first) == GeoPoint.from(position: last)) {
            ring.append(first)
        }
        return ring
    }
}
