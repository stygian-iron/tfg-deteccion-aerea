import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'alerts_screen.dart';
import 'telemetry_screen.dart';
import '../services/inference_service.dart';
import '../services/object_tracker.dart';
import '../services/snapshot_service.dart';
import '../services/sensor_service.dart';
import '../widgets/alerta_overlay.dart';

// ---------------------------------------------------------------------------
// Per-class visual mapping (shared by the painter and the detection list).
// Add a case here if you ever introduce more classes.
// ---------------------------------------------------------------------------

Color colorForClass(String label) {
  switch (label) {
    case 'drone':      return Colors.blue;
    case 'bird':       return Colors.green;
    case 'airplane':   return Colors.cyanAccent;
    case 'helicopter': return Colors.deepOrangeAccent;
    default:           return Colors.purpleAccent; // unexpected label
  }
}

IconData iconForClass(String label) {
  switch (label) {
    case 'drone':      return Icons.flight;
    case 'bird':       return Icons.flutter_dash;
    case 'airplane':   return Icons.airplanemode_active;
    case 'helicopter': return Icons.air;
    default:           return Icons.help_outline;
  }
}

class StreamScreen extends StatefulWidget {
  final String serverIp;
  const StreamScreen({super.key, required this.serverIp});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> {
  CameraController? _cameraController;
  bool _cameraReady = false;
  WebSocketChannel? _channel;
  bool _connected = false;
  String _status = 'Starting...';
  bool _onDeviceMode = false;
  final InferenceService _inferenceService = InferenceService();
  bool _modelLoaded = false;
  final ObjectTracker _tracker = ObjectTracker();
  String _fps = '0';
  int _detections = 0;
  List<dynamic> _detectionList = [];
  bool _sending = false;
  int _frameCount = 0;
  int _lastFrameTime = 0;
  final GlobalKey _previewKey = GlobalKey();
  Size _previewSize = Size.zero;
  final List<int> _fpsTimestamps = [];

  // Snapshot + badge
  // NOTE: _lastFrameJpeg now holds a CLEAN, already-rotated, higher-res JPEG
  // meant for the alert log — NOT the enhanced frame sent to the server.
  Uint8List? _lastFrameJpeg;
  bool _savingSnapshot = false;
  int _unreviewedCount = 0;

  // Telemetry
  final _telemetryNotifier = ValueNotifier<List<TelemetrySnapshot>>([]);

  // Auto-zoom
  double _currentZoom = 1.0;
  double _maxZoom = 1.0;
  int _lastZoomChangeMs = 0;
  static const int _zoomDebounceMs = 1200;

  // Model matrix: target set (drone/bird vs heli/plane) × detail (320 vs 512)
  TargetSet _target = TargetSet.droneBird;
  DetailMode _detail = DetailMode.acquisition;

  // Confirmation-mode zoom baseline (applies to both target sets).
  static const double _confirmBaseZoom   = 3.0;
  static const double _confirmActiveZoom = 4.0;

  // Base wide-lens FoV (deg) at 1× zoom — Samsung S22 main camera.
  static const double _baseHFovDeg = 69.0;

  // Confidence threshold — adjustable at runtime
  double _confThreshold = 0.25;

  @override
  void initState() {
    super.initState();
    _loadModel();
    _initCamera();
    _refreshBadge();
    SensorService.instance.start();
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _channel?.sink.close();
    _inferenceService.dispose();
    _telemetryNotifier.dispose();
    SensorService.instance.stop();
    super.dispose();
  }

  Future<void> _refreshBadge() async {
    final count = await SnapshotService.instance.getUnreviewedSnapshotCount();
    if (mounted) setState(() => _unreviewedCount = count);
  }

  Future<void> _loadModel() async {
    await _inferenceService.loadModel();
    setState(() => _modelLoaded = _inferenceService.isLoaded);
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _status = 'No camera found');
      return;
    }
    // Main back camera (id 0 on the S22). The second back camera is almost
    // certainly the ultrawide (wider FoV = shorter range) and the plugin
    // exposes no FoV to tell them apart, so reach comes from zoom on the main
    // lens instead of selecting it.
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    // ResolutionPreset.high (1280×720) gives the zoom path real detail. If
    // acquisition FPS suffers, drop to .medium — one word.
    _cameraController = CameraController(
      camera, ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _cameraController!.initialize();
    if (!mounted) return;

    try {
      _maxZoom = await _cameraController!.getMaxZoomLevel();
      _maxZoom = _maxZoom.clamp(1.0, 4.0);
    } catch (_) {
      _maxZoom = 1.0;
    }

    _applyEffectiveFov(); // tracker focal length for current zoom (1×)

    setState(() => _cameraReady = true);
    if (widget.serverIp.isNotEmpty) {
      _connectWebSocket();
    } else {
      setState(() { _onDeviceMode = true; _status = 'On-device · no server'; });
      _startImageStream();
    }
  }

