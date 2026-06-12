# HERE SDK for MapConductor iOS

## Description

MapConductor provides a unified API for iOS SwiftUI.
You can use HERE view with SwiftUI, but you can also switch to other Maps SDKs (such as MapLibre, MapKit, and so on), anytime.
Even using the wrapper API, you can still access the native HERE view if you want.

## Setup

https://docs-ios.mapconductor.com/setup/here/

## Usage

```swift
import SwiftUI
import MapConductorCore
import MapConductorForHERE

struct MapView: View {
    @StateObject private var mapViewState = HereMapViewState(
        cameraPosition: MapCameraPosition(
            position: GeoPoint(latitude: 35.6762, longitude: 139.6503),
            zoom: 2
        )
    )
    @State private var selectedMarker: MarkerState? = nil

    let center = GeoPoint(latitude: 35.6762, longitude: 139.6503)

    var body: some View {
        HereMapView(state: mapViewState) {
            Marker(
                position: center,
                icon: DefaultMarkerIcon(label: "Tokyo"),
                onClick: { state in selectedMarker = state }
            )
            if let selected = selectedMarker {
                InfoBubble(marker: selected) {
                    Text("Hello, world!")
                }
            }
        }
    }
}
```

![](docs/images/basic-setup-here.png)


## Components

### HereMapView [[docs]](https://docs-ios.mapconductor.com/components/mapviewcomponent/)

```swift
struct MapExample: View {
    @StateObject private var mapViewState = HereMapViewState(
        cameraPosition: MapCameraPosition(
            position: GeoPoint(latitude: 37.422198, longitude: -122.085377),
            zoom: 17,
            tilt: 60,
            bearing: 30
        )
    )

    var body: some View {
        HereMapView(state: mapViewState)
    }
}
```
![](docs/images/mapview.png)

------------------------------------------------------------------------

### Marker [[docs]](https://docs-ios.mapconductor.com/components/marker/)

```swift
struct MarkerExample: View {
    @State private var markerState = MarkerState(
        position: GeoPoint(latitude: 35.6762, longitude: 139.6503),
        icon: DefaultMarkerIcon(label: "Tokyo"),
        onClick: { state in state.animate(.bounce) }
    )

    var body: some View {
        HereMapView(state: mapViewState) {
            Marker(state: markerState)
        }
    }
}
```
![](docs/images/marker.png)

------------------------------------------------------------------------

### InfoBubble [[docs]](https://docs-ios.mapconductor.com/components/infobubble/)

```swift
struct InfoBubbleExample: View {
    @State private var selectedMarker: MarkerState? = nil
    @State private var markerState = MarkerState(
        position: GeoPoint(latitude: 35.6762, longitude: 139.6503),
        onClick: { [self] state in selectedMarker = state }
    )

    var body: some View {
        HereMapView(state: mapViewState) {
            Marker(state: markerState)
            if let selected = selectedMarker {
                InfoBubble(marker: selected) {
                    Text("Hello, world!")
                }
            }
        }
    }
}
```
![](docs/images/infobubble.png)

------------------------------------------------------------------------

### Circle [[docs]](https://docs-ios.mapconductor.com/components/circle/)

```swift
struct CircleExample: View {
    var body: some View {
        HereMapView(state: mapViewState) {
            Circle(
                center: GeoPoint(latitude: 35.6762, longitude: 139.6503),
                radiusMeters: 50,
                fillColor: UIColor.blue.withAlphaComponent(0.5),
                onClick: { state in
                    state.fillColor = UIColor.red.withAlphaComponent(0.5)
                }
            )
        }
    }
}
```
![](docs/images/circle.png)

------------------------------------------------------------------------

### Polyline [[docs]](https://docs-ios.mapconductor.com/components/polyline/)

```swift
struct PolylineExample: View {
    var body: some View {
        HereMapView(state: mapViewState) {
            Polyline(
                points: airports,
                strokeColor: UIColor.blue.withAlphaComponent(0.5),
                geodesic: true
            )
        }
    }
}
```
![](docs/images/polyline.png)

------------------------------------------------------------------------

### Polygon [[docs]](https://docs-ios.mapconductor.com/components/polygon/)

```swift
struct PolygonExample: View {
    var body: some View {
        HereMapView(state: mapViewState) {
            Polygon(
                points: goryokaku,
                strokeColor: UIColor.red.withAlphaComponent(0.5),
                fillColor: UIColor.red.withAlphaComponent(0.7)
            )
        }
    }
}
```
![](docs/images/polygon.png)

------------------------------------------------------------------------

### Polygon Hole

```swift
struct PolygonHoleExample: View {
    var body: some View {
        HereMapView(state: mapViewState) {
            Polygon(
                points: outerPoints,
                holes: [innerPoints1, innerPoints2],
                fillColor: UIColor(red: 0.47, green: 0.47, blue: 0.50, alpha: 0.8),
                strokeColor: UIColor.red,
                strokeWidth: 2
            )
        }
    }
}
```
![](docs/images/polygon-hole.png)

------------------------------------------------------------------------

### GroundImage [[docs]](https://docs-ios.mapconductor.com/components/groundimage/)

```swift
struct GroundImageExample: View {
    var body: some View {
        HereMapView(state: mapViewState) {
            GroundImage(
                bounds: GeoRectBounds(
                    southWest: GeoPoint.fromLatLong(...),
                    northEast: GeoPoint.fromLatLong(...)
                ),
                image: uiImage,
                opacity: 0.5
            )
        }
    }
}
```
![](docs/images/groundimage.png)
