import heresdk
import MapConductorCore
import SwiftUI
import UIKit

public struct HereMapView: View {
    @ObservedObject private var state: HereMapViewState

    private let onMapLoaded: OnMapLoadedHandler<HereMapViewState>?
    private let onMapClick: OnMapEventHandler?
    private let onMapLongClick: OnMapEventHandler?
    private let onCameraMoveStart: OnCameraMoveHandler?
    private let onCameraMove: OnCameraMoveHandler?
    private let onCameraMoveEnd: OnCameraMoveHandler?
    private let sdkInitialize: (() -> Void)?
    private let content: () -> MapViewContent

    public init(
        state: HereMapViewState,
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
        self.onMapLoaded = onMapLoaded
        self.onMapClick = onMapClick
        self.onMapLongClick = onMapLongClick
        self.onCameraMoveStart = onCameraMoveStart
        self.onCameraMove = onCameraMove
        self.onCameraMoveEnd = onCameraMoveEnd
        self.sdkInitialize = sdkInitialize
        self.content = content
    }

    public var body: some View {
        let mapContent = content()
        return ZStack {
            HereMapViewRepresentable(
                state: state,
                onMapLoaded: onMapLoaded,
                onMapClick: onMapClick,
                onMapLongClick: onMapLongClick,
                onCameraMoveStart: onCameraMoveStart,
                onCameraMove: onCameraMove,
                onCameraMoveEnd: onCameraMoveEnd,
                sdkInitialize: sdkInitialize,
                content: mapContent
            )
            ForEach(0..<mapContent.views.count, id: \.self) { index in
                mapContent.views[index]
            }
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

    let onMapLoaded: OnMapLoadedHandler<HereMapViewState>?
    let onMapClick: OnMapEventHandler?
    let onMapLongClick: OnMapEventHandler?
    let onCameraMoveStart: OnCameraMoveHandler?
    let onCameraMove: OnCameraMoveHandler?
    let onCameraMoveEnd: OnCameraMoveHandler?
    let sdkInitialize: (() -> Void)?
    let content: MapViewContent

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            onMapLoaded: onMapLoaded,
            onMapClick: onMapClick,
            onMapLongClick: onMapLongClick,
            onCameraMoveStart: onCameraMoveStart,
            onCameraMove: onCameraMove,
            onCameraMoveEnd: onCameraMoveEnd
        )
    }

    func makeUIView(context: Context) -> HereMapWrapperView {
        if let sdkInitialize {
            Coordinator.runOnce(sdkInitialize)
        }

        let mapView = MapView(frame: .zero)
        let wrapper = HereMapWrapperView(
            mapView: mapView,
            overlayContainer: context.coordinator.infoBubbleContainer
        )

        context.coordinator.mapView = mapView
        context.coordinator.bind(state: state, mapView: mapView)
        context.coordinator.updateContent(content)
        context.coordinator.loadInitialScene()

        return wrapper
    }

