import 'dart:math';
import 'package:vector_math/vector_math.dart';

class DeadReckoningEngine {
  // Last confirmed good GPS fix
  double _lastGoodLat = 0;
  double _lastGoodLng = 0;
  DateTime? _lastGoodTime;

  // Current estimated state
  double _estimatedLat = 0;
  double _estimatedLng = 0;
  double _estimatedSpeedMs = 0;  // metres per second
  double _headingDegrees = 0;    // 0 = North, 90 = East, 180 = South, 270 = West

  // Sensor readings (updated continuously from streams)
  double _accelX = 0, _accelY = 0, _accelZ = 0;
  double _gyroZ = 0; // rotation around vertical axis = change in heading

  bool _isActive = false;

  // Called continuously from accelerometer stream
  void updateAccelerometer(double x, double y, double z) {
    _accelX = x;
    _accelY = y;
    _accelZ = z;
  }

  // Called continuously from gyroscope stream
  void updateGyroscope(double x, double y, double z) {
    // z axis = rotation around vertical = turning left/right
    _gyroZ = z;
  }

  // Called every time a good GPS fix arrives — anchors the dead reckoning
  void anchorToGps(double lat, double lng, double speedMs, double headingDeg) {
    _lastGoodLat = lat;
    _lastGoodLng = lng;
    _lastGoodTime = DateTime.now();
    _estimatedLat = lat;
    _estimatedLng = lng;
    _estimatedSpeedMs = speedMs;
    _headingDegrees = headingDeg;
    _isActive = true;
  }

  // Called every ~100ms when GPS is unavailable — projects position forward
  DeadReckoningResult? project(DateTime now) {
    if (!_isActive || _lastGoodTime == null) return null;

    final dt = now.difference(_lastGoodTime!).inMilliseconds / 1000.0; // seconds

    // Estimate speed from accelerometer magnitude
    // Subtract gravity (9.81 m/s²) from the vertical component
    final horizontalAccel = sqrt(_accelX * _accelX + _accelY * _accelY);

    // Smooth speed — don't let it spike from a single noisy reading
    // A step causes ~2-4 m/s² of horizontal acceleration
    // Clamp between 0 and sprint speed (10 m/s)
    final newSpeed = (_estimatedSpeedMs + horizontalAccel * 0.1).clamp(0.0, 10.0);
    _estimatedSpeedMs = newSpeed;

    // Update heading from gyroscope
    // gyroZ is radians/second — convert to degrees and accumulate
    _headingDegrees += degrees(_gyroZ) * dt;
    _headingDegrees = _headingDegrees % 360; // keep in 0-360

    // Project new position using heading and speed
    // Uses the haversine inverse — given a start point, distance, and bearing,
    // calculate the destination point
    final newPos = _projectPosition(
      _estimatedLat,
      _estimatedLng,
      _estimatedSpeedMs * dt, // distance = speed × time
      _headingDegrees,
    );

    _estimatedLat = newPos[0];
    _estimatedLng = newPos[1];
    _lastGoodTime = now; // advance the clock for next projection

    return DeadReckoningResult(
      latitude: _estimatedLat,
      longitude: _estimatedLng,
      speedMs: _estimatedSpeedMs,
      headingDegrees: _headingDegrees,
      confidence: _calculateConfidence(dt),
    );
  }

  // Confidence decays over time — the longer since last GPS fix, the less
  // reliable the dead reckoning estimate becomes
  double _calculateConfidence(double secondsSinceLastFix) {
    // 100% at 0s, ~50% at 10s, ~10% at 30s
    return max(0.0, 1.0 - (secondsSinceLastFix / 30.0));
  }

  // Haversine inverse formula — projects a point from start + distance + bearing
  List<double> _projectPosition(
      double lat, double lng, double distanceMeters, double bearingDegrees) {
    const earthRadius = 6371000.0; // metres

    final latRad = radians(lat);
    final lngRad = radians(lng);
    final bearingRad = radians(bearingDegrees);
    final angularDist = distanceMeters / earthRadius;

    final newLat = asin(
      sin(latRad) * cos(angularDist) +
          cos(latRad) * sin(angularDist) * cos(bearingRad),
    );

    final newLng = lngRad + atan2(
      sin(bearingRad) * sin(angularDist) * cos(latRad),
      cos(angularDist) - sin(latRad) * sin(newLat),
    );

    return [degrees(newLat), degrees(newLng)];
  }

  void reset() {
    _isActive = false;
    _estimatedSpeedMs = 0;
    _headingDegrees = 0;
    _lastGoodTime = null;
  }
}

class DeadReckoningResult {
  final double latitude;
  final double longitude;
  final double speedMs;
  final double headingDegrees;
  final double confidence; // 0.0 to 1.0

  const DeadReckoningResult({
    required this.latitude,
    required this.longitude,
    required this.speedMs,
    required this.headingDegrees,
    required this.confidence,
  });
}