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
    private let style: MapViewStyle?
    private let onStyleDiagnostics: (([String]) -> Void)?
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
        /// How the map looks, when the app states it rather than naming a
        /// design. `MapConductorVectorStyle` builds one; what happens
        /// underneath depends on this backend and the app does not have to
        /// know.
        style: MapViewStyle? = nil,
        onStyleDiagnostics: (([String]) -> Void)? = nil,
        @MapViewContentBuilder content: @escaping () -> MapViewContent = { MapViewContent() }
    ) {
        self.state = state
        self.projection = projection
        self.cameraRestriction = cameraRestriction
        self.style = style
        self.onStyleDiagnostics = onStyleDiagnostics
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
                style: style,
                onStyleDiagnostics: onStyleDiagnostics,
                content: mapContent
            )
        }
    }
}

final class HereMapWrapperView: UIView {
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
    let style: MapViewStyle?
    let onStyleDiagnostics: (([String]) -> Void)?
    let content: MapViewContent

    // 地図の組み立てと結線は `HereMapHost` が持つ。ここは SwiftUI のライフサイクルを
    // ホストの呼び出しへ翻訳するだけ。
    func makeCoordinator() -> HereMapHost {
        HereMapHost(state: state, handlers: handlers)
    }

    func makeUIView(context: Context) -> HereMapWrapperView {
        context.coordinator.makeWrapperView(
            projection: projection,
            cameraRestriction: cameraRestriction,
            content: content
        )
    }

    func updateUIView(_ uiView: HereMapWrapperView, context: Context) {
        // Every evaluation of the app's `body` lands here; most calls do
        // nothing. See `MapViewStyleHost.apply`.
        context.coordinator.applyStyle(style, onDiagnostics: onStyleDiagnostics)
        // 制限値が変わったときだけ再適用する。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        context.coordinator.updateMapDesignIfNeeded()
        context.coordinator.updateGestures(state.uiSettings)
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: HereMapWrapperView, coordinator: HereMapHost) {
        coordinator.disposeStyle()
        coordinator.unbind()
        uiView.mapView.pause()
    }
}
