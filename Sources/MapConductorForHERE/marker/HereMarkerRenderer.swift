import heresdk
@_spi(MapConductorDriver) import MapConductorCore
import QuartzCore
import UIKit

@MainActor
final class HereMarkerRenderer: MarkerOverlayRendererProtocol, MarkerDrawOrderFrameReceiver {
    typealias ActualMarker = MapMarker

    private static let maxConcurrentAnimations = 30

    private weak var mapView: MapView?
    private var markerAnimationRunners: [String: MarkerAnimationRunner] = [:]
    /// Content hash of the last icon applied to each marker. Used to avoid
    /// rebuilding/reassigning the underlying MapImage when only the position changed
    /// (e.g. during a drag or a SwiftUI body re-evaluation that creates new icon objects
    /// with identical content).
    private var appliedIconHashes: [String: Int] = [:]

    var animateStartListener: OnMarkerEventHandler?
    var animateEndListener: OnMarkerEventHandler?

    // ── 重なり順 ────────────────────────────────────────────────
    //
    // HERE の `drawOrder` は大きな値を黙って捨てる（android の実機で 2849 は効き、4274 は足した順に
    // 戻った。iPad Pro 11 でも帯の底を 4274 にすると足した順に戻った）。zIndex × 段数 のような符号化はできないので、地図に載っているマーカーを
    // ``MarkerDrawOrder`` の順に並べ、順位（0...``maxDrawOrderRank``）を帯の底からの drawOrder にする。
    // 順位にしたので、同じ zIndex の中の順（画面で下・左ほど手前）も付けられる。

    /// 順位の上限。帯の底（約 450）に足しても android で効いた値に収まる。マーカーがこれより多いと
    /// 順位を詰めて割り当てる（近い順位どうしが同じ値になる）。
    static let maxDrawOrderRank = 2_047
    /// マーカー帯の底。ほかの帯（ポリゴン・サークル・ポリライン）の drawOrder はこれより小さい。
    private static let drawOrderBase = Int32(
        OverlayBand.marker.rawValue * HereOverlayStacking.drawOrderBandStride
            - HereOverlayStacking.drawOrderBandStride / 2
    )

    private var drawOrderFrame: MarkerDrawOrder.Frame = .northUp
    /// 地図に載っているマーカーと、その順位を出した state。
    private var placed: [String: (marker: MapMarker, state: MarkerState)] = [:]
    /// 順位が変わりうる変更があった（足した・外した・zIndex か位置が変わった）。
    private var needsRestack = false

    /// When set, drop/bounce animations run on the screen-space overlay layer
    /// (projection-independent: correct on tilted/rotated/globe views); the
    /// native marker stays hidden (opacity 0) for the duration.
    var animationOverlay: MarkerAnimationOverlayCoordinator?

    init(mapView: MapView?) {
        self.mapView = mapView
    }

    func onAdd(data: [MarkerOverlayAddParams]) async -> [MapMarker?] {
        guard let mapView else { return [] }
        return data.map { params in
            let bitmapIcon = params.bitmapIcon
            let state = params.state
            guard let pngData = bitmapIcon.bitmap.pngData() else { return nil }
            let width = UInt32(bitmapIcon.bitmap.cgImage?.width ?? Int(bitmapIcon.size.width))
            let height = UInt32(bitmapIcon.bitmap.cgImage?.height ?? Int(bitmapIcon.size.height))
            let image = MapImage(imageData: pngData, imageFormat: .png, width: width, height: height)
            let marker = MapMarker(
                at: state.position.toGeoCoordinates(),
                image: image,
                anchor: bitmapIcon.toHereAnchor()
            )
            marker.drawOrder = Self.drawOrderBase
            marker.opacity = (state.getAnimation() != nil && markerAnimationRunners[state.id] == nil) ? 0.0 : 1.0
            appliedIconHashes[state.id] = iconContentHash(pngData, bitmapIcon)
            placed[state.id] = (marker, state)
            needsRestack = true
            mapView.mapScene.addMapMarker(marker)
            return marker
        }
    }

    func onChange(data: [MarkerOverlayChangeParams<MapMarker>]) async -> [MapMarker?] {
        data.map { params in
            guard let marker = params.prev.marker else { return nil }
            let state = params.current.state
            apply(state: state, bitmapIcon: params.bitmapIcon, to: marker)
            if let previous = placed[state.id]?.state,
               previous.zIndex == state.zIndex,
               previous.position.latitude == state.position.latitude,
               previous.position.longitude == state.position.longitude {
                placed[state.id] = (marker, state)
            } else {
                placed[state.id] = (marker, state)
                needsRestack = true
            }
            return marker
        }
    }

