import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ---------------------------------------------------------------------------
// Camera constants — Samsung S22 rear wide-angle lens
// ---------------------------------------------------------------------------

const double kHFovDeg = 69.0;
const double kVFovDeg = 52.0;

// ---------------------------------------------------------------------------
// PhoneOrientation
// ---------------------------------------------------------------------------

class PhoneOrientation {
  final double compassBearing; // 0–360°, 0 = North
  final double pitchDeg;       // 0 = flat, 90 = pointing at sky
  final double rollDeg;

  const PhoneOrientation({
    required this.compassBearing,
    required this.pitchDeg,
    required this.rollDeg,
  });

  static const PhoneOrientation unknown =
      PhoneOrientation(compassBearing: 0, pitchDeg: 45, rollDeg: 0);
}

// ---------------------------------------------------------------------------
// PhoneLocation
// ---------------------------------------------------------------------------

class PhoneLocation {
  final double latitude;
  final double longitude;
  final double altitudeM;
  final double speedMps;
  final double headingDeg;
  final double accuracyM;

  const PhoneLocation({
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    required this.accuracyM,
  });

  static const PhoneLocation unknown = PhoneLocation(
    latitude: 0, longitude: 0, altitudeM: 0,
    speedMps: 0, headingDeg: 0, accuracyM: 9999,
  );

  bool get isValid => accuracyM < 30;
}

// ---------------------------------------------------------------------------
// ObjectTelemetry
// ---------------------------------------------------------------------------

class ObjectTelemetry {
  final double bearingDeg;
  final double elevationDeg;
  final String cardinal;
  final double distanceM;
  final double speedMps;
  final PhoneLocation phoneLocation;
  final ({double lat, double lng, double alt})? absolutePosition;

  const ObjectTelemetry({
    required this.bearingDeg,
    required this.elevationDeg,
    required this.cardinal,
    required this.distanceM,
    required this.speedMps,
    required this.phoneLocation,
    this.absolutePosition,
  });

  static String cardinalFromBearing(double deg) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((deg + 22.5) ~/ 45) % 8];
  }
}

// ---------------------------------------------------------------------------
// SensorService singleton
// ---------------------------------------------------------------------------

class SensorService {
  SensorService._();
  static final SensorService instance = SensorService._();

  static const double _refBboxAreaPx = 300.0;
  static const double _refDistanceM  = 10.0;
  static const double _modelPx       = 320.0;

  // Throttle: fuse() runs at most every 50 ms (20 Hz) regardless of sensor rate
  static const int _fusePeriodMs = 50;
  int _lastFuseMs = 0;

  PhoneOrientation _orientation = PhoneOrientation.unknown;
  PhoneLocation    _location    = PhoneLocation.unknown;

  List<double> _accel  = [0, 0, -9.8];
  List<double> _magnet = [0, 30, -60];

  StreamSubscription? _accelSub;
  StreamSubscription? _magnetSub;
  StreamSubscription? _gpsSub;
  bool _running = false;

  PhoneOrientation get orientation => _orientation;
  PhoneLocation    get location    => _location;

  // -------------------------------------------------------------------------
  // Start / stop
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((e) {
      _accel = [e.x, e.y, e.z];
      _fuse();
    }, onError: (_) {});

    _magnetSub = magnetometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((e) {
      _magnet = [e.x, e.y, e.z];
      _fuse();
    }, onError: (_) {});

