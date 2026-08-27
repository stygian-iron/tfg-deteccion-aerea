import 'dart:math';
import 'dart:ui' show Offset;

// ---------------------------------------------------------------------------
// Track states
// ---------------------------------------------------------------------------

enum TrackState { candidate, confirmed, unknown }

// ---------------------------------------------------------------------------
// TrackEvent — emitted once when a track first reaches confirmed or unknown
// ---------------------------------------------------------------------------

enum TrackEventType { newConfirmed, newUnknown }

class TrackEvent {
  final TrackEventType type;
  final String trackId;
  final String label;
  final double confidence;
  final double cx, cy, w, h;

  TrackEvent({
    required this.type,
    required this.trackId,
    required this.label,
    required this.confidence,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
  });
}

// ---------------------------------------------------------------------------
// TelemetrySnapshot — consumed by TelemetryScreen and SnapshotService
// ---------------------------------------------------------------------------

class TelemetrySnapshot {
  final String trackId;
  final String label;
  final TrackState state;
  final double cx, cy;
  final double w, h;
  final double speedMps;
  final double directionDeg;
  final double distanceM;
  final Duration timeInScene;
  final int framesAlive;
  final List<Offset> trajectory;

  const TelemetrySnapshot({
    required this.trackId,
    required this.label,
    required this.state,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.speedMps,
    required this.directionDeg,
    required this.distanceM,
    required this.timeInScene,
    required this.framesAlive,
    required this.trajectory,
  });
}

// ---------------------------------------------------------------------------
// TrackResult
// ---------------------------------------------------------------------------

class TrackResult {
  final List<TrackedObject> tracks;
  final List<TrackEvent> newEvents;
  TrackResult({required this.tracks, required this.newEvents});
}

// ---------------------------------------------------------------------------
// Internal timed position record
// ---------------------------------------------------------------------------

class _TimedPosition {
  final List<double> pos;  // [cx, cy] normalised
  final List<double> bbox; // [cx, cy, w, h] normalised
  final DateTime time;
  _TimedPosition(this.pos, this.bbox, this.time);
}

// ---------------------------------------------------------------------------
// TrackedObject
// ---------------------------------------------------------------------------

class TrackedObject {
  final int id;
  final String trackId;

  List<double> center;
  List<double> bbox;

  final List<String> _labelHistory   = [];
  final List<double> _confHistory    = [];
  final List<_TimedPosition> _posHistory = [];

  int _missedFrames = 0;
  TrackState state      = TrackState.candidate;
  TrackState _prevState = TrackState.candidate;
  String label          = '?';
  double confidence     = 0.0;
  int _framesAlive      = 0;
  final DateTime _createdAt = DateTime.now();

  // ── Tracker constants ────────────────────────────────────────────────────

  static const int    _confirmFrames = 4;
  static const int    _maxMissed     = 8;
  static const int    _historySize   = 6;
  static const double _matchRadius   = 0.15;
  static const int    _maxPosHistory = 20;

  // ── Camera & object geometry constants ───────────────────────────────────

  /// Nominal model input size (px). Distance and speed depend only on the ratio
  /// f / _modelPx (i.e. the field of view), so this stays 320 even when a
  /// confirmation model runs at 512 — the extra input resolution cancels out.
  static const double _modelPx = 320.0;

  /// Effective horizontal FoV (deg). Updated by [setEffectiveHFov] whenever the
  /// zoom level or lens changes. 69° = Samsung S22 wide lens at 1× zoom.
  static double _effectiveHFovDeg = 69.0;

  /// Focal length in pixels, derived from the effective FoV:
  ///   f = (_modelPx / 2) / tan(HFoV / 2). At 69° / 1× this is ≈ 232.6 px.
  static double _focalLengthPx = 232.6;

  /// Update the effective horizontal FoV so distance/speed stay correct across
  /// zoom levels and modes. Call from the camera layer on every zoom/mode change.
  static void setEffectiveHFov(double hFovDeg) {
    _effectiveHFovDeg = hFovDeg.clamp(1.0, 179.0);
    _focalLengthPx = (_modelPx / 2) / tan((_effectiveHFovDeg / 2) * pi / 180);
  }

