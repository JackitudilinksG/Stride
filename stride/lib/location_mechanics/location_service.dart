import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'sensor_usage.dart';
import 'package:sensors_plus/sensors_plus.dart';

class LocationService {
  StreamSubscription<Position>? _positionStream;

  final LocationSettings _settings = const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
  );

  // Call this once at app startup — configures the foreground service
  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sprout_tracking',
        channelName: 'Sprout Run Tracking',
        channelDescription: 'Keeps GPS active during your run',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,       // ← prevents CPU sleep killing the stream
        allowWifiLock: true,
      ),
    );
  }

  Future<bool> handlePermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('PERMISSIONS: Location service disabled');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    debugPrint('PERMISSIONS: Current permission = $permission');

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      debugPrint('PERMISSIONS: After request = $permission');
      if (permission == LocationPermission.denied) return false;
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('PERMISSIONS: Denied forever — opening settings');
      await Geolocator.openAppSettings();
      return false;
    }

    await FlutterForegroundTask.requestIgnoreBatteryOptimization();

    debugPrint('PERMISSIONS: Granted = $permission');
    return true;
  }

  Future<void> startTracking(Function(Position) onPositionUpdate) async {
    debugPrint('DEBUG: startTracking() called — opening stream');

    // Start the foreground service BEFORE opening the GPS stream
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Sprout is tracking your run',
      notificationText: 'Tap to return to the app',
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: _settings)
        .listen(
          (Position position) {
        debugPrint('DEBUG: raw position received — ${position.latitude}, accuracy: ${position.accuracy}m');
        onPositionUpdate(position);
      },
      onError: (e) => debugPrint('DEBUG: stream error — $e'),
      onDone: () => debugPrint('DEBUG: stream closed'),
    );

    debugPrint('DEBUG: stream subscription created');
  }

  Future<void> stopTracking() async {
    _positionStream?.cancel();
    _positionStream = null;

    // Stop the foreground service when run ends
    await FlutterForegroundTask.stopService();
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  final service = LocationService();
  ref.onDispose(() => service.stopTracking());
  return service;
});

// This class defines the state
class RunSessionState {
  final bool isRunning;
  final List<Position> breadcrumbs;
  final double distanceMeters;
  final DateTime? startTime;

  const RunSessionState({
    this.isRunning = false,
    this.breadcrumbs = const [],
    this.distanceMeters = 0.0,
    this.startTime,
  });

  RunSessionState copyWith({
    bool? isRunning,
    List<Position>? breadcrumbs,
    double? distanceMeters,
    DateTime? startTime,
  }) {
    return RunSessionState(
      isRunning: isRunning ?? this.isRunning,
      breadcrumbs: breadcrumbs ?? this.breadcrumbs,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      startTime: startTime ?? this.startTime,
    );
  }

  double get currentPace {
    if (startTime == null || distanceMeters == 0) return 0;
    final elapsed = DateTime.now().difference(startTime!).inSeconds;
    return elapsed / (distanceMeters / 1000);
  }

  Duration get timeElapsed {
    if (startTime == null) return Duration.zero;
    return DateTime.now().difference(startTime!);
  }
}

// NOTIFIER — Riverpod 2.x pattern
/// This class utilises the RunSession state definition
/// This class defines methods that can be used for a run session
class RunSessionNotifier extends Notifier<RunSessionState> {
  Timer? _ticker;
  Timer? _deadReckoningTimer;

  final GpsKalmanFilter _kalman = GpsKalmanFilter();
  final DeadReckoningEngine _deadReckoning = DeadReckoningEngine();

  // Sensor stream subscriptions
  StreamSubscription? _accelSubscription;
  StreamSubscription? _gyroSubscription;

  // Track GPS health
  DateTime? _lastGpsTime;
  static const _gpsTimeoutSeconds = 5;

  @override
  RunSessionState build() {
    ref.onDispose(() {
      _ticker?.cancel();
      _deadReckoningTimer?.cancel();
      _accelSubscription?.cancel();
      _gyroSubscription?.cancel();
      _kalman.reset();
      _deadReckoning.reset();
    });
    return const RunSessionState();
  }