    func updateUIView(_ uiView: HereMapWrapperView, context: Context) {
        context.coordinator.updateMapDesignIfNeeded()
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: HereMapWrapperView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.mapView.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        private static var hasInitializedSdk = false

        private let state: HereMapViewState
        private let onMapLoaded: OnMapLoadedHandler<HereMapViewState>?
        private let onMapClick: OnMapEventHandler?
        private let onMapLongClick: OnMapEventHandler?
        private let onCameraMoveStart: OnCameraMoveHandler?
        private let onCameraMove: OnCameraMoveHandler?
        private let onCameraMoveEnd: OnCameraMoveHandler?

        weak var mapView: MapView?
        private var controller: HereMapViewController?
        private var markerController: HereMarkerController?
        private var polylineController: HerePolylineController?
        private var polygonController: HerePolygonController?
        private var circleController: HereCircleController?
        private var groundImageController: HereGroundImageController?
        private var rasterLayerController: HereRasterLayerController?
        private var infoBubbleCoordinator: InfoBubbleOverlayCoordinator?
        fileprivate let infoBubbleContainer = PassthroughContainerView()
        private var loadedMapScheme: MapScheme?
        private var latestContent = MapViewContent()
        private var isSceneLoaded = false
        private var needsOverlayResetOnNextSceneLoaded = false
        private var didCallMapLoaded = false

        init(
            state: HereMapViewState,
            onMapLoaded: OnMapLoadedHandler<HereMapViewState>?,
            onMapClick: OnMapEventHandler?,
            onMapLongClick: OnMapEventHandler?,
            onCameraMoveStart: OnCameraMoveHandler?,
            onCameraMove: OnCameraMoveHandler?,
            onCameraMoveEnd: OnCameraMoveHandler?
        ) {
            self.state = state
            self.onMapLoaded = onMapLoaded
            self.onMapClick = onMapClick
            self.onMapLongClick = onMapLongClick
            self.onCameraMoveStart = onCameraMoveStart
            self.onCameraMove = onCameraMove
            self.onCameraMoveEnd = onCameraMoveEnd
        }

        static func runOnce(_ initializer: () -> Void) {
            if hasInitializedSdk { return }
            hasInitializedSdk = true
            initializer()
        }

        func bind(state: HereMapViewState, mapView: MapView) {
            infoBubbleContainer.backgroundColor = .clear
            infoBubbleContainer.isUserInteractionEnabled = true

            let controller = HereMapViewController(mapView: mapView)
            self.controller = controller
            state.setController(controller)
            state.setMapViewHolder(controller.holder)

            let markerController = HereMarkerController(mapView: mapView)
            let polylineController = HerePolylineController(mapView: mapView)
            let polygonController = HerePolygonController(mapView: mapView)
            let circleController = HereCircleController(mapView: mapView)
            let groundImageController = HereGroundImageController(mapView: mapView)
            let rasterLayerController = HereRasterLayerController(mapView: mapView)
            self.markerController = markerController
            self.polylineController = polylineController
            self.polygonController = polygonController
            self.circleController = circleController
            self.groundImageController = groundImageController
            self.rasterLayerController = rasterLayerController

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

            controller.setMapClickListener(listener: onMapClick)
            controller.setMapLongClickListener(listener: onMapLongClick)
            controller.setCameraMoveStartListener { [weak self] position in
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMoveStart?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
            }
            controller.setCameraMoveListener { [weak self] position in
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMove?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
            }
            controller.setCameraMoveEndListener { [weak self] position in
                self?.state.updateCameraPosition(position)
                self?.polylineController?.setCurrentCameraPosition(position)
                self?.onCameraMoveEnd?(position)
                self?.infoBubbleCoordinator?.updateAllLayouts()
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
                self?.markerController?.handleLongPress(state: state, origin: origin) ?? false
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
            groundImageController?.syncGroundImages(content.groundImages)
            rasterLayerController?.syncRasterLayers(content.rasterLayers)
            polylineController?.syncPolylines(content.polylines)
            polygonController?.syncPolygons(content.polygons)
            circleController?.syncCircles(content.circles)
            infoBubbleCoordinator?.updateAllLayouts()
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
            markerController?.unbind()
            markerController = nil
            polylineController?.unbind()
            polylineController = nil
            polygonController?.unbind()
            polygonController = nil
            circleController?.unbind()
            circleController = nil
            groundImageController?.unbind()
            groundImageController = nil
            rasterLayerController?.unbind()
            rasterLayerController = nil
            infoBubbleCoordinator?.unbind()
            infoBubbleCoordinator = nil
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
                    self.syncContent(self.latestContent)
                }
            } else {
                syncContent(latestContent)
            }
        }

        private func handleTap(origin: Point2D, point: GeoPoint) -> Bool {
            let screenPoint = CGPoint(x: origin.x, y: origin.y)
            if markerController?.handleTap(at: screenPoint) == true {
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

        private func notifyMapLoadedIfNeeded() {
            guard !didCallMapLoaded else { return }
            didCallMapLoaded = true
            onMapLoaded?(state)
        }
    }
}