    await _startGps();
  }

  Future<void> _startGps() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).listen((pos) {
        _location = PhoneLocation(
          latitude:   pos.latitude,
          longitude:  pos.longitude,
          altitudeM:  pos.altitude,
          speedMps:   pos.speed,
          headingDeg: pos.heading,
          accuracyM:  pos.accuracy,
        );
      }, onError: (_) {});
    } catch (e) {
      debugPrint('GPS start error: $e');
    }
  }

  Future<void> stop() async {
    await _accelSub?.cancel();
    await _magnetSub?.cancel();
    await _gpsSub?.cancel();
    _accelSub = _magnetSub = _gpsSub = null;
    _running = false;
  }

  // -------------------------------------------------------------------------
  // Tilt-compensated compass fusion — throttled to _fusePeriodMs
  //
  // Without throttling this fires on every sensor event (~100+ Hz on some
  // devices) which causes unnecessary CPU load. 20 Hz is more than adequate
  // for compass heading used in telemetry.
  //
  // Algorithm (equivalent to Android SensorManager.getRotationMatrix):
  //   1. Normalise gravity vector from accelerometer
  //   2. East  = gravity × magnetic  (cross product)
  //   3. North = East × gravity
  //   4. Bearing = atan2(East_x, North_x)
  //   5. Pitch  = asin(−gy_normalised)
  //   6. Roll   = atan2(gx, −gz)
  // -------------------------------------------------------------------------

  void _fuse() {
    // Throttle to avoid excessive CPU use
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFuseMs < _fusePeriodMs) return;
    _lastFuseMs = now;

    final ax = _accel[0], ay = _accel[1], az = _accel[2];
    final mx = _magnet[0], my = _magnet[1], mz = _magnet[2];

    final aNorm = sqrt(ax * ax + ay * ay + az * az);
    if (aNorm < 0.5) return; // sensor not ready
    final gx = ax / aNorm, gy = ay / aNorm, gz = az / aNorm;

    // East = gravity × magnetic
    final ex = gy * mz - gz * my;
    final ey = gz * mx - gx * mz;
    final ez = gx * my - gy * mx;
    final eNorm = sqrt(ex * ex + ey * ey + ez * ez);
    if (eNorm < 0.1) return;
    final exN = ex / eNorm;
    final eyN = ey / eNorm;
    final ezN = ez / eNorm;

    // North = East × gravity
    final nx = eyN * gz - ezN * gy;
    final ny = ezN * gx - exN * gz; // used below in bearing

    // Bearing: project East and North onto the horizontal reference plane.
    // atan2(East_component, North_component) gives azimuth clockwise from North.
    final bearing = (atan2(exN - eyN, nx - ny) * 180 / pi + 360) % 360;

    final pitchDeg = asin(-gy.clamp(-1.0, 1.0)) * 180 / pi;
    final rollDeg  = atan2(gx, -gz) * 180 / pi;

    _orientation = PhoneOrientation(
      compassBearing: bearing,
      pitchDeg:       pitchDeg,
      rollDeg:        rollDeg,
    );
  }

  // -------------------------------------------------------------------------
  // Compute sensor-corrected object telemetry
  // -------------------------------------------------------------------------

  ObjectTelemetry computeObjectTelemetry({
    required double cx,
    required double cy,
    required double w,
    required double h,
    required double apparentSpeedMps,
    double zoomLevel = 1.0,
  }) {
    final o   = _orientation;
    final loc = _location;

    // Effective FoV narrows as zoom increases
    final effectiveHFov = kHFovDeg / zoomLevel;
    final effectiveVFov = kVFovDeg / zoomLevel;

    // True bearing to object
    final hOffset = (cx - 0.5) * effectiveHFov;
    final bearing = (o.compassBearing + hOffset + 360) % 360;

    // Elevation
    final vOffset   = (0.5 - cy) * effectiveVFov;
    final elevation = o.pitchDeg + vOffset;

    // Distance (bbox area heuristic)
    final areaPx = w * _modelPx * h * _modelPx;
    final distM  = areaPx > 0
        ? sqrt(_refBboxAreaPx / areaPx) * _refDistanceM
        : 0.0;

    // Speed corrected for phone lateral motion
    double correctedSpeed = apparentSpeedMps.abs();
    if (loc.isValid && loc.speedMps > 0.1 && distM > 1.0) {
      final angleDiffRad = (loc.headingDeg - o.compassBearing) * pi / 180;
      final phoneLateralMps = loc.speedMps * sin(angleDiffRad);
      correctedSpeed = max(0.0, apparentSpeedMps - phoneLateralMps);
    }

    // Estimated absolute GPS position
    ({double lat, double lng, double alt})? absPos;
    if (loc.isValid && distM > 0.5) {
      final bearingRad = bearing   * pi / 180;
      final elevRad    = elevation * pi / 180;
      final groundDist = distM * cos(elevRad);
      final vertDist   = distM * sin(elevRad);
      final cosLat     = cos(loc.latitude * pi / 180);
      final dLat = (groundDist * cos(bearingRad)) / 111111;
      final dLng = (groundDist * sin(bearingRad)) /
                   (111111 * cosLat.abs().clamp(0.001, 1.0));
      absPos = (
        lat: loc.latitude  + dLat,
        lng: loc.longitude + dLng,
        alt: loc.altitudeM + vertDist,
      );
    }

    return ObjectTelemetry(
      bearingDeg:       bearing,
      elevationDeg:     elevation,
      cardinal:         ObjectTelemetry.cardinalFromBearing(bearing),
      distanceM:        distM,
      speedMps:         correctedSpeed,
      phoneLocation:    loc,
      absolutePosition: absPos,
    );
  }
}