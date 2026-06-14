import Foundation
import heresdk
import MapConductorCore

typealias HereMapDesignTypeChangeHandler = (HereMapDesignType) -> Void
typealias HereSceneLoadedHandler = () -> Void

@MainActor
final class HereMapViewController: NSObject,
    @preconcurrency MapViewControllerProtocol,
    @preconcurrency MapCameraDelegate,
    @preconcurrency TapDelegate,
    @preconcurrency PanDelegate,
    @preconcurrency LongPressDelegate,
    @preconcurrency AnimationDelegate {
    let holder: AnyMapViewHolder
    let coroutine = CoroutineScope()

    private let hereHolder: HereViewHolder
    private var cameraMoveStartListener: OnCameraMoveHandler?
    private var cameraMoveListener: OnCameraMoveHandler?
    private var cameraMoveEndListener: OnCameraMoveHandler?
    private var mapClickListener: OnMapEventHandler?
    private var mapLongClickListener: OnMapEventHandler?
    private var mapInitializedListener: OnMapInitializedHandler?
    private var tapHandler: ((Point2D, GeoPoint) -> Bool)?
    private var panHandler: ((GestureState, Point2D) -> Bool)?
    private var longPressHandler: ((GestureState, Point2D) -> Bool)?
    private var mapDesignType: HereMapDesignType = HereMapDesign.NormalDay
    private var mapDesignTypeChangeListener: HereMapDesignTypeChangeHandler?
    private var sceneLoadedHandler: HereSceneLoadedHandler?
    private var lastRequestedCameraPosition: MapCameraPosition?
    private var cameraMoveEndTask: Task<Void, Never>?
    private var cameraMoveInProgress = false
    private var isAnimatingCamera = false
    private var lastCameraPosition: MapCameraPosition?

    private static let cameraMoveEndIdleNanoseconds: UInt64 = 120_000_000

    init(mapView: MapView) {
        let hereHolder = HereViewHolder(mapView: mapView)
        self.hereHolder = hereHolder
        self.holder = AnyMapViewHolder(hereHolder)
        super.init()
        setupListeners()
    }

    deinit {
        cameraMoveEndTask?.cancel()
    }

    func clearOverlays() async {
        hereHolder.mapView.mapScene.removeAllMapItems()
    }

    func setCameraMoveStartListener(listener: OnCameraMoveHandler?) {
        cameraMoveStartListener = listener
    }

    func setCameraMoveListener(listener: OnCameraMoveHandler?) {
        cameraMoveListener = listener
    }

    func setCameraMoveEndListener(listener: OnCameraMoveHandler?) {
        cameraMoveEndListener = listener
    }

    func setMapClickListener(listener: OnMapEventHandler?) {
        mapClickListener = listener
    }

    func setMapLongClickListener(listener: OnMapEventHandler?) {
        mapLongClickListener = listener
    }

    func setMapInitializedListener(listener: OnMapInitializedHandler?) {
        mapInitializedListener = listener
    }

    func setTapHandler(_ handler: ((Point2D, GeoPoint) -> Bool)?) {
        tapHandler = handler
    }

    func setPanHandler(_ handler: ((GestureState, Point2D) -> Bool)?) {
        panHandler = handler
    }

    func setLongPressHandler(_ handler: ((GestureState, Point2D) -> Bool)?) {
        longPressHandler = handler
    }

    func moveCamera(position: MapCameraPosition) {
        lastRequestedCameraPosition = position
        hereHolder.mapView.camera.applyUpdate(position.toMapCameraUpdate())
    }

    func animateCamera(position: MapCameraPosition, duration: Long) {
        lastRequestedCameraPosition = position
        let display = position.toHereDisplayCamera()
        let animation = MapCameraAnimationFactory.flyTo(
            target: display.target.toGeoCoordinates().toUpdate(),
            orientation: GeoOrientation(bearing: display.bearing, tilt: display.tiltDeg).toUpdate(),
            zoom: MapMeasure(kind: .zoomLevel, value: display.hereZoomLevel),
            bowFactor: 1.0,
            duration: max(0.0, Double(duration) / 1000.0)
        )
        isAnimatingCamera = true
        hereHolder.mapView.camera.startAnimation(animation, animationDelegate: self)
    }

    func setMapDesignType(_ value: HereMapDesignType) {
        let scene = value.getValue()
        hereHolder.mapView.mapScene.loadScene(mapScheme: scene) { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("[MapConductor] HERE loadScene failed: %@", String(describing: error))
                return
            }
            self.mapDesignType = value
            if let cameraPosition = self.lastRequestedCameraPosition {
                self.moveCamera(position: cameraPosition)
            }
            self.mapDesignTypeChangeListener?(value)
            self.sceneLoadedHandler?()
        }
    }

    func setMapDesignTypeChangeListener(_ listener: HereMapDesignTypeChangeHandler?) {
        mapDesignTypeChangeListener = listener
        if let listener {
            listener(mapDesignType)
        }
    }

    func setSceneLoadedHandler(_ listener: HereSceneLoadedHandler?) {
        sceneLoadedHandler = listener
    }

    func onMapCameraUpdated(_ cameraState: MapCamera.State) {
        let mapCameraPosition = cameraState.toMapCameraPosition(visibleRegion: visibleRegion())
        lastCameraPosition = mapCameraPosition
        cameraMoveListener?(mapCameraPosition)

        if isAnimatingCamera { return }

        if !cameraMoveInProgress {
            cameraMoveInProgress = true
            cameraMoveStartListener?(mapCameraPosition)
        }

        cameraMoveEndTask?.cancel()
        cameraMoveEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.cameraMoveEndIdleNanoseconds)
            guard let self, let lastCameraPosition = self.lastCameraPosition else { return }
            self.cameraMoveInProgress = false
            self.cameraMoveEndListener?(lastCameraPosition)
        }
    }

    func onTap(origin: Point2D) {
        guard let point = hereHolder.mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() else { return }
        if tapHandler?(origin, point) == true { return }
        mapClickListener?(point)
    }

    func onLongPress(state: GestureState, origin: Point2D) {
        // Marker dragging consumes the whole long-press gesture (begin/update/end).
        if longPressHandler?(state, origin) == true { return }
        guard state == .begin else { return }
        guard let point = hereHolder.mapView.viewToGeoCoordinates(viewCoordinates: origin)?.toGeoPoint() else { return }
        mapLongClickListener?(point)
    }

    func onPan(state: GestureState, origin: Point2D, translation: Point2D, velocity: Double) {
        if panHandler?(state, origin) == true { return }
    }

    func onAnimationStateChanged(state: AnimationState) {
        switch state {
        case .started:
            if let current = hereHolder.mapView.camera.state.toMapCameraPosition(visibleRegion: visibleRegion()) as MapCameraPosition? {
                cameraMoveStartListener?(current)
            }
        case .completed:
            isAnimatingCamera = false
            if let position = lastRequestedCameraPosition {
                cameraMoveEndListener?(position)
            }
        case .cancelled:
            isAnimatingCamera = false
            cameraMoveEndListener?(hereHolder.mapView.camera.state.toMapCameraPosition(visibleRegion: visibleRegion()))
        @unknown default:
            isAnimatingCamera = false
        }
    }

    func notifyMapInitialized() {
        mapInitializedListener?(.MapCreated)
    }

    private func setupListeners() {
        hereHolder.mapView.camera.removeDelegate(self)
        hereHolder.mapView.camera.addDelegate(self)
        hereHolder.mapView.gestures.tapDelegate = self
        hereHolder.mapView.gestures.panDelegate = self
        hereHolder.mapView.gestures.longPressDelegate = self
    }

    private func visibleRegion() -> VisibleRegion? {
        guard let boundingBox = hereHolder.mapView.camera.boundingBox else { return nil }
        let width = hereHolder.mapView.bounds.width
        let height = hereHolder.mapView.bounds.height
        return VisibleRegion(
            bounds: boundingBox.toGeoRectBounds(),
            nearLeft: hereHolder.fromScreenOffsetSync(offset: CGPoint(x: 0.0, y: height)),
            nearRight: hereHolder.fromScreenOffsetSync(offset: CGPoint(x: width, y: height)),
            farLeft: hereHolder.fromScreenOffsetSync(offset: .zero),
            farRight: hereHolder.fromScreenOffsetSync(offset: CGPoint(x: width, y: 0.0))
        )
    }
}