  // -------------------------------------------------------------------------
  // Sensitivity bottom sheet
  // -------------------------------------------------------------------------

  void _showSensitivitySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.tune, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                const Text('Detection Sensitivity',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                  _confThreshold.toStringAsFixed(2),
                  style: const TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                'Lower → more detections, more false positives\n'
                'Higher → fewer but more confident detections',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
              const SizedBox(height: 20),
              Row(children: [
                _presetChip('Sensitive', 0.15, setSheet),
                const SizedBox(width: 8),
                _presetChip('Default', 0.25, setSheet),
                const SizedBox(width: 8),
                _presetChip('Strict', 0.45, setSheet),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Text('0.10',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: _confThreshold.clamp(0.10, 0.60),
                    min: 0.10,
                    max: 0.60,
                    divisions: 50,
                    activeColor: Colors.blueAccent,
                    inactiveColor: Colors.grey.shade700,
                    onChanged: (val) {
                      setSheet(() {});
                      setState(() => _confThreshold = val);
                      _inferenceService.setConfThreshold(val);
                    },
                  ),
                ),
                Text('0.60',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presetChip(String label, double value, StateSetter setSheet) {
    final isActive = (_confThreshold - value).abs() < 0.01;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setSheet(() {});
          setState(() => _confThreshold = value);
          _inferenceService.setConfThreshold(value);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.blueAccent.withOpacity(0.15)
                : Colors.grey.shade800,
            border: Border.all(
              color: isActive ? Colors.blueAccent : Colors.grey.shade700,
              width: isActive ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text(label,
                style: TextStyle(
                    color: isActive ? Colors.blueAccent : Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(value.toStringAsFixed(2),
                style: TextStyle(
                    color: isActive
                        ? Colors.blueAccent.withOpacity(0.8)
                        : Colors.grey.shade600,
                    fontSize: 10)),
          ]),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Effective FoV → tracker focal length
  // -------------------------------------------------------------------------

  void _applyEffectiveFov() {
    final effHFov = (_baseHFovDeg / _currentZoom).clamp(1.0, 179.0);
    TrackedObject.setEffectiveHFov(effHFov);
  }

  // -------------------------------------------------------------------------
  // Auto-zoom (detail-mode aware)
  // -------------------------------------------------------------------------

  Future<void> _updateZoom(List<TrackedObject> tracks) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastZoomChangeMs < _zoomDebounceMs) return;

    final hasActive = tracks.any((t) =>
        t.state == TrackState.confirmed || t.state == TrackState.unknown);

    double targetZoom;
    if (_detail == DetailMode.confirmation) {
      final base   = _confirmBaseZoom.clamp(1.0, _maxZoom).toDouble();
      final locked = _confirmActiveZoom.clamp(1.0, _maxZoom).toDouble();
      targetZoom = hasActive ? locked : base;
    } else {
      targetZoom = (hasActive ? 2.0 : 1.0).clamp(1.0, _maxZoom).toDouble();
    }

    if ((targetZoom - _currentZoom).abs() < 0.05) return;

    try {
      await _cameraController?.setZoomLevel(targetZoom);
      _currentZoom = targetZoom;
      _lastZoomChangeMs = now;
      _applyEffectiveFov();
    } catch (e) {
      debugPrint('Zoom error: $e');
    }
  }

  Future<void> _resetZoom() async {
    if (_currentZoom == 1.0) return;
    try {
      await _cameraController?.setZoomLevel(1.0);
      _currentZoom = 1.0;
      _applyEffectiveFov();
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Model selection (target set + detail mode)
  // -------------------------------------------------------------------------

  Future<void> _setTarget(TargetSet t) async {
    if (t == _target) return;
    if (!_inferenceService.isTargetAvailable(t)) return; // no model bundled
    setState(() {
      _target = t;
      _detectionList = [];
      _detections = 0;
    });
    await _inferenceService.setActive(_target, _detail);
    _tracker.clear();
    _telemetryNotifier.value = [];
    _lastZoomChangeMs = 0;
    await _updateZoom(const <TrackedObject>[]);
    _applyEffectiveFov();
  }

  Future<void> _setDetail(DetailMode d) async {
    if (d == _detail) return;
    setState(() {
      _detail = d;
      _detectionList = [];
      _detections = 0;
    });
    await _inferenceService.setActive(_target, _detail);
    _tracker.clear();
    _telemetryNotifier.value = [];
    _lastZoomChangeMs = 0;
    await _updateZoom(const <TrackedObject>[]);
    _applyEffectiveFov();
  }

  String _modeLabel() {
    final t = _target == TargetSet.heliPlane ? 'Heli/Plane' : 'Drone/Bird';
    final size = _detail == DetailMode.confirmation ? '512' : '320';
    final avail = _inferenceService.isAvailable(_target, _detail);
    return '$t · $size${avail ? '' : ' (fallback)'}';
  }

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  Future<void> _openAlerts() async {
    if (_cameraController?.value.isStreamingImages == true) {
      await _cameraController?.stopImageStream();
    }
    await _resetZoom();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AlertsScreen(serverIp: widget.serverIp)),
    );
    if (mounted) {
      await _refreshBadge();
      if (_onDeviceMode) {
        _startImageStream();
        _lastZoomChangeMs = 0;
        await _updateZoom(const <TrackedObject>[]);
      } else if (_connected) {
        _startSendingFrames();
      }
    }
  }

  void _openTelemetry() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TelemetryScreen(telemetryNotifier: _telemetryNotifier),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // API mode — WebSocket
  // -------------------------------------------------------------------------

  void _connectWebSocket() {
    final uri = Uri.parse('ws://${widget.serverIp}:8000/stream');
    _channel = WebSocketChannel.connect(uri);
    setState(() { _status = 'Connected to ${widget.serverIp}'; _connected = true; });

    _channel!.stream.listen(
      (data) async {
        if (_onDeviceMode) return;
        final json = jsonDecode(data as String);
        final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null) _previewSize = box.size;

        final rawDetections =
            (json['detections'] as List).cast<Map<String, dynamic>>();
        final trackResult = _tracker.update(rawDetections);

        await _updateZoom(trackResult.tracks);

        // _lastFrameJpeg is already the clean, rotated, higher-res snapshot
        // prepared by _startSendingFrames — save it directly, no rotation.
        if (trackResult.newEvents.isNotEmpty &&
            !_savingSnapshot &&
            _lastFrameJpeg != null) {
          _savingSnapshot = true;
          await _saveSnapshot(trackResult, _lastFrameJpeg!);
          _savingSnapshot = false;
        }

        _telemetryNotifier.value = _tracker.telemetry;

        setState(() {
          _fps = json['fps']?.toString() ?? '0';
          _detections = trackResult.tracks
              .where((t) => t.state == TrackState.confirmed)
              .length;
          _detectionList = trackResult.tracks.map((t) => {
            'label': t.label,
            'confidence': t.confidence,
            'bbox': t.bbox,
            'center': t.center,
            'state': t.state.name,
          }).toList();
        });
      },
      onError: (e) =>
          setState(() { _status = 'Error: $e'; _connected = false; }),
      onDone: () {
        setState(() {
          _status = 'Disconnected - reconnecting...';
          _connected = false;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && !_onDeviceMode) _connectWebSocket();
        });
      },
    );

    _startSendingFrames();
    Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_connected || _onDeviceMode) { timer.cancel(); return; }
      try { _channel!.sink.add(jsonEncode({'ping': true})); } catch (e) { timer.cancel(); }
    });
  }

  void _startSendingFrames() {
    _cameraController!.startImageStream((CameraImage cameraImage) async {
      if (!_cameraReady || _sending || _onDeviceMode) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastFrameTime < 150) return;
      _lastFrameTime = now;
      _sending = true;
      try {
        // One YUV→RGB pass, two outputs:
        //   server   → enhanced 320 px landscape JPEG (detection input, as before)
        //   snapshot → clean, rotated-portrait, higher-res JPEG (alert log)
        final frames = await compute(_convertYuvApiIsolate, {
          'width': cameraImage.width, 'height': cameraImage.height,
          'yBytes': cameraImage.planes[0].bytes,
          'uBytes': cameraImage.planes[1].bytes,
          'vBytes': cameraImage.planes[2].bytes,
          'uvRowStride': cameraImage.planes[1].bytesPerRow,
          'uvPixelStride': cameraImage.planes[1].bytesPerPixel ?? 1,
        });
        final serverJpeg   = frames['server'];
        final snapshotJpeg = frames['snapshot'];
        if (serverJpeg == null || !_connected) return;
        // Keep the clean snapshot ready for whenever an event fires; the
        // server still receives the enhanced frame (detection unchanged).
        if (snapshotJpeg != null) _lastFrameJpeg = snapshotJpeg;
        _channel!.sink.add(
          jsonEncode({'image': base64Encode(serverJpeg), 'frame_id': _frameCount++}),
        );
      } catch (e) {
        debugPrint('Error sending frame: $e');
      } finally {
        _sending = false;
      }
    });
  }

  // -------------------------------------------------------------------------
  // On-device mode
  // -------------------------------------------------------------------------

  void _startImageStream() {
    _cameraController!.startImageStream((CameraImage cameraImage) async {
      if (!_cameraReady || _sending || !_onDeviceMode) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastFrameTime < 150) return;
      _lastFrameTime = now;
      _sending = true;
      try {
        await _processOnDevice(cameraImage);
      } catch (e) {
        debugPrint('Error on-device: $e');
      } finally {
        _sending = false;
      }
    });
  }

  Future<void> _processOnDevice(CameraImage cameraImage) async {
    if (!_modelLoaded) return;
    final rotationDegrees =
        _cameraController?.description.sensorOrientation ?? 0;
    final results = await _inferenceService.runOnFrame(cameraImage, rotationDegrees);

    final now = DateTime.now().millisecondsSinceEpoch;
    _fpsTimestamps.add(now);
    _fpsTimestamps.removeWhere((t) => now - t > 1000);

    final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) _previewSize = box.size;

    final rawDetections = results.map((r) => {
      'label': r.label,
      'confidence': r.confidence,
      'bbox': [r.x, r.y, r.width, r.height],
    } as Map<String, dynamic>).toList();

    final trackResult = _tracker.update(rawDetections);

    await _updateZoom(trackResult.tracks);

    if (trackResult.newEvents.isNotEmpty && !_savingSnapshot) {
      _savingSnapshot = true;
      // Clean, un-enhanced, native-resolution snapshot, rotated to portrait.
      // On-device detection is done in Kotlin (enhanceBitmap), so no Dart-side
      // enhancement is needed here — this JPEG is only for human review and
      // active-learning export. Enhancement here would only blow out the sky.
      final jpeg = await compute(_convertYuvToCleanJpegIsolate, {
        'width': cameraImage.width, 'height': cameraImage.height,
        'yBytes': cameraImage.planes[0].bytes,
        'uBytes': cameraImage.planes[1].bytes,
        'vBytes': cameraImage.planes[2].bytes,
        'uvRowStride': cameraImage.planes[1].bytesPerRow,
        'uvPixelStride': cameraImage.planes[1].bytesPerPixel ?? 1,
        'maxLongSide': 1280, // preserve detail for the 6× zoom viewer
      });
      if (jpeg != null) await _saveSnapshot(trackResult, jpeg);
      _savingSnapshot = false;
    }

    _telemetryNotifier.value = _tracker.telemetry;

    setState(() {
      _fps = _fpsTimestamps.length.toString();
      _detections = trackResult.tracks
          .where((t) => t.state == TrackState.confirmed)
          .length;
      _detectionList = trackResult.tracks.map((t) => {
        'label': t.label,
        'confidence': t.confidence,
        'bbox': t.bbox,
        'center': t.center,
        'state': t.state.name,
      }).toList();
      _status = 'On-device · ${_modeLabel()}';
    });
  }

  // -------------------------------------------------------------------------
  // Save snapshot
  //
  // The incoming JPEG is ALREADY clean and rotated to portrait (both the
  // on-device and API paths hand it over pre-rotated), so no rotation happens
  // here anymore. This method only computes telemetry and persists the row.
  // -------------------------------------------------------------------------

  Future<void> _saveSnapshot(TrackResult trackResult, Uint8List rotatedJpeg) async {
    try {
      final allDetections = trackResult.tracks.map((t) {
        final tel = SensorService.instance.computeObjectTelemetry(
          cx: t.bbox[0], cy: t.bbox[1],
          w:  t.bbox[2], h:  t.bbox[3],
          apparentSpeedMps: t.speedMps,
          zoomLevel: _currentZoom,
        );
        return DetectionInput(
          trackId:      t.trackId,
          classLabel:   t.state == TrackState.unknown
              ? 'unknown'
              : (t.state == TrackState.confirmed ? t.label : 'candidate'),
          confidence:   t.confidence,
          cx: t.bbox[0], cy: t.bbox[1], w: t.bbox[2], h: t.bbox[3],
          speedMps:     tel.speedMps,
          directionDeg: tel.bearingDeg,
          distanceM:    t.distanceM,
        );
      }).toList();

      await SnapshotService.instance.saveSnapshot(
        jpegBytes: rotatedJpeg,
        detections: allDetections,
      );
      await _refreshBadge();
    } catch (e) {
      debugPrint('Snapshot save error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Mode toggle (API ↔ on-device)
  // -------------------------------------------------------------------------

  void _toggleMode(bool value) async {
    await _cameraController?.stopImageStream();
    await _resetZoom();
    _tracker.clear();
    _telemetryNotifier.value = [];
    setState(() {
      _onDeviceMode = value;
      _detectionList = [];
      _detections = 0;
      _fps = '0';
    });
    if (value) {
      setState(() =>
          _status = 'On-device · ${_modelLoaded ? _modeLabel() : "Loading..."}');
      _startImageStream();
      _lastZoomChangeMs = 0;
      await _updateZoom(const <TrackedObject>[]);
    } else {
      if (widget.serverIp.isNotEmpty) _connectWebSocket();
      else {
        setState(() => _status = 'No server configured');
        _startImageStream();
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool thresholdModified = (_confThreshold - 0.25).abs() > 0.01;

    // ── Alert state ──────────────────────────────────────────────────────
    // Any CONFIRMED track drives the visual alert overlay. We reuse the
    // tracker's own "confirmed" definition (4 frames + 70% label agreement),
    // the same criterion used in the field study, so no extra debounce is
    // needed here. The overlay handles the blink and fires haptics only on the
    // rising edge (first confirmation), because it stays mounted always.
    final confirmed = _detectionList
        .where((d) => (d['state'] as String? ?? 'confirmed') == 'confirmed')
        .toList();
    final bool alertActive = confirmed.isNotEmpty;
    String? alertLabel;
    if (alertActive) {
      confirmed.sort((a, b) =>
          (b['confidence'] as num).compareTo(a['confidence'] as num));
      alertLabel = (confirmed.first['label'] as String).toUpperCase();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Live Stream'),
        actions: [
          Row(children: [
            Icon(
              _onDeviceMode ? Icons.phone_android : Icons.wifi,
              size: 18,
              color: _onDeviceMode ? Colors.greenAccent : Colors.blueAccent,
            ),
            const SizedBox(width: 4),
            Switch(
              value: _onDeviceMode,
              onChanged: _modelLoaded ? _toggleMode : null,
              activeColor: Colors.greenAccent,
            ),
          ]),
          IconButton(
            icon: Icon(Icons.tune,
                color: thresholdModified ? Colors.orange : null),
            tooltip: 'Detection sensitivity (${_confThreshold.toStringAsFixed(2)})',
            onPressed: _showSensitivitySheet,
          ),
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: 'Live telemetry',
            onPressed: _openTelemetry,
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: _openAlerts,
              ),
              if (_unreviewedCount > 0)
                Positioned(
                  right: 6, top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      _unreviewedCount > 99 ? '99+' : '$_unreviewedCount',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              _onDeviceMode
                  ? Icons.memory
                  : (_connected ? Icons.circle : Icons.circle_outlined),
              color: _onDeviceMode
                  ? Colors.greenAccent
                  : (_connected ? Colors.green : Colors.red),
              size: 16,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _onDeviceMode
                ? Colors.green.shade900
                : (_connected ? Colors.green.shade900 : Colors.red.shade900),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Text(_status,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              if (_currentZoom > 1.0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.orange.withOpacity(0.6)),
                  ),
                  child: Text(
                    '${_currentZoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
            ]),
          ),

          // Model selectors (on-device only): target set, then detail mode.
          if (_onDeviceMode) ...[
            _buildTargetSelector(),
            _buildDetailSelector(),
          ],

          if (_cameraReady)
            LayoutBuilder(builder: (context, constraints) {
              final camRatio = _cameraController!.value.aspectRatio;
              final maxW = constraints.maxWidth;
              final maxH = maxW / camRatio;
              return SizedBox(
                width: maxW, height: maxH,
                child: Stack(fit: StackFit.expand, children: [
                  ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.center,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          key: _previewKey,
                          width: maxW, height: maxH,
                          child: CameraPreview(_cameraController!),
                        ),
                      ),
                    ),
                  ),
                  if (_detectionList.isNotEmpty)
                    CustomPaint(
                      painter: BoundingBoxPainter(detections: _detectionList),
                      size: Size(maxW, maxH),
                    ),
                  // Visual alert overlay — pulsing border + blinking dot + haptic.
                  // Always mounted (not behind an `if`) so the haptic fires only
                  // on the rising edge, and it renders nothing while inactive.
                  Positioned.fill(
                    child: AlertaOverlay(
                      activa: alertActive,
                      etiqueta: alertLabel,
                      objetivos: confirmed.length,
                    ),
                  ),
                ]),
              );
            })
          else
            const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator())),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _metricCard('FPS', _fps, Icons.speed),
                  _metricCard('Confirmed', _detections.toString(), Icons.verified),
                ]),
          ),

          _buildLegend(),

          const SizedBox(height: 6),

          Expanded(
            child: _detectionList.isEmpty
                ? Center(
                    child: Text(
                      _onDeviceMode && !_modelLoaded
                          ? 'Loading model...'
                          : 'No active detections',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _detectionList.length,
                    itemBuilder: (context, i) {
                      final d = _detectionList[i];
                      final state = d['state'] as String? ?? 'confirmed';
                      final label = d['label'] as String;
                      Color itemColor;
                      IconData itemIcon;
                      String displayLabel;

                      if (state == 'candidate') {
                        itemColor = Colors.grey;
                        itemIcon = Icons.help_outline;
                        displayLabel = 'Detecting...';
                      } else if (state == 'unknown') {
                        itemColor = Colors.yellow;
                        itemIcon = Icons.question_mark;
                        displayLabel = 'UNKNOWN';
                      } else {
                        itemColor = colorForClass(label);
                        itemIcon = iconForClass(label);
                        final conf = (d['confidence'] as num).toDouble();
                        displayLabel =
                            '${label.toUpperCase()} · ${(conf * 100).toStringAsFixed(0)}%';
                      }

                      return ListTile(
                        leading: Icon(itemIcon, color: itemColor),
                        title: Text(displayLabel,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: itemColor)),
                        subtitle: state == 'confirmed'
                            ? Text(
                                'x: ${((d['center'][0] as num)).toStringAsFixed(2)}  '
                                'y: ${((d['center'][1] as num)).toStringAsFixed(2)}',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12))
                            : null,
                      );
                    }),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Selectors + legend
  // -------------------------------------------------------------------------

  Widget _buildTargetSelector() {
    final heliAvail = _inferenceService.isTargetAvailable(TargetSet.heliPlane);
    final uniAvail  = _inferenceService.isTargetAvailable(TargetSet.unified);
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(children: [
        _targetChip(
          label: 'Drone/Bird',
          sub: 'specialist',
          icon: Icons.radar,
          target: TargetSet.droneBird,
          enabled: _inferenceService.isTargetAvailable(TargetSet.droneBird),
        ),
        const SizedBox(width: 6),
        _targetChip(
          label: 'Heli/Plane',
          sub: heliAvail ? 'specialist' : 'no model',
          icon: Icons.connecting_airports,
          target: TargetSet.heliPlane,
          enabled: heliAvail,
        ),
        const SizedBox(width: 6),
        _targetChip(
          label: 'Unified',
          sub: uniAvail ? '4 classes' : 'no model',
          icon: Icons.category,
          target: TargetSet.unified,
          enabled: uniAvail,
        ),
      ]),
    );
  }

  Widget _targetChip({
    required String label,
    required String sub,
    required IconData icon,
    required TargetSet target,
    required bool enabled,
  }) {
    final active = _target == target && enabled;
    final accent = Colors.amberAccent;
    final fg = !enabled
        ? Colors.grey.shade700
        : (active ? accent : Colors.grey);
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? () => _setTarget(target) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: active ? accent.withOpacity(0.15) : Colors.grey.shade800,
            border: Border.all(
              color: active ? accent : Colors.grey.shade800,
              width: active ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: fg, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(sub,
                    style: TextStyle(
                        color: !enabled
                            ? Colors.grey.shade700
                            : (active
                                ? accent.withOpacity(0.8)
                                : Colors.grey.shade600),
                        fontSize: 9)),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildDetailSelector() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(children: [
        _detailChip(
          label: 'Acquisition',
          icon: Icons.zoom_out_map,
          detail: DetailMode.acquisition,
        ),
        const SizedBox(width: 8),
        _detailChip(
          label: 'Confirmation',
          icon: Icons.center_focus_strong,
          detail: DetailMode.confirmation,
        ),
      ]),
    );
  }

  Widget _detailChip({
    required String label,
    required IconData icon,
    required DetailMode detail,
  }) {
    final active = _detail == detail;
    final avail = _inferenceService.isAvailable(_target, detail);
    final accent = Colors.tealAccent;
    final sub = detail == DetailMode.confirmation
        ? (avail ? '512 · zoom · range' : '512 n/a → 320')
        : (avail ? '320 · wide · fast' : '320 n/a → fallback');
    final fg = active ? accent : Colors.grey;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setDetail(detail),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: active ? accent.withOpacity(0.15) : Colors.grey.shade800,
            border: Border.all(
              color: active ? accent : Colors.grey.shade700,
              width: active ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: fg, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(sub,
                    style: TextStyle(
                        color: active
                            ? accent.withOpacity(0.8)
                            : Colors.grey.shade600,
                        fontSize: 9)),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    // Class list follows the active target set (2 for specialists, 4 for unified).
    final classLabels = _inferenceService.classNamesFor(_target);
    String cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          _legendDot(Colors.grey, 'Candidate'),
          _legendDot(Colors.yellow, 'Unknown'),
          for (final label in classLabels)
            _legendDot(colorForClass(label), cap(label)),
        ],
      ),
    );
  }

  Widget _metricCard(String label, String value, IconData icon) => Card(
        color: Colors.grey.shade900,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          child: Column(children: [
            Icon(icon, size: 24, color: Colors.white70),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ]),
        ),
      );

  Widget _legendDot(Color color, String label) => Row(children: [
        Container(
            width: 10, height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ]);
}

