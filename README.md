# MapConductor for HERE

HERE Maps provider for the MapConductor unified mapping API, built on the HERE SDK
(Explore Edition) for iOS.

## Description

MapConductor provides a unified API for iOS SwiftUI.
You can use HERE Maps with SwiftUI, but you can also switch to other Maps SDKs (such as
MapLibre, Google Maps, and so on) at any time using the same API surface.
Even using the wrapper API, you can still access the native HERE view if you want.

## Setup

https://docs-ios.mapconductor.com/setup/here-maps/

The HERE SDK is a binary `xcframework` wired in as a `.binaryTarget` (see `Package.swift`);
it is not fetched from a public package registry. Initialize it once, before any map view
is created:

```swift
import MapConductorForHERE

try initializeHERE(
    accessKeyId: "YOUR_HERE_ACCESS_KEY_ID",
    accessKeySecret: "YOUR_HERE_ACCESS_KEY_SECRET"
)
```

`initializeHERE` throws — surface the error rather than discarding it, since a failed
initialization only shows up later, as a blank map.

## Usage

```swift
import SwiftUI
import MapConductorCore
import MapConductorForHERE

struct ContentView: View {
    @StateObject private var mapState = HereMapViewState(
        mapDesignType: HereMapDesign.NormalDay,
        cameraPosition: MapCameraPosition(
            position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
            zoom: 12
        )
    )

    var body: some View {
        HereMapView(state: mapState) {
            Marker(
                position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
                icon: DefaultMarkerIcon(label: "Tokyo")
            )
        }
        .ignoresSafeArea()
    }
}
```

## Supported overlays

Marker (custom icons, click, drag, and tiled rendering for large marker sets), Polyline,
Polygon (holes supported), Circle, GroundImage, RasterLayer and InfoBubble.

## Available designs

`HereMapDesign` maps onto HERE's map schemes, mostly in day/night pairs:
`NormalDay`, `NormalNight`, `Satellite`, `HybridDay`, `HybridNight`, `LiteDay`,
`LiteNight`, `LiteHybridDay`, `LiteHybridNight`, `LogisticsDay`, `LogisticsNight`,
`LogisticsHybridDay`, `LogisticsHybridNight`, `RoadNetworkDay`, `RoadNetworkNight`.

## Files

| File | Role |
| --- | --- |
| `HereMapView.swift` | SwiftUI view, camera/interaction callbacks, InfoBubble wiring |
| `HereMapViewState.swift` | `HereMapViewState` (camera, design, controller) |
| `HereSDKConfiguration.swift` | `initializeHERE(accessKeyId:accessKeySecret:)` |
| `HereMapDesign.swift` | Map schemes |
| `controller/` | Camera control and `MapViewHolder` over the native HERE view |
| `marker/` | Native marker rendering, events, drag, hit-testing |
| `polyline/` / `polygon/` / `circle/` | Vector overlay controllers and renderers |
| `groundimage/` / `raster/` | Ground images and raster tile layers |
| `ZoomAltitudeConverter.swift` | Unified zoom ↔ HERE-native conversion |

## Implementation notes

- **Polygon holes**: the HERE SDK does not reliably draw `MapPolygon` inner boundaries (the
  same conclusion `android-for-here` reached), and a keyhole-bridged ring self-overlaps so a
  semi-transparent fill double-blends over the hole. The fill is therefore split by the shared
  core `splitPolygonWithHolesIntoSimpleRings` into hole-free simple rings, one `MapPolygon`
  each; the pieces are disjoint, so no double-blending. Outlines (outer ring and each hole) are
  drawn separately as stroke-only polygons, because a piece boundary contains the split bridges.
  Both platforms use this same approach. It replaced an earlier raster-tile mask.
- **Marker tiling**: static markers are batched into raster tiles once the marker count
  passes `MarkerTilingOptions.minMarkerCount`. Draggable and animating markers stay as
  native markers so they remain interactive.
- **Marker drag**: HERE exposes no getter for gesture state, so the view pushes the current
  `uiSettings.scrollGesture` value down to the marker controller; restoring panning after a
  drag honours that value instead of unconditionally re-enabling it.
