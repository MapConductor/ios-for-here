import heresdk
import MapConductorCore
import QuartzCore
import UIKit

@MainActor
final class HereMarkerRenderer: MarkerOverlayRendererProtocol {
    typealias ActualMarker = MapMarker

    private static let maxConcurrentAnimations = 30

    private weak var mapView: MapView?
    private var markerAnimationRunners: [String: MarkerAnimationRunner] = [:]

    var animateStartListener: OnMarkerEventHandler?
    var animateEndListener: OnMarkerEventHandler?

    init(mapView: MapView?) {
        self.mapView = mapView
    }

    func onAdd(data: [MarkerOverlayAddParams]) async -> [MapMarker?] {
        guard let mapView else { return [] }
        return data.map { params in
            guard let image = makeMapImage(params.bitmapIcon) else { return nil }
            let marker = MapMarker(
                at: params.state.position.toGeoCoordinates(),
                image: image,
                anchor: params.bitmapIcon.toHereAnchor()
            )
            apply(state: params.state, bitmapIcon: params.bitmapIcon, to: marker)
            mapView.mapScene.addMapMarker(marker)
            return marker
        }
    }

    func onChange(data: [MarkerOverlayChangeParams<MapMarker>]) async -> [MapMarker?] {
        data.map { params in
            guard let marker = params.prev.marker else { return nil }
            apply(state: params.current.state, bitmapIcon: params.bitmapIcon, to: marker)
            return marker
        }
    }

    func onRemove(data: [MarkerEntity<MapMarker>]) async {
        guard let mapView else { return }
        for entity in data {
            markerAnimationRunners[entity.state.id]?.stop()
            markerAnimationRunners.removeValue(forKey: entity.state.id)
            if let marker = entity.marker {
                mapView.mapScene.removeMapMarker(marker)
            }
        }
    }

    func onAnimate(entity: MarkerEntity<MapMarker>) async {
        guard markerAnimationRunners[entity.state.id] == nil else { return }
        guard let animation = entity.state.getAnimation() else { return }

        switch animation {
        case .Drop:
            await animateMarker(entity: entity, animation: .Drop, duration: 0.3)
        case .Bounce:
            await animateMarker(entity: entity, animation: .Bounce, duration: 2.0)
        }
    }

    func onPostProcess() async {}

    func unbind() {
        markerAnimationRunners.values.forEach { $0.stop() }
        markerAnimationRunners.removeAll()
        mapView = nil
    }

    private func apply(state: MarkerState, bitmapIcon: BitmapIcon, to marker: MapMarker) {
        marker.coordinates = state.position.toGeoCoordinates()
        marker.anchor = bitmapIcon.toHereAnchor()
        marker.drawOrder = 10
        marker.opacity = (state.getAnimation() != nil && markerAnimationRunners[state.id] == nil) ? 0.0 : 1.0
        if let image = makeMapImage(bitmapIcon) {
            marker.image = image
        }
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

    private func makeMapImage(_ bitmapIcon: BitmapIcon) -> MapImage? {
        guard let data = bitmapIcon.bitmap.pngData() else { return nil }
        let width = UInt32(bitmapIcon.bitmap.cgImage?.width ?? Int(bitmapIcon.size.width))
        let height = UInt32(bitmapIcon.bitmap.cgImage?.height ?? Int(bitmapIcon.size.height))
        return MapImage(imageData: data, imageFormat: .png, width: width, height: height)
    }
}

private extension BitmapIcon {
    func toHereAnchor() -> Anchor2D {
        Anchor2D(horizontal: Double(anchor.x), vertical: Double(anchor.y))
    }
}