// ---------------------------------------------------------------------------
// Bounding Box Painter
// ---------------------------------------------------------------------------

class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detections;
  BoundingBoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in detections) {
      final state = d['state'] as String? ?? 'confirmed';
      final label = d['label'] as String;
      Color color;
      String displayLabel;
      double strokeWidth;

      if (state == 'candidate') {
        color = Colors.grey; displayLabel = '?'; strokeWidth = 1.5;
      } else if (state == 'unknown') {
        color = Colors.yellow; displayLabel = 'UNKNOWN'; strokeWidth = 2.0;
      } else {
        final conf = (d['confidence'] as num).toDouble();
        color = colorForClass(label);
        displayLabel = '${label.toUpperCase()} ${(conf * 100).toStringAsFixed(0)}%';
        strokeWidth = 2.5;
      }

      final paint = Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      final bbox = d['bbox'] as List<dynamic>;
      final cx = (bbox[0] as num).toDouble();
      final cy = (bbox[1] as num).toDouble();
      final w  = (bbox[2] as num).toDouble();
      final h  = (bbox[3] as num).toDouble();

      final x1 = (cx - w / 2) * size.width;
      final y1 = (cy - h / 2) * size.height;
      final x2 = (cx + w / 2) * size.width;
      final y2 = (cy + h / 2) * size.height;

      canvas.drawRect(Rect.fromLTRB(x1, y1, x2, y2), paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: displayLabel,
          style: TextStyle(
            color: color, fontSize: 13, fontWeight: FontWeight.bold,
            backgroundColor: Colors.black.withOpacity(0.6),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(canvas, Offset(x1, y1 > 20 ? y1 - 18 : y1 + 4));
    }
  }

  @override
  bool shouldRepaint(BoundingBoxPainter old) => old.detections != detections;
}

