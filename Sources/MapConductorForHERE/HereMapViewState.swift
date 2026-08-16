import Combine
import Foundation
import MapConductorCore

/// HERE の state。
///
/// カメラの保持と委譲、`uiSettings`、`id` はコアの ``MapViewState`` が持つ。
/// ここに残るのは **HERE 固有のもの**だけ。`mapDesignType` の setter が
/// メインアクターでシーンを差し替えに行くところが他プロバイダと違う。
public final class HereMapViewState: MapViewState<HereMapDesignType> {
    @Published private var _mapDesignType: HereMapDesignType

    /// Provider-typed holder: `mapView` is `MapView`, `map` is `MapScene`, no cast needed.
    public private(set) var mapViewHolder: HereViewHolder?

    public override var mapDesignType: HereMapDesignType {
        get { _mapDesignType }
        set {
            _mapDesignType = newValue
            if let controller = attachedMapController as? HereMapViewController {
                let design = newValue
                Task { @MainActor in
                    controller.setMapDesignType(design)
                }
            }
        }
    }

    public init(
        id: String,
        mapDesignType: HereMapDesignType = HereMapDesign.NormalDay,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self._mapDesignType = mapDesignType
        super.init(id: id, initialCameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    public convenience init(
        mapDesignType: HereMapDesignType = HereMapDesign.NormalDay,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self.init(id: UUID().uuidString, mapDesignType: mapDesignType, cameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    /// アプリが `state.getMapViewHolder()?.map` で `MapScene` を取れる形を保つための絞り込み。
    public override func getMapViewHolder() -> AnyMapViewHolder? {
        mapViewHolder.map { AnyMapViewHolder($0) }
    }

    func setController(_ controller: (any MapViewControllerProtocol)?) {
        attachController(controller)
    }

    func setMapViewHolder(_ holder: HereViewHolder?) {
        mapViewHolder = holder
    }

    func updateCameraPosition(_ cameraPosition: MapCameraPosition) {
        setCameraPositionInternal(cameraPosition)
    }

    /// 地図側からデザインが変わったことを受け取る（setter を経由せず保持だけ更新する）。
    func onMapDesignTypeChange(_ value: HereMapDesignType) {
        _mapDesignType = value
    }
}

public typealias HereViewState = HereMapViewState