    func onRemove(data: [MarkerEntity<MapMarker>]) async {
        guard let mapView else { return }
        for entity in data {
            markerAnimationRunners[entity.state.id]?.stop()
            markerAnimationRunners.removeValue(forKey: entity.state.id)
            appliedIconHashes.removeValue(forKey: entity.state.id)
            placed.removeValue(forKey: entity.state.id)
            if let marker = entity.marker {
                mapView.mapScene.removeMapMarker(marker)
            }
        }
    }

    func onAnimate(entity: MarkerEntity<MapMarker>) async {
        guard markerAnimationRunners[entity.state.id] == nil else { return }
        guard let animation = entity.state.getAnimation() else { return }

        // Preferred path: animate the marker image on the screen-space overlay.
        // Projection-independent, so tilt/rotation/globe views stay correct.
        // The native marker was added with opacity 0 (pending animation);
        // reveal it at the target when the overlay finishes.
        if let overlay = animationOverlay, let marker = entity.marker {
            marker.opacity = 0.0
            animateStartListener?(entity.state)
            let icon = (entity.state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
            let target = entity.state.position
            overlay.start(MarkerAnimationOverlayEntry(
                id: entity.state.id,
                state: entity.state,
                icon: icon,
                animation: animation,
                duration: animation == .Bounce ? 2.0 : 0.3,
                onFinished: { [weak self] in
                    marker.coordinates = target.toGeoCoordinates()
                    marker.opacity = 1.0
                    entity.state.animate(nil)
                    self?.animateEndListener?(entity.state)
                }
            ))
            return
        }

        switch animation {
        case .Drop:
            await animateMarker(entity: entity, animation: .Drop, duration: Settings.Default.markerDropAnimateInterval)
        case .Bounce:
            await animateMarker(entity: entity, animation: .Bounce, duration: Settings.Default.markerBounceAnimateInterval)
        }
    }

    func onPostProcess() async {
        if needsRestack { restack() }
    }

    func onDrawOrderFrameChanged(_ frame: MarkerDrawOrder.Frame, entities: [MarkerEntity<MapMarker>]) async {
        drawOrderFrame = frame
        restack()
    }

    /// 地図に載っているマーカーを ``MarkerDrawOrder`` の順に並べ、順位を drawOrder に書く。
    private func restack() {
        needsRestack = false
        let frame = drawOrderFrame
        let ordered = placed.values
            .map { (key: MarkerDrawOrder.key(zIndex: $0.state.zIndex, position: $0.state.position, frame: frame), marker: $0.marker) }
            .sorted { $0.key < $1.key }
        let last = max(ordered.count - 1, 1)
        for (rank, entry) in ordered.enumerated() {
            let scaled = ordered.count > Self.maxDrawOrderRank + 1 ? rank * Self.maxDrawOrderRank / last : rank
            let order = Self.drawOrderBase + Int32(scaled)
            if entry.marker.drawOrder != order { entry.marker.drawOrder = order }
        }
    }

    func unbind() {
        markerAnimationRunners.values.forEach { $0.stop() }
        markerAnimationRunners.removeAll()
        appliedIconHashes.removeAll()
        placed.removeAll()
        mapView = nil
    }

    private func apply(state: MarkerState, bitmapIcon: BitmapIcon, to marker: MapMarker) {
        marker.coordinates = state.position.toGeoCoordinates()
        marker.anchor = bitmapIcon.toHereAnchor()
        marker.opacity = (state.getAnimation() != nil && markerAnimationRunners[state.id] == nil) ? 0.0 : 1.0

        // Only rebuild and reassign the MapImage when the icon content actually changed.
        // Reassigning marker.image on every update forces HERE to reload the marker texture;
        // during panning (SwiftUI body re-evaluations create new icon objects each frame)
        // that makes markers flicker. We hash the PNG bytes so two separately allocated
        // UIImage objects with identical pixels are treated as equal.
        guard let data = bitmapIcon.bitmap.pngData() else { return }
        let iconHash = iconContentHash(data, bitmapIcon)
        if appliedIconHashes[state.id] != iconHash {
            let width = UInt32(bitmapIcon.bitmap.cgImage?.width ?? Int(bitmapIcon.size.width))
            let height = UInt32(bitmapIcon.bitmap.cgImage?.height ?? Int(bitmapIcon.size.height))
            let image = MapImage(imageData: data, imageFormat: .png, width: width, height: height)
            marker.image = image
            appliedIconHashes[state.id] = iconHash
        }
    }

    private func iconContentHash(_ data: Data, _ bitmapIcon: BitmapIcon) -> Int {
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(bitmapIcon.anchor.x)
        hasher.combine(bitmapIcon.anchor.y)
        hasher.combine(bitmapIcon.debug)
        return hasher.finalize()
    }

    private func animateMarker(
        entity: MarkerEntity<MapMarker>,
        animation: MarkerAnimation,
        duration: CFTimeInterval
    ) async {
        guard let mapView, let marker = entity.marker else { return }

        if markerAnimationRunners.count >= Self.maxConcurrentAnimations {
            applyImmediatePosition(for: entity, to: marker)
            return
        }

        let target = entity.state.position
        guard let targetPoint = mapView.geoToViewCoordinates(geoCoordinates: target.toGeoCoordinates()),
              isVisible(point: targetPoint, in: mapView) else {
            applyImmediatePosition(for: entity, to: marker)
            return
        }

        let startPoint = Point2D(x: targetPoint.x, y: animationStartY(in: mapView))
        guard let startGeoPoint = mapView.viewToGeoCoordinates(viewCoordinates: startPoint)?.toGeoPoint() else {
            applyImmediatePosition(for: entity, to: marker)
            return
        }

        marker.coordinates = startGeoPoint.toGeoCoordinates()
        marker.opacity = 1.0
        animateStartListener?(entity.state)

        let pathPoints = animation == .Bounce
            ? bouncePath(for: mapView, target: target)
            : MarkerAnimationRunner.makeLinearPath(start: startGeoPoint, target: target)

        let runner = MarkerAnimationRunner(
            duration: duration,
            pathPoints: pathPoints,
            onUpdate: { point in
                marker.coordinates = point.toGeoCoordinates()
            },
            onCompletion: { [weak self] in
                marker.coordinates = target.toGeoCoordinates()
                marker.opacity = 1.0
                entity.state.animate(nil)
                self?.markerAnimationRunners[entity.state.id] = nil
                self?.animateEndListener?(entity.state)
            }
        )
        markerAnimationRunners[entity.state.id] = runner
        runner.start()
    }

    private func applyImmediatePosition(for entity: MarkerEntity<MapMarker>, to marker: MapMarker) {
        marker.coordinates = entity.state.position.toGeoCoordinates()
        marker.opacity = 1.0
        entity.state.animate(nil)
        animateEndListener?(entity.state)
    }

    private func bouncePath(for mapView: MapView, target: GeoPoint) -> [GeoPoint] {
        guard let targetPoint = mapView.geoToViewCoordinates(geoCoordinates: target.toGeoCoordinates()) else {
            return [target]
        }

        let startY = animationStartY(in: mapView)
        let distance = targetPoint.y - startY
        var point = targetPoint
        var path: [GeoPoint] = []

        path.append(geoPoint(for: Point2D(x: targetPoint.x, y: startY), in: mapView) ?? target)

        var coefficient = 0.5
        point.y = startY + distance * coefficient

        while coefficient > 0 {
            if let geoPoint = geoPoint(for: point, in: mapView) {
                path.append(geoPoint)
            }

            point.y = startY + distance
            if let geoPoint = geoPoint(for: point, in: mapView) {
                path.append(geoPoint)
            }

            coefficient -= 0.15
            point.y = startY + (distance - distance * max(coefficient, 0))
        }

        path.append(target)
        return path
    }

    private func geoPoint(for point: Point2D, in mapView: MapView) -> GeoPoint? {
        mapView.viewToGeoCoordinates(viewCoordinates: point)?.toGeoPoint()
    }

    private func isVisible(point: Point2D, in mapView: MapView) -> Bool {
        let viewport = mapView.viewportSize
        let width = viewport.width > 0 ? viewport.width : mapView.bounds.width * mapView.pixelScale
        let height = viewport.height > 0 ? viewport.height : mapView.bounds.height * mapView.pixelScale
        return point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height
    }

    private func animationStartY(in mapView: MapView) -> Double {
        let viewportHeight = mapView.viewportSize.height > 0 ? mapView.viewportSize.height : mapView.bounds.height * mapView.pixelScale
        return -max(32.0 * mapView.pixelScale, viewportHeight * 0.2)
    }

}

private extension BitmapIcon {
    func toHereAnchor() -> Anchor2D {
        Anchor2D(horizontal: Double(anchor.x), vertical: Double(anchor.y))
    }
}
