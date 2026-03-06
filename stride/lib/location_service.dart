import 'dart:async';
import 'package:geolocator/geolocator.dart';

/// Stride LocationService for capturing real-time breadcrumbs (FR2)
class LocationService {
  StreamSubscription<Position>? _positionStream;

  final LocationSettings _settings = const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5, // Capture every 5 meters
  );

  /// Check and request permissions before starting (PRD Requirement)
  Future<bool> handlePermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }

    if (permission == LocationPermission.deniedForever) return false;
    return true;
  }

  /// Start real-time tracking (FR2: Real-time map updates)
  void startTracking(Function(Position) onPositionUpdate) {
    _positionStream = Geolocator.getPositionStream(locationSettings: _settings)
        .listen((Position position) {
      // Logic for POC: Send position back to UI/Controller
      onPositionUpdate(position);
    });
  }

  /// Stop tracking and cleanup
  void stopTracking() {
    _positionStream?.cancel();
    _positionStream = null;
  }
}