  void startRun() async {
    debugPrint('DEBUG: startRun() called');
    _kalman.reset();
    _deadReckoning.reset();

    state = state.copyWith(
      isRunning: true,
      startTime: DateTime.now(),
      breadcrumbs: [],
      distanceMeters: 0.0,
    );

    // Start GPS tracking
    await ref.read(locationServiceProvider).startTracking(_onNewPosition);

    // Start reading accelerometer — feeds into dead reckoning
    _accelSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      _deadReckoning.updateAccelerometer(event.x, event.y, event.z);
    });

    // Start reading gyroscope — feeds heading into dead reckoning
    _gyroSubscription = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      _deadReckoning.updateGyroscope(event.x, event.y, event.z);
    });

    // Dead reckoning timer — fires every 500ms to project position
    // when GPS hasn't updated recently
    _deadReckoningTimer = Timer.periodic(
      const Duration(milliseconds: 500), (_) => _onDeadReckoningTick(),
    );

    // UI refresh ticker
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isRunning) state = state.copyWith();
    });
  }

  void _onDeadReckoningTick() {
    if (!state.isRunning || _lastGpsTime == null) return;

    final secondsSinceGps =
        DateTime.now().difference(_lastGpsTime!).inSeconds;

    // Only activate dead reckoning if GPS has gone quiet
    if (secondsSinceGps < _gpsTimeoutSeconds) return;

    final result = _deadReckoning.project(DateTime.now());
    if (result == null || result.confidence < 0.2) return;

    debugPrint(
        'DEAD RECKONING (${secondsSinceGps}s since GPS) → '
            'lat: ${result.latitude.toStringAsFixed(6)}, '
            'lng: ${result.longitude.toStringAsFixed(6)}, '
            'confidence: ${(result.confidence * 100).toStringAsFixed(0)}%'
    );

    // Add an estimated breadcrumb — tagged so you know it's not real GPS
    // You'll use this to fill the path on the map during signal loss
    _addBreadcrumb(
      lat: result.latitude,
      lng: result.longitude,
      isEstimated: true,
    );
  }

  void _onNewPosition(Position position) {
    if (position.accuracy > 50) {
      debugPrint('REJECTED: accuracy ${position.accuracy}m');
      return;
    }

    _lastGpsTime = DateTime.now(); // mark last good GPS time

    // Update Kalman filter
    _kalman.update(
      position.latitude,
      position.longitude,
      position.accuracy,
      position.timestamp.millisecondsSinceEpoch,
    );

    // Anchor dead reckoning to this confirmed GPS fix
    _deadReckoning.anchorToGps(
      _kalman.latitude,
      _kalman.longitude,
      position.speed,        // m/s — geolocator provides this
      position.heading,      // degrees — geolocator provides this
    );

    if (state.breadcrumbs.isNotEmpty) {
      final last = state.breadcrumbs.last;
      final timeDiff =
          position.timestamp.difference(last.timestamp).inSeconds;
      final dist = Geolocator.distanceBetween(
        last.latitude, last.longitude,
        _kalman.latitude, _kalman.longitude,
      );

      if (timeDiff > 0 && (dist / timeDiff) > 12) {
        debugPrint('REJECTED: impossible speed');
        return;
      }

      _addBreadcrumb(
        lat: _kalman.latitude,
        lng: _kalman.longitude,
        isEstimated: false,
        distanceToAdd: dist,
      );
    } else {
      // First point
      _addBreadcrumb(
        lat: _kalman.latitude,
        lng: _kalman.longitude,
        isEstimated: false,
      );
    }
  }

  void _addBreadcrumb({
    required double lat,
    required double lng,
    required bool isEstimated,
    double distanceToAdd = 0.0,
  }) {
    // Create a synthetic Position for storage
    final point = Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: isEstimated ? -1 : 0, // -1 flags estimated points
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

    state = state.copyWith(
      breadcrumbs: [...state.breadcrumbs, point],
      distanceMeters: state.distanceMeters + distanceToAdd,
    );
  }

  void stopRun() async {
    _ticker?.cancel();
    _deadReckoningTimer?.cancel();
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _ticker = null;
    _deadReckoningTimer = null;
    await ref.read(locationServiceProvider).stopTracking();
    state = state.copyWith(isRunning: false);
  }

  void reset() async {
    _ticker?.cancel();
    _deadReckoningTimer?.cancel();
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _kalman.reset();
    _deadReckoning.reset();
    _lastGpsTime = null;
    _ticker = null;
    _deadReckoningTimer = null;
    await ref.read(locationServiceProvider).stopTracking();
    state = const RunSessionState();
  }
}

// PROVIDERS
/// This function provides a stream of position data, based on the distance filter
final positionStreamProvider = StreamProvider<Position>((ref) {
  return Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    ),
  );
});

// NotifierProvider replaces StateNotifierProvider
// The syntax is NotifierProvider<NotifierClass, StateClass>
final runSessionProvider = NotifierProvider<RunSessionNotifier, RunSessionState>(
  RunSessionNotifier.new,
);

class GpsKalmanFilter {
  double _lat = 0, _lng = 0;
  double _variance = -1; // negative = uninitialised

  // How much we trust new GPS points vs our existing estimate.
  // Higher = trust new points more (noisier but more responsive)
  // Lower  = trust existing estimate more (smoother but lags)
  static const double _minAccuracy = 1.0;

  void update(double lat, double lng, double accuracy, int timestampMs) {
    // Clamp accuracy floor — GPS never reports below ~3m realistically
    final acc = accuracy < _minAccuracy ? _minAccuracy : accuracy;

    if (_variance < 0) {
      // First point — initialise the filter
      _lat = lat;
      _lng = lng;
      _variance = acc * acc;
      return;
    }

    // Kalman gain — how much weight to give the new measurement
    final newVariance = _variance + (acc * acc);
    final gain = _variance / newVariance;

    // Blend the existing estimate with the new measurement
    _lat = _lat + gain * (lat - _lat);
    _lng = _lng + gain * (lng - _lng);
    _variance = (1 - gain) * _variance;
  }

  double get latitude  => _lat;
  double get longitude => _lng;

  void reset() => _variance = -1;
}