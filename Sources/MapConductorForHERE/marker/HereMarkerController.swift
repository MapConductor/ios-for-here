import Combine
import CoreGraphics
import Foundation
import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HereMarkerController: AbstractMarkerController<MapMarker, HereMarkerRenderer> {
    private weak var mapView: MapView?
    private var markerStatesById: [String: MarkerState] = [:]
    private var markerSubscriptions: [String: AnyCancellable] = [:]
    private var draggingMarkerId: String?
    private let defaultIcon: any MarkerIconProtocol = DefaultMarkerIcon()
    private let defaultMarkerIconForTiling: BitmapIcon = DefaultMarkerIcon().toBitmapIcon()

    var tilingOptions: MarkerTilingOptions = .Default
    private let tileServer = TileServerRegistry.get(forceNoStoreCache: true)
    private var tileRenderer: MarkerTileRenderer<MapMarker>?
    private var tileRouteId: String?
    private var tiledMarkerIds: Set<String> = []
    private var tileDataSource: RasterDataSource?
    private var tileLayer: MapLayer?
    private var tileGeneration: Int64 = 0
    private static let tileScale: Double = 2.0

    init(mapView: MapView?) {
        self.mapView = mapView
        let markerManager = MarkerManager<MapMarker>.defaultManager()
        let renderer = HereMarkerRenderer(mapView: mapView)
        super.init(markerManager: markerManager, renderer: renderer)
    }

    func syncMarkers(_ markers: [Marker]) {
        let newIds = Set(markers.map { $0.id })
        let oldIds = Set(markerStatesById.keys)
        var newStatesById: [String: MarkerState] = [:]
        var shouldSyncList = oldIds != newIds

        for marker in markers {
            let state = marker.state
            if let existing = markerStatesById[state.id], existing !== state {
                markerSubscriptions[state.id]?.cancel()
                markerSubscriptions.removeValue(forKey: state.id)
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !markerManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        markerStatesById = newStatesById

        for id in oldIds.subtracting(newIds) {
            markerSubscriptions[id]?.cancel()
            markerSubscriptions.removeValue(forKey: id)
        }

        if shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: markers.map { $0.state })
            }
        } else {
            refreshTileLayerIfNeeded()
        }

        for marker in markers {
            subscribeToMarker(marker.state)
        }
    }
    
    private func hitTest(at screenPoint: CGPoint) -> MarkerState? {
        guard let mapView else { return nil }
        let pixelScale = CGFloat(mapView.pixelScale)
        // Minimum hit target: 44pt expressed in physical pixels.
        let minHitPx: CGFloat = 44.0 * pixelScale
        
        var bestState: MarkerState?
        var bestDistance = CGFloat.infinity
        for entity in markerManager.allEntities() where entity.state.clickable {
            guard let p = mapView.geoToViewCoordinates(geoCoordinates: entity.state.position.toGeoCoordinates()) else { continue }

            let icon: any MarkerIconProtocol = entity.state.icon ?? defaultIcon
            // Rendered size in physical pixels: iconSize (pts) × scale × pixelScale.
            // Icons are square canvases; anchor is normalized (0–1).
            let renderedPx = max(icon.iconSize * icon.scale * pixelScale, minHitPx)

            let left = CGFloat(p.x) - icon.anchor.x * renderedPx
            let top  = CGFloat(p.y) - icon.anchor.y * renderedPx
            let hitRect = CGRect(x: left, y: top, width: renderedPx, height: renderedPx)

            guard hitRect.contains(screenPoint) else { continue }

            // Among overlapping markers prefer the one whose anchor is closest to the tap.
            let distance = hypot(screenPoint.x - CGFloat(p.x), screenPoint.y - CGFloat(p.y))
            if distance < bestDistance {
                bestDistance = distance
                bestState = entity.state
            }
        }
        return bestState
    }

    func handleTap(at screenPoint: CGPoint) -> Bool {
        let bestState = hitTest(at: screenPoint)
        
        guard let bestState else { return false }
        dispatchClick(state: bestState)
        return true
    }

    override func add(data: [MarkerState]) async {
        guard tilingOptions.enabled else {
            await super.add(data: data)
            removeTileOverlay()
            return
        }
        if tileRenderer == nil {
            setupTileRenderer()
        }

        let shouldTileMarkers = data.count >= tilingOptions.minMarkerCount
        var localTiledMarkerIds = tiledMarkerIds
        let result = await MarkerIngestionEngine.ingest(
            data: data,
            markerManager: markerManager,
            renderer: renderer,
            defaultMarkerIcon: defaultMarkerIconForTiling,
            tilingEnabled: tilingOptions.enabled,
            tiledMarkerIds: &localTiledMarkerIds,
            shouldTile: { [shouldTileMarkers] state in
                shouldTileMarkers && !state.draggable && state.getAnimation() == nil
            }
        )
        tiledMarkerIds = localTiledMarkerIds
        await restoreNativeMarkersIfNeeded(states: data)

        if result.tiledDataChanged, let tileRenderer {
            tileRenderer.invalidate()
            updateTileLayer(hasTiledMarkers: result.hasTiledMarkers)
        } else if result.hasTiledMarkers {
            refreshTileLayerIfNeeded()
        } else {
            removeTileLayer()
        }
    }

    private func restoreNativeMarkersIfNeeded(states: [MarkerState]) async {
        var added: [MarkerOverlayAddParams] = []
        added.reserveCapacity(states.count)

        for state in states where !tiledMarkerIds.contains(state.id) {
            guard let entity = markerManager.getEntity(state.id), entity.marker == nil else { continue }
            let markerIcon = (state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
            added.append(MarkerOverlayAddParams(state: state, bitmapIcon: markerIcon))
        }

        guard !added.isEmpty else { return }
        let markers = await renderer.onAdd(data: added)
        for (index, marker) in markers.enumerated() {
            guard let marker else { continue }
            markerManager.updateEntity(MarkerEntity(
                marker: marker,
                state: added[index].state,
                visible: true,
                isRendered: true
            ))
        }
        await renderer.onPostProcess()
    }

    override func update(state: MarkerState) async {
        guard markerManager.hasEntity(state.id),
              let prevEntity = markerManager.getEntity(state.id) else { return }

        let currentFinger = state.fingerPrint()
        let prevFinger = prevEntity.fingerPrint
        if currentFinger == prevFinger { return }

        let tilingEnabled = tilingOptions.enabled && markerManager.allEntities().count >= tilingOptions.minMarkerCount
        let wantsTiled = tilingEnabled && !state.draggable && state.getAnimation() == nil
        let wasTiled = tiledMarkerIds.contains(state.id)

        if wantsTiled {
            if !wasTiled {
                if prevEntity.marker != nil {
                    await renderer.onRemove(data: [prevEntity])
                }
                tiledMarkerIds.insert(state.id)
            }
            markerManager.updateEntity(MarkerEntity(
                marker: nil,
                state: state,
                visible: prevEntity.visible,
                isRendered: true
            ))
            await renderer.onPostProcess()
            tileRenderer?.invalidate()
            updateTileLayer(hasTiledMarkers: true)
            return
        }

        if wasTiled {
            tiledMarkerIds.remove(state.id)
            let markerIcon = (state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
            let markers = await renderer.onAdd(data: [MarkerOverlayAddParams(state: state, bitmapIcon: markerIcon)])
            if let marker = markers.first ?? nil {
                let entity = MarkerEntity(
                    marker: marker,
                    state: state,
                    visible: prevEntity.visible,
                    isRendered: true
                )
                markerManager.updateEntity(entity)
                if state.getAnimation() != nil {
                    await renderer.onAnimate(entity: entity)
                }
            }
            await renderer.onPostProcess()
            tileRenderer?.invalidate()
            updateTileLayer(hasTiledMarkers: !tiledMarkerIds.isEmpty)
            return
        }

        await super.update(state: state)
        if !tiledMarkerIds.isEmpty {
            tileRenderer?.invalidate()
            updateTileLayer(hasTiledMarkers: true)
        }
    }

    override func clear() async {
        let entities = markerManager.allEntities()
        let nativeEntities = entities.filter { $0.marker != nil }
        if !nativeEntities.isEmpty {
            await renderer.onRemove(data: nativeEntities)
        }
        markerManager.clear()
        tiledMarkerIds.removeAll()
        removeTileOverlay()
    }
    

    /// Handles the HERE long-press gesture for marker dragging.
    /// Drag starts when the user long-presses a draggable marker (.begin),
    /// continues while the finger moves (.update), and ends on release (.end).
    func handleLongPress(state gestureState: GestureState, origin: Point2D) -> Bool {
        guard let mapView else { return false }

        switch gestureState {
        case .begin:
            guard let state = draggableMarkerState(at: origin) else { return false }
            draggingMarkerId = state.id
            mapView.gestures.disableDefaultAction(forGesture: .pan)
            dispatchDragStart(state: state)
            return true

        case .update:
            guard let markerId = draggingMarkerId,
                  let state = markerManager.getEntity(markerId)?.state,
                  let point = mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() else {
                return false
            }
            state.position = point
            dispatchDrag(state: state)
            return true

        case .end:
            guard let markerId = draggingMarkerId,
                  let state = markerManager.getEntity(markerId)?.state else {
                draggingMarkerId = nil
                return false
            }
            if let point = mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() {
                state.position = point
            }
            dispatchDragEnd(state: state)
            draggingMarkerId = nil
            mapView.gestures.enableDefaultAction(forGesture: .pan)
            return true

        case .cancel:
            let wasDragging = draggingMarkerId != nil
            draggingMarkerId = nil
            mapView.gestures.enableDefaultAction(forGesture: .pan)
            return wasDragging

        @unknown default:
            return draggingMarkerId != nil
        }
    }

    private func subscribeToMarker(_ state: MarkerState) {
        guard markerSubscriptions[state.id] == nil else { return }
        markerSubscriptions[state.id] = state.asFlow()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.markerStatesById[state.id] != nil else { return }
                Task { [weak self] in
                    await self?.update(state: state)
                }
            }
    }

    func unbind() {
        markerSubscriptions.values.forEach { $0.cancel() }
        markerSubscriptions.removeAll()
        markerStatesById.removeAll()
        draggingMarkerId = nil
        removeTileOverlay()
        renderer.unbind()
        mapView = nil
        destroy()
    }

    private func draggableMarkerState(at origin: Point2D) -> MarkerState? {
        return hitTest(at: CGPoint(x: origin.x, y: origin.y))
    }

    private static var retinaAwareTileSize: Int {
        Int(256.0 * self.tileScale * max(1.0, UIScreen.main.scale))
    }

    private func setupTileRenderer() {
        let routeId = "mapconductor-markers-\(UUID().uuidString)"
        let renderer = MarkerTileRenderer<MapMarker>(
            markerManager: markerManager,
            tileSize: Self.retinaAwareTileSize,
            extraIconScale: Self.tileScale,
            cacheSizeBytes: tilingOptions.cacheSize,
            debugTileOverlay: tilingOptions.debugTileOverlay,
            iconScaleCallback: tilingOptions.iconScaleCallback
        )
        tileServer.register(routeId: routeId, provider: renderer)
        tileRenderer = renderer
        tileRouteId = routeId
    }

    private func refreshTileLayerIfNeeded() {
        guard !tiledMarkerIds.isEmpty, tileLayer == nil else { return }
        updateTileLayer(hasTiledMarkers: true)
    }

    private func updateTileLayer(hasTiledMarkers: Bool) {
        guard hasTiledMarkers else {
            removeTileLayer()
            return
        }
        if tileRenderer == nil {
            setupTileRenderer()
        }
        guard let mapView, let routeId = tileRouteId, let tileRenderer else { return }

        tileGeneration += 1
        removeTileLayer()

        let cacheKey = String(tileGeneration)
        let tileTemplate = tileServer.urlTemplate(routeId: routeId, tileSize: tileRenderer.tileSize, cacheKey: cacheKey)
        guard let urlProvider = TileUrlProviderFactory.fromXyzUrlTemplate(tileTemplate) else { return }

        let providerConfig = RasterDataSourceConfiguration.Provider(
            urlProvider: urlProvider,
            tilingScheme: .quadTreeMercator,
            storageLevels: Array(0...22).map(Int32.init),
            hasAlphaChannel: true
        )
        let cache = RasterDataSourceConfiguration.Cache(path: tileCacheDirectoryPath())
        let sourceName = "mapconductor-marker-tiles-source-\(routeId)-\(tileGeneration)"
        let layerName = "mapconductor-marker-tiles-layer-\(routeId)-\(tileGeneration)"
        let config = RasterDataSourceConfiguration(name: sourceName, provider: providerConfig, cache: cache)
        let dataSource = RasterDataSource(context: mapView.mapContext, configuration: config)

        do {
            let layer = try MapLayerBuilder()
                .withName(layerName)
                .withDataSource(named: sourceName, contentType: .rasterImage)
                .forMap(mapView.hereMap)
                .build()
            layer.setEnabled(true)
            tileDataSource = dataSource
            tileLayer = layer
        } catch {
            NSLog("[MapConductor] HERE marker tile layer creation failed: %@", String(describing: error))
        }
    }

    private func removeTileLayer() {
        tileLayer?.setEnabled(false)
        tileLayer = nil
        tileDataSource = nil
    }

    private func removeTileOverlay() {
        removeTileLayer()
        if let routeId = tileRouteId {
            tileServer.unregister(routeId: routeId)
        }
        tileRenderer = nil
        tileRouteId = nil
        tiledMarkerIds.removeAll()
    }

    private func tileCacheDirectoryPath() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cacheURL = url.appendingPathComponent("MapConductorHEREMarkerTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return cacheURL.path
    }
}