// ---------------------------------------------------------------------------
// Isolates
// ---------------------------------------------------------------------------

// Shared YUV420 → RGB conversion at full sensor resolution, NO enhancement.
// Both snapshot paths and the API server-frame path build on this single pass.
img.Image _yuvToImage(Map<String, dynamic> params) {
  final int width  = params['width'];
  final int height = params['height'];
  final Uint8List yBytes = params['yBytes'];
  final Uint8List uBytes = params['uBytes'];
  final Uint8List vBytes = params['vBytes'];
  final int uvRowStride   = params['uvRowStride'];
  final int uvPixelStride = params['uvPixelStride'];

  final out = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
      final yValue = yBytes[y * width + x];
      final uValue = uBytes[uvIndex];
      final vValue = vBytes[uvIndex];
      out.setPixelRgb(
        x, y,
        (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255),
        (yValue - 0.344 * (uValue - 128) - 0.714 * (vValue - 128)).round().clamp(0, 255),
        (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255),
      );
    }
  }
  return out;
}

// Downscale so the longer side is at most [maxLong] px (0 = no cap). Aspect
// ratio is preserved, so the normalized bbox overlays in the alert log line up
// exactly as before — only the resolution changes.
img.Image _capLongSide(img.Image src, int maxLong) {
  if (maxLong <= 0) return src;
  final longSide = src.width > src.height ? src.width : src.height;
  if (longSide <= maxLong) return src;
  return src.width >= src.height
      ? img.copyResize(src, width: maxLong)
      : img.copyResize(src, height: maxLong);
}

