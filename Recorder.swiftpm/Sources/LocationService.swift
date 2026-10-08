import AVFoundation
import CoreLocation
import ImageIO
import SwiftUI

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CaptureLocation?
    @Published private(set) var status = "等待定位授权"
    private let manager = CLLocationManager()
    private var enabled = false
    private var foreground = true

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }
    func setEnabled(_ value: Bool, foreground: Bool = true) {
        enabled = value
        self.foreground = foreground
        guard value, foreground else {
            manager.stopUpdatingLocation()
            latest = nil
            status = value ? "定位已暂停" : "定位信息已关闭"
            return
        }
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String,
              !purpose.isEmpty else { status = "运行环境未加载定位权限声明"; return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        updateAuthorization()
    }
    private func updateAuthorization() {
        guard enabled, foreground else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            status = latest == nil ? "正在获取拍摄位置…" : "已取得拍摄位置"
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            latest = nil
            status = "定位未获授权，拍摄不含位置"
        case .notDetermined: status = "等待定位授权"
        @unknown default: status = "定位暂不可用"
        }
    }
    func snapshot() -> CaptureLocation? {
        guard enabled, let latest = latest, Date().timeIntervalSince(latest.timestamp) < 60,
              latest.horizontalAccuracy >= 0 else { return nil }
        return latest
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateAuthorization() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) < 60 else { return }
        let value = CaptureLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                    altitude: fix.altitude, horizontalAccuracy: fix.horizontalAccuracy,
                                    verticalAccuracy: fix.verticalAccuracy, timestamp: fix.timestamp)
        Task { @MainActor [weak self] in
            guard let self = self, self.enabled, self.foreground else { return }
            self.latest = value
            self.status = "定位精度约 \(Int(value.horizontalAccuracy)) 米"
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.status = "暂未取得位置，拍摄仍可继续" }
    }
}

extension CaptureLocation {
    var clLocation: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: altitude,
                   horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy, timestamp: timestamp)
    }
    var gpsMetadata: [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        let date = formatter.string(from: timestamp)
        formatter.dateFormat = "HH:mm:ss.SSSSSS"
        var result: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSDateStamp as String: date,
            kCGImagePropertyGPSTimeStamp as String: formatter.string(from: timestamp),
            kCGImagePropertyGPSHPositioningError as String: horizontalAccuracy
        ]
        if verticalAccuracy >= 0 {
            result[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            result[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return [kCGImagePropertyGPSDictionary as String: result]
    }
    var movieMetadata: [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue as NSString
        item.value = iso6709 as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }
}
