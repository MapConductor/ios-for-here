import Foundation
import heresdk
@_spi(MapConductorDriver) import MapConductorCore

/// HERE の地図レイヤ（`MapLayer`）で載せるオーバーレイ（ラスター・グラウンドイメージ・
/// マーカーのタイル）を、重なり順の帯（``OverlayBand``）の順に並べる。
///
/// `MapLayer` は優先度を指定しないと作った時点で一番上に置かれる。マップアイテム
/// （ポリゴン・サークル・ポリライン・マーカー）が描かれる層は最初のアイテムを足したときに
/// 作られるようで、それより後に作った地図レイヤはアイテムを覆う（実機: 先に足したラスターは
/// ポリゴンの下、送り直したラスターはポリゴンの上）。`renderedFirst()` はベースマップの下まで
/// 沈んで見えなくなる。
///
/// そこで、アイテムより先（地図を作った直後）に空の「錨」の地図レイヤを 1 枚作っておき、
/// ラスター・グラウンドイメージを帯 → zIndex → 作った順に並べて、先頭を錨の直後、
/// 2 枚目以降を 1 つ前の直後（`renderedAfterLayer(named:)`）に置き直す。
/// マーカーのタイルは並びに入れず既定の優先度のまま（作った時点で一番上 = マーカーの帯）。
///
/// ポリゴン・サークル・ポリライン・マーカー（マップアイテム）の間の順は `drawOrder`
/// （``OverlayStacking/globalZIndex(_:)``）で決める。
@MainActor
enum HereOverlayStacking {
    static let anchorLayerName = "mapconductor-stack-anchor"

    /// `drawOrder` の帯の幅。4096 幅（他プロバイダの既定）では実機で帯の順にならなかったので
    /// 小さく取る（帯の中の zIndex は ±49 に丸める）。
    static let drawOrderBandStride = 100

    /// 錨の地図レイヤを作る。マップアイテムを足す前（`bind` の直後）に呼ぶ。
    static func installAnchor(on mapView: MapView) {
        let registry = registry(of: mapView)
        guard registry.anchor == nil else { return }
        guard let urlProvider = TileUrlProviderFactory.fromXyzUrlTemplate("http://127.0.0.1:1/{z}/{x}/{y}.png") else { return }
        let provider = RasterDataSourceConfiguration.Provider(
            urlProvider: urlProvider,
            tilingScheme: .quadTreeMercator,
            storageLevels: [],
            hasAlphaChannel: true
        )
        let sourceName = "mapconductor-stack-anchor-source"
        let cachePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("mapconductor-stack-anchor")
        let config = RasterDataSourceConfiguration(
            name: sourceName,
            provider: provider,
            cache: RasterDataSourceConfiguration.Cache(path: cachePath)
        )
        registry.anchorSource = RasterDataSource(context: mapView.mapContext, configuration: config)
        registry.anchor = try? MapLayerBuilder()
            .withName(anchorLayerName)
            .withDataSource(named: sourceName, contentType: .rasterImage)
            .forMap(mapView.hereMap)
            .build()
        registry.anchor?.setEnabled(false)
    }

    private final class Entry {
        let name: String
        weak var layer: MapLayer?
        let key: OverlayStackKey
        init(name: String, layer: MapLayer, key: OverlayStackKey) {
            self.name = name
            self.layer = layer
            self.key = key
        }
    }

    private final class Registry {
        var entries: [Entry] = []
        var anchor: MapLayer?
        var anchorSource: RasterDataSource?
        var polylineLayerAdded = false
    }

    private static var registryKey: UInt8 = 0

    private static func registry(of mapView: MapView) -> Registry {
        if let registry = objc_getAssociatedObject(mapView, &registryKey) as? Registry { return registry }
        let registry = Registry()
        objc_setAssociatedObject(mapView, &registryKey, registry, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return registry
    }

    static let polylineLayerName = "mapconductor-polylines"

    /// ポリラインを専用のポリラインレイヤ（一番上に描く優先度）へ足す。
    ///
    /// 既定のシーンに足したポリラインは `drawOrder` に関わらずポリゴン・サークルの下、
    /// さらにラスターの地図レイヤの下に描かれた（実機）。HERE はポリラインだけ名前付きの
    /// レイヤ（`addMapPolylineLayer(name:layerPriority:)`）へ足せるので、そこへ入れて
    /// ポリゴン・サークルより上に置く。マーカーは SDK がさらに上に描く。
    static func addPolyline(_ polyline: MapPolyline, to mapView: MapView) {
        let registry = registry(of: mapView)
        if !registry.polylineLayerAdded {
            registry.polylineLayerAdded = mapView.mapScene.addMapPolylineLayer(
                name: polylineLayerName,
                layerPriority: MapLayerPriorityBuilder().renderedLast().build()
            )
        }
        if !registry.polylineLayerAdded || !mapView.mapScene.addMapPolyline(polyline, layerName: polylineLayerName) {
            mapView.mapScene.addMapPolyline(polyline)
        }
    }

    /// 作った地図レイヤを帯の位置へ置く。`MapLayerBuilder.build()` の直後に呼ぶ。
    static func place(_ layer: MapLayer, named name: String, _ key: OverlayStackKey, on mapView: MapView) {
        // マーカーのタイルは既定の優先度のまま（作った時点で一番上）。
        guard key.band != .marker else { return }
        let registry = registry(of: mapView)
        registry.entries.removeAll { $0.layer == nil || $0.name == name }
        let index = OverlayStacking.insertionIndex(for: key, among: registry.entries.map(\.key))
        registry.entries.insert(Entry(name: name, layer: layer, key: key), at: index)
        apply(registry)
    }

    /// 外した地図レイヤを並びから除く。
    static func remove(named name: String, on mapView: MapView?) {
        guard let mapView else { return }
        let registry = registry(of: mapView)
        registry.entries.removeAll { $0.layer == nil || $0.name == name }
        apply(registry)
    }

    private static func apply(_ registry: Registry) {
        var previous: String?
        for entry in registry.entries {
            guard let layer = entry.layer else { continue }
            let after = previous ?? (registry.anchor != nil ? anchorLayerName : nil)
            guard let after else { break }
            layer.setPriority(MapLayerPriorityBuilder().renderedAfterLayer(named: after).build())
            previous = entry.name
        }
    }
}