// On-device snapshot: clean (no contrast/brightness/sharpen), rotated 90° CW to
// portrait, high quality. This is the daylight-overexposure fix — the review
// image now reflects what the camera actually saw, at usable resolution for the
// 6× zoom viewer. Optional 'maxLongSide' caps the size.
Uint8List? _convertYuvToCleanJpegIsolate(Map<String, dynamic> params) {
  try {
    final base    = _yuvToImage(params);
    final capped  = _capLongSide(base, (params['maxLongSide'] as int?) ?? 0);
    final rotated = img.copyRotate(capped, angle: 90); // 90° CW → portrait
    return Uint8List.fromList(img.JpegEncoder(quality: 88).encode(rotated));
  } catch (_) {
    return null;
  }
}

// API mode: one YUV→RGB pass, two outputs.
//   'server'   → enhanced 320 px landscape JPEG — unchanged detection input,
//                so API-mode behaviour and Dart↔Kotlin preprocessing parity
//                stay exactly as documented.
//   'snapshot' → clean, 640 px long side, rotated-portrait JPEG for the alert
//                log (same treatment as the on-device snapshot). This is what
//                gets saved when an event fires; the server never sees it.
Map<String, Uint8List?> _convertYuvApiIsolate(Map<String, dynamic> params) {
  final result = <String, Uint8List?>{'server': null, 'snapshot': null};
  try {
    final base = _yuvToImage(params);

    // Server frame — same enhancement pipeline as the original isolate.
    final server = img.copyResize(base, width: 320);
    img.adjustColor(server, contrast: 1.25, brightness: 8);
    // Sharpen kernel matched to the Kotlin on-device path (k = 0.6):
    //   center = 1 + 4k = 3.4, neighbours = -k = -0.6, div = 1
    const double k = 0.6;
    final serverSharp = img.convolution(
      server,
      filter: [0, -k, 0, -k, 1 + 4 * k, -k, 0, -k, 0],
      div: 1,
      offset: 0,
    );
    result['server'] =
        Uint8List.fromList(img.JpegEncoder(quality: 65).encode(serverSharp));

    // Snapshot frame — clean, bounded resolution, rotated to portrait.
    final snap    = _capLongSide(base, 640);
    final snapRot = img.copyRotate(snap, angle: 90); // 90° CW → portrait
    result['snapshot'] =
        Uint8List.fromList(img.JpegEncoder(quality: 85).encode(snapRot));
  } catch (_) {}
  return result;
}