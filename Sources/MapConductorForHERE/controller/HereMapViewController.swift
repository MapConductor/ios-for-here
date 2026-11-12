import Foundation
import heresdk
@_spi(MapConductorDriver) import MapConductorCore

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
    let typedHolder: HereViewHolder
    let coroutine = CoroutineScope()

    /// この地図に紐づくオーバーレイコントローラの登録簿。
    /// 拡張モジュール（ヒートマップ、マーカークラスタリング等）がここに登録して
    /// カメラ変更を受け取る。`MapViewControllerProtocol` の要件。
    let overlayControllers = OverlayControllerRegistry()

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
    /// 最後に指定されたパディング。パディングはカメラの主点を動かさず、中心をずらして
    /// 再現し（``CameraPaddingEmulation``）、読み戻しで逆にずらすときに使う。
    /// android-for-here と同じ。主点はアニメーションの最初で一気に切り替わるため使わない。
    private var lastPaddings: MapPaddingsProtocol?
    private var cameraMoveEndTask: Task<Void, Never>?

    /// HERE はネイティブのカメラ範囲制限 API を持たないため、android-for-here と同じく
    /// カメラ停止時に矩形内へクランプして再適用する方式で制限する。
    private let cameraRestrictionClamp = CameraRestrictionClamp()
    private var cameraMoveInProgress = false
    private var isAnimatingCamera = false
    private var lastCameraPosition: MapCameraPosition?

    private static let cameraMoveEndIdleNanoseconds: UInt64 = 120_000_000

    init(mapView: MapView) {
        let hereHolder = HereViewHolder(mapView: mapView)
        self.hereHolder = hereHolder
        self.typedHolder = hereHolder
        self.holder = AnyMapViewHolder(hereHolder)
        super.init()
        setupListeners()
    }

    deinit {
        cameraMoveEndTask?.cancel()
    }

    /// ``clearOverlays()`` の中身。オーバーレイのコントローラはホストが持っているので、
    /// ホストが生成時に設定する（android-sdk と同じく、各コントローラの `clear()` を呼ぶ）。
    var clearOverlaysHandler: (@MainActor () async -> Void)?

    func clearOverlays() async {
        await clearOverlaysHandler?()
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

    func setCameraRestriction(_ restriction: CameraRestriction?) {
        cameraRestrictionClamp.set(restriction)
    }

    func moveCamera(position: MapCameraPosition) {
        let requested = rememberPaddings(position)
        lastRequestedCameraPosition = requested
        hereHolder.mapView.camera.applyUpdate(paddingApplied(requested).toMapCameraUpdate())
        scheduleCorrection(requested)
    }

    /// `paddings` が `nil` なら今のパディングを引き継ぎ、指定されていれば覚える。
    private func rememberPaddings(_ position: MapCameraPosition) -> MapCameraPosition {
        if let paddings = position.paddings { lastPaddings = paddings }
        return position.copy(paddings: lastPaddings ?? MapPaddings.Zeros)
    }

    /// HERE へ渡すカメラ。パディングの分だけ中心をずらす。
    private func paddingApplied(_ position: MapCameraPosition) -> MapCameraPosition {
        CameraPaddingEmulation.applied(
            to: position,
            fov: hereVerticalFieldOfView,
            viewportSize: hereHolder.mapView.bounds.size
        )
    }

    /// 補正の世代。新しい移動が始まったら、前の移動の補正は捨てる。
    private var correctionGeneration = 0

    /// 補正は地図がカメラを描き終えてから測る（applyUpdate の直後は投影がまだ古い）。
    private func scheduleCorrection(_ requested: MapCameraPosition) {
        correctionGeneration += 1
        let generation = correctionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.correctPaddedTarget(requested, generation: generation)
        }
    }

    /// 計算で置いた中心は、HERE の縮尺や tilt の扱いが計算と違うとずれる。地図の投影で
    /// 実際の位置を測り、パディングの残りの中央に来るまで中心だけを動かし直す。
    /// 1 回ごとに反映を待ってから測り直す。
    private func correctPaddedTarget(_ requested: MapCameraPosition, generation: Int, remaining: Int = 4) {
        guard remaining > 0, generation == correctionGeneration else { return }
        let holder = hereHolder
        guard let center = CameraPaddingEmulation.correctedCenter(
            target: requested.position,
            paddings: requested.paddings,
            viewportSize: holder.mapView.bounds.size,
            project: { holder.toScreenOffset(position: $0) },
            unproject: { holder.fromScreenOffsetSync(offset: $0) }
        ) else { return }
        holder.mapView.camera.lookAt(point: center.toGeoCoordinates())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.correctPaddedTarget(requested, generation: generation, remaining: remaining - 1)
        }
    }

    /// HERE から読み戻したカメラ（中心）を、ターゲット・パディング・視野角を持つカメラへ戻す。
    private func reportedCamera(_ state: MapCamera.State) -> MapCameraPosition {
        let holder = hereHolder
        return CameraPaddingEmulation.restored(
            state.toMapCameraPosition(
                logicalTiltHint: lastRequestedCameraPosition?.tilt,
                visibleRegion: visibleRegion()
            ),
            paddings: lastPaddings,
            fov: hereVerticalFieldOfView,
            viewportSize: holder.mapView.bounds.size,
            unproject: { holder.fromScreenOffsetSync(offset: $0) }
        )
    }

    func animateCamera(position: MapCameraPosition, duration: Long) {
        let requested = rememberPaddings(position)
        lastRequestedCameraPosition = requested
        let display = paddingApplied(requested).toHereDisplayCamera()
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

    func fitBounds(bounds: GeoRectBounds, padding: Int) {
        guard let geoBox = bounds.toGeoBox() else { return }
        let mapView = hereHolder.mapView
        // HERE frames a GeoBox into a viewport Rectangle2D. Insetting that rectangle on every side
        // reserves empty margin, which is what `padding` requests. `viewportSize` is in physical
        // pixels while the shared `padding` is in points (the point-based unit the other providers
        // feed to their UIEdgeInsets), so scale by `pixelScale` for cross-provider parity — the same
        // point<->pixel conversion HereMarkerRenderer already relies on.
        let scale = mapView.pixelScale
        let viewport = mapView.viewportSize
        let width = viewport.width > 0 ? viewport.width : mapView.bounds.width * scale
        let height = viewport.height > 0 ? viewport.height : mapView.bounds.height * scale
        let insetPx = max(0.0, Double(padding) * scale)
        // Never let the padded rectangle collapse to zero/negative area.
        let horizontalInset = min(insetPx, max(0.0, (width - 1.0) / 2.0))
        let verticalInset = min(insetPx, max(0.0, (height - 1.0) / 2.0))
        let viewRectangle = Rectangle2D(
            origin: Point2D(x: horizontalInset, y: verticalInset),
            size: Size2D(width: width - 2.0 * horizontalInset, height: height - 2.0 * verticalInset)
        )
        let cameraUpdate = MapCameraUpdateFactory.lookAt(area: geoBox, viewRectangle: viewRectangle)
        mapView.camera.applyUpdate(cameraUpdate)
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
        let mapCameraPosition = reportedCamera(cameraState)
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
            // 範囲・ズーム制限に違反していれば矩形内へ引き戻す（HERE はネイティブの範囲制限 API が
            // 無いため）。再適用すると onMapCameraUpdated が再発火し、そこでは補正不要になり
            // 通常フローへ進む。android-for-here と同一仕様。
            if let corrected = self.cameraRestrictionClamp.correction(for: lastCameraPosition) {
                self.moveCamera(position: corrected)
                return
            }
            self.cameraMoveInProgress = false
            // 登録済みオーバーレイ（拡張モジュール含む）へ伝播する。
            self.overlayControllers.dispatchCameraChanged(lastCameraPosition)
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
            if let current = reportedCamera(hereHolder.mapView.camera.state) as MapCameraPosition? {
                cameraMoveStartListener?(current)
            }
        case .completed:
            isAnimatingCamera = false
            if let position = lastRequestedCameraPosition {
                scheduleCorrection(position)
                overlayControllers.dispatchCameraChanged(position)
                cameraMoveEndListener?(position)
            }
        case .cancelled:
            isAnimatingCamera = false
            overlayControllers.dispatchCameraChanged(
                reportedCamera(hereHolder.mapView.camera.state)
            )
            cameraMoveEndListener?(
                reportedCamera(hereHolder.mapView.camera.state)
            )
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