  /// Reference real-world object widths (m) for the pinhole distance estimate,
  /// keyed by class label. ACKNOWLEDGED APPROXIMATIONS — class-average values.
  ///
  /// Aircraft widths vary enormously (a light plane ~11 m vs an airliner ~35 m),
  /// so absolute distance for airplane/helicopter is a rough placeholder, not a
  /// measurement. The DETECTION-RANGE benefit of large objects is real and
  /// independent of this; only the distance readout is affected.
  static const Map<String, double> _refWidthM = {
    'bird':       0.30,
    'drone':      0.26,
    'helicopter': 12.0, // ~main rotor diameter, light/medium heli
    'airplane':   18.0, // very rough class-average wingspan
  };

  // ── Kalman filter state for distance ────────────────────────────────────

  double _kfDistance = 10.0; // initial estimate (metres)
  double _kfP        = 50.0; // initial error variance

  static const double _kfQ = 0.5;  // process noise variance
  static const double _kfR = 8.0;  // measurement noise variance

  TrackedObject({
    required this.id,
    required this.trackId,
    required this.center,
    required this.bbox,
  });

  // -------------------------------------------------------------------------
  // Update — called each frame with a new detection
  // -------------------------------------------------------------------------

  TrackEvent? update(
    List<double> newCenter,
    List<double> newBbox,
    String newLabel,
    double newConf,
  ) {
    center = newCenter;
    bbox   = newBbox;
    _missedFrames = 0;
    _framesAlive++;

    _labelHistory.add(newLabel);
    _confHistory.add(newConf);
    if (_labelHistory.length > _historySize) {
      _labelHistory.removeAt(0);
      _confHistory.removeAt(0);
    }

    _posHistory.add(_TimedPosition(
      List.of(newCenter), List.of(newBbox), DateTime.now()));
    if (_posHistory.length > _maxPosHistory) _posHistory.removeAt(0);

    _prevState = state;
    _updateState();

    _updateDistanceKalman();

    final justConfirmed =
        state == TrackState.confirmed && _prevState != TrackState.confirmed;
    final justUnknown =
        state == TrackState.unknown && _prevState != TrackState.unknown;

    if (justConfirmed) {
      return TrackEvent(
        type: TrackEventType.newConfirmed, trackId: trackId, label: label,
        confidence: confidence,
        cx: bbox[0], cy: bbox[1], w: bbox[2], h: bbox[3],
      );
    }
    if (justUnknown) {
      return TrackEvent(
        type: TrackEventType.newUnknown, trackId: trackId, label: 'unknown',
        confidence: 0.0,
        cx: bbox[0], cy: bbox[1], w: bbox[2], h: bbox[3],
      );
    }
    return null;
  }

  void markMissed() => _missedFrames++;
  bool get shouldRemove => _missedFrames >= _maxMissed;

  // -------------------------------------------------------------------------
  // Pinhole camera distance estimate + 1D Kalman filter
  //   Z = (f × W) / w   (Zhang 2000; Dist-YOLO 2022)
  // -------------------------------------------------------------------------

  void _updateDistanceKalman() {
    final bboxW = bbox[2]; // normalised width (0–1)
    if (bboxW <= 0.01) return;

    // Reference width by label. If the label isn't in the table (e.g. an
    // unknown-state track), skip the update rather than invent a distance.
    final refWidthM = _refWidthM[label];
    if (refWidthM == null) return;

    final bboxWidthPx = bboxW * _modelPx;
    final rawDist = (_focalLengthPx * refWidthM) / bboxWidthPx;
    final z = rawDist.clamp(0.5, 5000.0); // aircraft can be very far

    _kfP += _kfQ;
    final K = _kfP / (_kfP + _kfR);
    _kfDistance = _kfDistance + K * (z - _kfDistance);
    _kfP = (1.0 - K) * _kfP;
  }

  // -------------------------------------------------------------------------
  // Telemetry getters
  // -------------------------------------------------------------------------

  double get distanceM => _kfDistance;

  double get speedMps {
    if (_posHistory.length < 2) return 0.0;
    final cur  = _posHistory.last;
    final prev = _posHistory[_posHistory.length - 2];
    final dt   = cur.time.difference(prev.time).inMilliseconds / 1000.0;
    if (dt <= 0) return 0.0;
    final dx = (cur.pos[0] - prev.pos[0]) * _modelPx;
    final dy = (cur.pos[1] - prev.pos[1]) * _modelPx;
    final speedPxPerS = sqrt(dx * dx + dy * dy) / dt;
    return speedPxPerS * (_kfDistance / _focalLengthPx);
  }

