import Combine
import heresdk
import MapConductorCore
import SwiftUI
import UIKit

public struct HereMapView: View {
    @ObservedObject private var state: HereMapViewState
    private let projection: MapConductorCore.MapProjection

    private let handlers: MapViewHandlers<HereMapViewState>
    private let cameraRestriction: CameraRestriction?
    private let content: () -> MapViewContent

    public init(
        state: HereMapViewState,
        projection: MapConductorCore.MapProjection = .globe,
        cameraRestriction: CameraRestriction? = nil,
        onMapLoaded: OnMapLoadedHandler<HereMapViewState>? = nil,
        onMapClick: OnMapEventHandler? = nil,
        onMapLongClick: OnMapEventHandler? = nil,
        onCameraMoveStart: OnCameraMoveHandler? = nil,
        onCameraMove: OnCameraMoveHandler? = nil,
        onCameraMoveEnd: OnCameraMoveHandler? = nil,
        sdkInitialize: (() -> Void)? = nil,
        @MapViewContentBuilder content: @escaping () -> MapViewContent = { MapViewContent() }
    ) {
        self.state = state
        self.projection = projection
        self.cameraRestriction = cameraRestriction
        self.handlers = MapViewHandlers(
            onMapLoaded: onMapLoaded,
            onMapClick: onMapClick,
            onMapLongClick: onMapLongClick,
            onCameraMoveStart: onCameraMoveStart,
            onCameraMove: onCameraMove,
            onCameraMoveEnd: onCameraMoveEnd,
            sdkInitialize: sdkInitialize
        )
        self.content = content
    }

    public var body: some View {
        // The provider's registry is in scope only while content is being assembled —
        // the same window in which Compose provides `LocalMapServiceRegistry` around the
        // content lambda. Bracketing the pass lets a removed plugin be noticed.
        let support = state.serviceRegistry.get(MarkerRenderingSupportKey.self)
        support?.beginContentPass()
        let mapContent = MapServiceRegistryScope.with(state.serviceRegistry) { content() }
        support?.endContentPass()
        return MapViewBase(
            attributionRules: state.mapDesignType.attributionRules,
            camera: state.cameraPosition,
            content: mapContent
        ) {
            HereMapViewRepresentable(
                state: state,
                cameraRestriction: cameraRestriction,
                projection: projection,
                handlers: handlers,
                content: mapContent
            )
        }
    }
}

private final class HereMapWrapperView: UIView {
    let mapView: MapView
    let overlayContainer: UIView

