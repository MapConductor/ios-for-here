import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HerePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<MapPolygon> {
    private weak var mapView: MapView?
    private var masks: [String: HereMaskHandle] = [:]

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> MapPolygon? {
        guard let mapView else { return nil }

        if state.holes.isEmpty {
            removeMask(id: state.id)
            return createNativePolygon(state: state, mapView: mapView)
        } else {
            ensureMask(state: state, mapView: mapView)
            return createNativePolygon(state: state, mapView: mapView, fillOverride: .clear)
        }
    }

    override func updatePolygonProperties(
        polygon: MapPolygon,
        current: PolygonEntity<MapPolygon>,
        prev: PolygonEntity<MapPolygon>
    ) async -> MapPolygon? {
        guard let mapView else { return polygon }
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint
        let hadHoles = !prev.state.holes.isEmpty
        let hasHoles = !current.state.holes.isEmpty

        let shapeChanged = finger.points != prevFinger.points
            || finger.holes != prevFinger.holes
            || finger.geodesic != prevFinger.geodesic

        if shapeChanged, let geometry = makeGeometry(state: current.state) {
            polygon.geometry = geometry
        }

        if hasHoles {
            ensureMask(state: current.state, mapView: mapView)
            polygon.fillColor = .clear
            polygon.outlineColor = current.state.strokeColor
            polygon.outlineWidth = current.state.strokeWidth
            polygon.drawOrder = Int32(truncatingIfNeeded: current.state.zIndex)
        } else {
            if hadHoles {
                removeMask(id: current.state.id)
            }
            if finger.fillColor != prevFinger.fillColor || hadHoles {
                polygon.fillColor = current.state.fillColor
            }
            if finger.strokeColor != prevFinger.strokeColor {
                polygon.outlineColor = current.state.strokeColor
            }
            if finger.strokeWidth != prevFinger.strokeWidth {
                polygon.outlineWidth = current.state.strokeWidth
            }
            if finger.zIndex != prevFinger.zIndex {
                polygon.drawOrder = Int32(truncatingIfNeeded: current.state.zIndex)
            }
        }
        return polygon
    }

    override func removePolygon(entity: PolygonEntity<MapPolygon>) async {
        guard let mapView, let polygon = entity.polygon else { return }
        mapView.mapScene.removeMapPolygon(polygon)
        removeMask(id: entity.state.id)
    }

    func unbind() {
        masks.values.forEach { handle in
            handle.layer.setEnabled(false)
            TileServerRegistry.get().unregister(routeId: handle.routeId)
        }
        masks.removeAll()
        mapView = nil
    }

    // MARK: - Native polygon

    private func createNativePolygon(
        state: PolygonState,
        mapView: MapView,
        fillOverride: UIColor? = nil
    ) -> MapPolygon? {
        guard let geometry = makeGeometry(state: state) else { return nil }
        let fill = fillOverride ?? state.fillColor
        let polygon = MapPolygon(
            geometry: geometry,
            color: fill,
            outlineColor: state.strokeColor,
            outlineWidthInPixels: state.strokeWidth
        )
        polygon.drawOrder = Int32(truncatingIfNeeded: state.zIndex)
        mapView.mapScene.addMapPolygon(polygon)
        return polygon
    }

    // MARK: - Mask (raster tile overlay for hole polygons)

    private func ensureMask(state: PolygonState, mapView: MapView) {
        let id = state.id
        if let existing = masks[id] {
            existing.tileRenderer.update(
                points: state.points,
                holes: state.holes,
                fillColor: state.fillColor,
                geodesic: state.geodesic
            )
            return
        }

        let tileRenderer = PolygonRasterTileRenderer(tileSize: 256)
        tileRenderer.update(
            points: state.points,
            holes: state.holes,
            fillColor: state.fillColor,
            geodesic: state.geodesic
        )

        let routeId = "polygon-raster-\(safeId(id))"
        let cacheKey = String(abs(routeId.hashValue))
        let tileServer = TileServerRegistry.get(forceNoStoreCache: true)
        tileServer.register(routeId: routeId, provider: tileRenderer)
        let urlTemplate = tileServer.urlTemplate(routeId: routeId, tileSize: 256, cacheKey: cacheKey)

        let sourceName = "mapconductor-polygon-mask-source-\(safeId(id))"
        let layerName = "mapconductor-polygon-mask-layer-\(safeId(id))"

        let providerConfig = RasterDataSourceConfiguration.Provider(
            urlProvider: { x, y, level in
                urlTemplate
                    .replacingOccurrences(of: "{z}", with: "\(level)")
                    .replacingOccurrences(of: "{x}", with: "\(x)")
                    .replacingOccurrences(of: "{y}", with: "\(y)")
            },
            tilingScheme: .quadTreeMercator,
            storageLevels: Array(0...22).map(Int32.init),
            hasAlphaChannel: true
        )
        let cache = RasterDataSourceConfiguration.Cache(path: cacheDirectoryPath())
        let config = RasterDataSourceConfiguration(
            name: sourceName,
            provider: providerConfig,
            cache: cache
        )
        let dataSource = RasterDataSource(context: mapView.mapContext, configuration: config)

        do {
            let layer = try MapLayerBuilder()
                .withName(layerName)
                .withDataSource(named: sourceName, contentType: .rasterImage)
                .forMap(mapView.hereMap)
                .build()
            layer.setEnabled(true)
            masks[id] = HereMaskHandle(
                routeId: routeId,
                tileRenderer: tileRenderer,
                dataSource: dataSource,
                layer: layer
            )
        } catch {
            NSLog("[MapConductor] HERE polygon mask layer creation failed: %@", String(describing: error))
            TileServerRegistry.get().unregister(routeId: routeId)
        }
    }

    private func removeMask(id: String) {
        guard let handle = masks.removeValue(forKey: id) else { return }
        handle.layer.setEnabled(false)
        TileServerRegistry.get().unregister(routeId: handle.routeId)
    }

    private func cacheDirectoryPath() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheURL = url.appendingPathComponent("MapConductorHEREPolygonMask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return cacheURL.path
    }

    private func safeId(_ id: String) -> String {
        id.map { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? String(ch) : "_"
        }.joined()
    }

    // MARK: - Geometry

    private func makeGeometry(state: PolygonState) -> GeoPolygon? {
        let outerRing = makeRing(points: state.points, geodesic: state.geodesic)
        let vertices = ensureCounterClockwise(outerRing).map { $0.toGeoCoordinates() }
        guard vertices.count >= 4 else { return nil }
        let holes = state.holes.map { holePoints -> [GeoCoordinates] in
            let ring = makeRing(points: holePoints, geodesic: state.geodesic)
            return ensureClockwiseRing(ring).map { $0.toGeoCoordinates() }
        }
        return try? GeoPolygon(vertices: vertices, innerBoundaries: holes)
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

private struct HereMaskHandle {
    let routeId: String
    let tileRenderer: PolygonRasterTileRenderer
    let dataSource: RasterDataSource
    let layer: MapLayer
}