  double get directionDeg {
    if (_posHistory.length < 2) return 0.0;
    final cur  = _posHistory.last;
    final prev = _posHistory[_posHistory.length - 2];
    final dx = cur.pos[0] - prev.pos[0];
    final dy = cur.pos[1] - prev.pos[1];
    if (dx == 0 && dy == 0) return 0.0;
    final rad = atan2(dy, dx);
    final deg = (rad * 180 / pi + 90) % 360;
    return deg < 0 ? deg + 360 : deg;
  }

  Duration get timeInScene => DateTime.now().difference(_createdAt);
  int get framesAlive => _framesAlive;

  List<Offset> get trajectory =>
      _posHistory.map((p) => Offset(p.pos[0], p.pos[1])).toList();

  // -------------------------------------------------------------------------
  // State machine
  // -------------------------------------------------------------------------

  void _updateState() {
    if (_labelHistory.length < _confirmFrames) {
      state = TrackState.candidate;
      return;
    }
    final votes = <String, int>{};
    for (final l in _labelHistory) {
      votes[l] = (votes[l] ?? 0) + 1;
    }
    final total    = _labelHistory.length;
    final topLabel = votes.entries.reduce((a, b) => a.value > b.value ? a : b);
    final ratio    = topLabel.value / total;

    if (ratio >= 0.7) {
      state      = TrackState.confirmed;
      label      = topLabel.key;
      confidence = _confHistory.reduce((a, b) => a + b) / _confHistory.length;
    } else {
      state      = TrackState.unknown;
      label      = '?';
      confidence = 0.0;
    }
  }

  double distanceTo(List<double> otherCenter) {
    final dx = center[0] - otherCenter[0];
    final dy = center[1] - otherCenter[1];
    return sqrt(dx * dx + dy * dy);
  }

  static double get matchRadius => _matchRadius;
}

// ---------------------------------------------------------------------------
// ObjectTracker
// ---------------------------------------------------------------------------

class ObjectTracker {
  final List<TrackedObject> _tracks = [];
  int _nextId = 0;

  List<TrackedObject> get tracks => List.unmodifiable(_tracks);

  TrackResult update(List<Map<String, dynamic>> detections) {
    final events = <TrackEvent>[];

    for (final t in _tracks) t.markMissed();

    for (final det in detections) {
      final bbox   = (det['bbox'] as List).map((e) => (e as num).toDouble()).toList();
      final center = [bbox[0], bbox[1]];
      final label  = det['label'] as String;
      final conf   = (det['confidence'] as num).toDouble();

      TrackedObject? best;
      double bestDist = TrackedObject.matchRadius;
      for (final t in _tracks) {
        final d = t.distanceTo(center);
        if (d < bestDist) { bestDist = d; best = t; }
      }

      if (best != null) {
        final event = best.update(center, bbox, label, conf);
        if (event != null) events.add(event);
      } else {
        final newId  = _nextId++;
        final tid    = 'track_${newId.toString().padLeft(3, '0')}';
        final track  = TrackedObject(
            id: newId, trackId: tid, center: center, bbox: bbox);
        final event  = track.update(center, bbox, label, conf);
        if (event != null) events.add(event);
        _tracks.add(track);
      }
    }

    _tracks.removeWhere((t) => t.shouldRemove);

    return TrackResult(tracks: List.unmodifiable(_tracks), newEvents: events);
  }

  List<TelemetrySnapshot> get telemetry => _tracks
      .where((t) =>
          t.state == TrackState.confirmed || t.state == TrackState.unknown)
      .map((t) => TelemetrySnapshot(
            trackId:      t.trackId,
            label:        t.state == TrackState.unknown ? 'unknown' : t.label,
            state:        t.state,
            cx:           t.bbox[0],
            cy:           t.bbox[1],
            w:            t.bbox[2],
            h:            t.bbox[3],
            speedMps:     t.speedMps,
            directionDeg: t.directionDeg,
            distanceM:    t.distanceM,
            timeInScene:  t.timeInScene,
            framesAlive:  t.framesAlive,
            trajectory:   t.trajectory,
          ))
      .toList();

  void clear() {
    _tracks.clear();
    _nextId = 0;
  }
}