    init(mapView: MapView, overlayContainer: UIView) {
        self.mapView = mapView
        self.overlayContainer = overlayContainer
        super.init(frame: .zero)
        addSubview(mapView)
        addSubview(overlayContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        overlayContainer.frame = bounds
    }
}

private struct HereMapViewRepresentable: UIViewRepresentable {
    @ObservedObject var state: HereMapViewState
    let cameraRestriction: CameraRestriction?
    let projection: MapConductorCore.MapProjection
    let handlers: MapViewHandlers<HereMapViewState>
    let content: MapViewContent

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, handlers: handlers)
    }

    func makeUIView(context: Context) -> HereMapWrapperView {
        if let sdkInitialize = handlers.sdkInitialize {
            Coordinator.runOnce(sdkInitialize)
        }

        let options = MapViewOptions(
            projection: projection == .globe ? .globe : .webMercator
        )
        let mapView = MapView(frame: .zero, options: options)
        let wrapper = HereMapWrapperView(
            mapView: mapView,
            overlayContainer: context.coordinator.infoBubbleContainer
        )

        context.coordinator.mapView = mapView
        context.coordinator.bind(state: state, mapView: mapView)
        // android-for-here の HereMapView.kt と同じ位置で適用する。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        context.coordinator.updateGestures(state.uiSettings)
        context.coordinator.updateContent(content)
        context.coordinator.loadInitialScene()

        return wrapper
    }

    func updateUIView(_ uiView: HereMapWrapperView, context: Context) {
        // 制限値が変わったときだけ再適用する。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        context.coordinator.updateMapDesignIfNeeded()
        context.coordinator.updateGestures(state.uiSettings)
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: HereMapWrapperView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.mapView.pause()
    }

    @MainActor
    final class Coordinator: MapViewCoordinatorBase<HereMapViewState>, MarkerRenderingSupport {
        /// android-sdk の `cameraRestriction?.let { controller.setCameraRestriction(it) }` 相当。
        func applyCameraRestriction(_ restriction: CameraRestriction?) {
            applyCameraRestriction(restriction, to: controller)
        }

        weak var mapView: MapView?
        private var controller: HereMapViewController?
        private var markerController: HereMarkerController?
        private var markerEventController: (any HereMarkerEventControllerProtocol)?
        private var polylineController: HerePolylineController?
        private var polygonController: HerePolygonController?
        private var hullPolygonController: HerePolygonController?
        private var circleController: HereCircleController?
        private var groundImageController: HereGroundImageController?
        private var rasterLayerController: HereRasterLayerController?
        private var overlayScope: MapOverlayScope?
        private var infoBubbleCoordinator: InfoBubbleOverlayCoordinator?
        /// 接続中の strategy の有無。以前は `MapViewContent.markerRenderingStrategy` を
        /// 毎回覗いていたが、プラグインが capability 経由で接続する形に反転した。
        private var hasConnectedStrategy = false
        private var strategyConnectedThisPass = false
        private var pendingStrategy: Any?

        private var strategyMarkerController: StrategyMarkerController<
            MapMarker,
            AnyMarkerRenderingStrategy<MapMarker>,
            HereMarkerRenderer
        >?
        private var strategyMarkerRenderer: HereMarkerRenderer?
        private var strategyMarkerSubscriptions: [String: AnyCancellable] = [:]
        private var strategyMarkerStatesById: [String: MarkerState] = [:]
        private var loadedMapScheme: MapScheme?
        private var latestContent = MapViewContent()
        private var isSceneLoaded = false
        private var needsOverlayResetOnNextSceneLoaded = false
        private var lastKnownCameraPosition: MapCameraPosition?

        func bind(state: HereMapViewState, mapView: MapView) {
            // Publish marker rendering as a map-scoped capability. Add-on modules resolve it
            // from the registry; this provider never learns that clustering exists.
            // 再バインド時に前回の capability が残らないよう、登録前に空にする
            // （android-sdk の各 *MapView.kt が `registry.clear()` してから put するのと同じ）。
            state.serviceRegistry.clear()
            state.serviceRegistry.put(MarkerRenderingSupportKey.self, self)
            // A strategy can be connected before the map view exists (content is assembled
            // first); replay it now that the renderer can actually be built.
            if let pending = pendingStrategy {
                pendingStrategy = nil
                applyStrategyRendering(pending)
            }
            infoBubbleContainer.backgroundColor = .clear
            infoBubbleContainer.isUserInteractionEnabled = true

            let controller = HereMapViewController(mapView: mapView)
            self.controller = controller
            state.setController(controller)
            state.setMapViewHolder(controller.typedHolder)

            let markerController = HereMarkerController(mapView: mapView)
            let polylineController = HerePolylineController(mapView: mapView)
            let polygonController = HerePolygonController(mapView: mapView)
            let circleController = HereCircleController(mapView: mapView)
            let groundImageController = HereGroundImageController(mapView: mapView)
            let rasterLayerController = HereRasterLayerController(mapView: mapView)
            self.markerController = markerController
            self.markerEventController = DefaultHereMarkerEventController(markerController: markerController)
            self.polylineController = polylineController
            self.polygonController = polygonController
            self.hullPolygonController = HerePolygonController(mapView: mapView)
            self.circleController = circleController
            self.groundImageController = groundImageController
            self.rasterLayerController = rasterLayerController

            // Route the simple overlays through the shared collector so each
            // controller subscribes to one source of truth instead of the map
            // host re-diffing arrays every render.
            let overlayScope = MapOverlayScope()
            self.overlayScope = overlayScope
            bindOverlayCollector(overlayScope.circleCollector, to: circleController)
            bindOverlayCollector(overlayScope.polylineCollector, to: polylineController)
            bindOverlayCollector(overlayScope.polygonCollector, to: polygonController)
            bindOverlayCollector(overlayScope.rasterLayerCollector, to: rasterLayerController)
            bindOverlayCollector(overlayScope.groundImageCollector, to: groundImageController)

            self.infoBubbleCoordinator = InfoBubbleOverlayCoordinator(
                container: infoBubbleContainer,
                project: { [weak self] point in
                    guard let mapView = self?.mapView else { return nil }
                    guard let p2d = mapView.geoToViewCoordinates(geoCoordinates: point.toGeoCoordinates()) else { return nil }
                    return p2d.toUIKitPoint(pixelScale: mapView.pixelScale)
                },
                resolveMarkerStateForIcon: { [weak markerController] id, bubbleMarker in
                    markerController?.markerManager.getEntity(id)?.state ?? bubbleMarker
                },
                iconMetrics: { markerState in
                    let icon = (markerState.icon ?? DefaultMarkerIcon()).toBitmapIcon()
                    return MarkerIconMetrics(size: icon.size, anchor: icon.anchor, infoAnchor: icon.infoAnchor)
                }
            )

            // Screen-space marker animation layer: shares the info-bubble
            // container (inserted below the bubbles) and the map projection.
            markerController.renderer.animationOverlay = MarkerAnimationOverlayCoordinator(
                container: infoBubbleContainer,
                project: { [weak self] point in
                    guard let mapView = self?.mapView else { return nil }
                    guard let p2d = mapView.geoToViewCoordinates(geoCoordinates: point.toGeoCoordinates()) else { return nil }
                    return p2d.toUIKitPoint(pixelScale: mapView.pixelScale)
                }
            )

            controller.setMapClickListener(listener: onMapClick)
            controller.setMapLongClickListener(listener: onMapLongClick)
            controller.setCameraMoveStartListener { [weak self] position in
                self?.lastKnownCameraPosition = position
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMoveStart?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
                Task { [weak self] in
                    await self?.strategyMarkerController?.onCameraChanged(mapCameraPosition: position)
                }
            }
            controller.setCameraMoveListener { [weak self] position in
                self?.lastKnownCameraPosition = position
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMove?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
                Task { [weak self] in
                    await self?.strategyMarkerController?.onCameraChanged(mapCameraPosition: position)
                }
            }
            controller.setCameraMoveEndListener { [weak self] position in
                self?.lastKnownCameraPosition = position
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMoveEnd?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
                Task { [weak self] in
                    await self?.strategyMarkerController?.onCameraChanged(mapCameraPosition: position)
                }
            }
            controller.setMapDesignTypeChangeListener { [weak self] design in
                self?.state.onMapDesignTypeChange(design)
            }
            controller.setSceneLoadedHandler { [weak self] in
                self?.handleSceneLoaded()
            }
            controller.setTapHandler { [weak self] origin, point in
                self?.handleTap(origin: origin, point: point) ?? false
            }
            controller.setLongPressHandler { [weak self] state, origin in
                let handled = self?.markerEventController?.handleLongPress(state: state, origin: origin) ?? false
                // マーカードラッグ中（handled==true）は InfoBubble をマーカーへ追従させる
                // （mapbox の onUpdateInfoBubble 相当）。
                if handled {
                    self?.infoBubbleCoordinator?.updateAllLayouts()
                }
                return handled
            }
        }

        func updateGestures(_ ui: MapUISettings) {
            guard let mapView else { return }
            markerController?.scrollGestureEnabled = ui.scrollGesture

            func apply(_ enabled: Bool, _ gesture: heresdk.GestureType) {
                if enabled {
                    mapView.gestures.enableDefaultAction(forGesture: gesture)
                } else {
                    mapView.gestures.disableDefaultAction(forGesture: gesture)
                }
            }

            apply(ui.scrollGesture, .pan)
            apply(ui.tiltGesture, .twoFingerPan)
            // HERE bundles pinch-zoom and rotation into a single `.pinchRotate`
            // recogniser, so neither can be switched off on its own. Only drop it
            // when both are disabled; the discrete zoom gestures still follow
            // `zoomGesture` on their own.
            apply(ui.zoomGesture || ui.rotateGesture, .pinchRotate)
            apply(ui.zoomGesture, .doubleTap)
            apply(ui.zoomGesture, .twoFingerTap)

            if ui.zoomGesture != ui.rotateGesture {
                let stillOn: MapGesture = ui.zoomGesture ? .rotate : .zoom
                MapUISettingsDiagnostics.warnIfRequested(
                    false,
                    gesture: stillOn,
                    provider: "HERE",
                    reason: "pinch zoom and rotation share one gesture recogniser, so they can only be disabled together"
                )
            }
        }

        func updateContent(_ content: MapViewContent) {
            latestContent = content
            guard isSceneLoaded else { return }
            syncContent(content)
        }

        private func syncContent(_ content: MapViewContent) {
            infoBubbleCoordinator?.syncInfoBubbles(content.infoBubbles)
            markerController?.tilingOptions = content.markerTilingOptions
            markerController?.syncMarkers(content.markers)
            overlayScope?.groundImageCollector.sync(content.groundImages.map { $0.state })
            overlayScope?.rasterLayerCollector.sync(content.rasterLayers.map { $0.state })
            overlayScope?.polylineCollector.sync(content.polylines.map { $0.state })
            overlayScope?.polygonCollector.sync(content.polygons.map { $0.state })
            for handler in content.polygonSyncHandlers {
                let hullController = hullPolygonController
                handler.bindPolygonSync { [weak hullController] states in
                    await hullController?.add(data: states)
                }
            }
            overlayScope?.circleCollector.sync(content.circles.map { $0.state })
            infoBubbleCoordinator?.updateAllLayouts()
        }

        // MARK: - MarkerRenderingSupport
        //
        // HERE keeps its own renderer rather than using StrategyMarkerManager, so the
        // coordinator implements the capability directly. The lookup direction matches every
        // other provider: the plugin resolves this from MapServiceRegistry and calls connect.

        @discardableResult
        func connect(strategy: Any, markers: [MarkerState]) -> Bool {
            guard strategy is AnyMarkerRenderingStrategy<MapMarker> else { return false }
            strategyConnectedThisPass = true
            hasConnectedStrategy = true
            guard mapView != nil else {
                // Content is assembled before bind(state:mapView:) on the first pass.
                pendingStrategy = strategy
                return true
            }
            applyStrategyRendering(strategy)
            syncMarkers(markers)
            return true
        }

        func syncMarkers(_ markers: [MarkerState]) {
            syncStrategyMarkers(markers)
        }

        func disconnect() {
            pendingStrategy = nil
            hasConnectedStrategy = false
            applyStrategyRendering(nil)
        }

        func beginContentPass() {
            strategyConnectedThisPass = false
        }

        func endContentPass() {
            if !strategyConnectedThisPass, hasConnectedStrategy {
                disconnect()
            }
        }

        private func applyStrategyRendering(_ anyStrategy: Any?) {
            guard let mapView else { return }
            if let strategy = anyStrategy as? AnyMarkerRenderingStrategy<MapMarker> {
                if strategyMarkerController == nil ||
                    strategyMarkerController?.markerManager !== strategy.markerManager {
                    strategyMarkerRenderer?.unbind()
                    let renderer = HereMarkerRenderer(mapView: mapView)
                    strategyMarkerRenderer = renderer
                    strategyMarkerController = StrategyMarkerController(strategy: strategy, renderer: renderer)
                    // find() の android 同等 screen 空間判定用に geo→screen 投影を注入する。
                    strategyMarkerController?.markerProjector = { [weak self] geo in
                        guard let mapView = self?.mapView,
                              let p2d = mapView.geoToViewCoordinates(geoCoordinates: geo.toGeoCoordinates())
                        else { return nil }
                        return p2d.toUIKitPoint(pixelScale: mapView.pixelScale)
                    }
                    if let position = lastKnownCameraPosition {
                        Task { [weak self] in
                            await self?.strategyMarkerController?.onCameraChanged(mapCameraPosition: position)
                        }
                    }
                }
            } else {
                strategyMarkerSubscriptions.values.forEach { $0.cancel() }
                strategyMarkerSubscriptions.removeAll()
                strategyMarkerStatesById.removeAll()
                strategyMarkerRenderer?.unbind()
                strategyMarkerRenderer = nil
                strategyMarkerController?.destroy()
                strategyMarkerController = nil
            }
        }

        private func syncStrategyMarkers(_ markers: [MarkerState]) {
            guard let controller = strategyMarkerController else { return }
            let newIds = Set(markers.map { $0.id })
            let oldIds = Set(strategyMarkerStatesById.keys)
            var shouldSyncList = newIds != oldIds

            var newStatesById: [String: MarkerState] = [:]
            for state in markers {
                if let existing = strategyMarkerStatesById[state.id], existing !== state {
                    strategyMarkerSubscriptions[state.id]?.cancel()
                    strategyMarkerSubscriptions.removeValue(forKey: state.id)
                    shouldSyncList = true
                }
                newStatesById[state.id] = state
            }
            strategyMarkerStatesById = newStatesById

            for id in oldIds.subtracting(newIds) {
                strategyMarkerSubscriptions[id]?.cancel()
                strategyMarkerSubscriptions.removeValue(forKey: id)
            }

            if shouldSyncList {
                Task { [weak self] in
                    guard self != nil else { return }
                    await controller.add(data: markers)
                }
            }

            for state in markers {
                subscribeToStrategyMarker(state)
            }
        }

        private func subscribeToStrategyMarker(_ state: MarkerState) {
            guard strategyMarkerSubscriptions[state.id] == nil else { return }
            strategyMarkerSubscriptions[state.id] = state.asFlow()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.strategyMarkerStatesById[state.id] != nil else { return }
                    Task { [weak self] in
                        await self?.strategyMarkerController?.update(state: state)
                    }
                }
        }

        func loadInitialScene() {
            guard let mapView else { return }
            let scheme = state.mapDesignType.getValue()
            mapView.mapScene.loadScene(mapScheme: scheme) { [weak self] error in
                guard let self else { return }
                if let error {
                    NSLog("[MapConductor] HERE loadScene failed: %@", String(describing: error))
                    return
                }
                self.loadedMapScheme = scheme
                self.isSceneLoaded = true
                self.lastKnownCameraPosition = self.state.cameraPosition
                self.controller?.moveCamera(position: self.state.cameraPosition)
                self.syncContentAfterSceneLoaded(resetOverlays: false)
                self.notifyMapLoadedIfNeeded()
            }
        }

        func updateMapDesignIfNeeded() {
            let scheme = state.mapDesignType.getValue()
            guard loadedMapScheme != scheme else { return }
            loadedMapScheme = scheme
            isSceneLoaded = false
            needsOverlayResetOnNextSceneLoaded = true
            controller?.setMapDesignType(state.mapDesignType)
        }

        func unbind() {
            state.setController(nil)
            state.setMapViewHolder(nil)
            mapView?.camera.removeDelegates()
            mapView?.gestures.tapDelegate = nil
            mapView?.gestures.panDelegate = nil
            mapView?.gestures.longPressDelegate = nil
            markerController?.renderer.animationOverlay?.unbind()
            markerController?.renderer.animationOverlay = nil
            markerController?.unbind()
            markerController = nil
            markerEventController = nil
            polylineController?.unbind()
            polylineController = nil
            polygonController?.unbind()
            polygonController = nil
            hullPolygonController?.unbind()
            hullPolygonController = nil
            circleController?.unbind()
            circleController = nil
            groundImageController?.unbind()
            groundImageController = nil
            rasterLayerController?.unbind()
            rasterLayerController = nil
            overlayScope?.clear()
            overlayScope = nil
            infoBubbleCoordinator?.unbind()
            infoBubbleCoordinator = nil
            strategyMarkerSubscriptions.values.forEach { $0.cancel() }
            strategyMarkerSubscriptions.removeAll()
            strategyMarkerStatesById.removeAll()
            strategyMarkerRenderer?.unbind()
            strategyMarkerRenderer = nil
            strategyMarkerController?.destroy()
            strategyMarkerController = nil
            controller?.setSceneLoadedHandler(nil)
            controller = nil
            mapView = nil
        }

        fileprivate func updateInfoBubbleLayouts() {
            infoBubbleCoordinator?.updateAllLayouts()
        }

        private func handleSceneLoaded() {
            let shouldResetOverlays = isSceneLoaded || needsOverlayResetOnNextSceneLoaded
            loadedMapScheme = state.mapDesignType.getValue()
            isSceneLoaded = true
            needsOverlayResetOnNextSceneLoaded = false
            syncContentAfterSceneLoaded(resetOverlays: shouldResetOverlays)
        }

        private func syncContentAfterSceneLoaded(resetOverlays: Bool) {
            if resetOverlays {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.markerController?.clear()
                    await self.polylineController?.clear()
                    await self.polygonController?.clear()
                    await self.circleController?.clear()
                    await self.groundImageController?.clear()
                    await self.rasterLayerController?.clear()
                    // The clears above bypass the overlay collectors, which still
                    // hold their membership. Reset them so the following
                    // syncContent re-adds the overlays instead of seeing "no
                    // change" and skipping the repopulate after a scene reload.
                    self.overlayScope?.clear()
                    self.syncContent(self.latestContent)
                }
            } else {
                syncContent(latestContent)
            }
        }

        private func handleTap(origin: Point2D, point: GeoPoint) -> Bool {
            // Marker event dispatch is delegated through HereMarkerEventController
            let screenPoint = CGPoint(x: origin.x, y: origin.y)
            if markerEventController?.handleTap(at: screenPoint) == true {
                return true
            }
            if handleStrategyMarkerTap(at: screenPoint) {
                return true
            }
            if circleController?.handleTap(at: point) == true {
                return true
            }
            if polylineController?.handleTap(at: point) == true {
                return true
            }
            if polygonController?.handleTap(at: point) == true {
                return true
            }
            if groundImageController?.handleTap(at: point) == true {
                return true
            }
            return false
        }

        private func handleStrategyMarkerTap(at screenPoint: CGPoint) -> Bool {
            guard let mapView, let controller = strategyMarkerController else { return false }
            let state = HereMarkerHitTest.find(
                at: screenPoint,
                in: mapView,
                states: controller.markerManager.allEntities().map(\.state).filter(\.clickable),
                defaultIcon: DefaultMarkerIcon()
            )
            guard let state else { return false }
            controller.dispatchClick(state)
            return true
        }

        private func notifyMapLoadedIfNeeded() {
            performMapLoadedOnce {
                controller?.notifyMapInitialized()
                onMapLoaded?(state)
            }
        }
    }
}
