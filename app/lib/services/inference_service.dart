// lib/services/inference_service.dart
// Delegates inference to native Kotlin over a Platform Channel.
//
// Model registry — three target sets, each with a 320 (acquisition) and a 512
// (confirmation) variant. Any model not bundled simply fails to load and is
// marked unavailable; its chip greys out and selecting it falls back in Kotlin.
//
//   droneBird : specialist, 2 classes  {bird, drone}          (your 0.953 model)
//   heliPlane : specialist, 2 classes  {airplane, helicopter} (optional)
//   unified   : generalist, 4 classes  {airplane,bird,drone,helicopter} (AOD4)
//
// The droneBird-specialist vs unified comparison (per class, across range) is
// the headline experiment.

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

enum TargetSet { droneBird, heliPlane, unified }
enum DetailMode { acquisition, confirmation } // 320 / 512

class _ModelSpec {
  final TargetSet target;
  final DetailMode detail;
  final String asset;
  final List<String> classNames; // index order MUST match the model's data.yaml
  const _ModelSpec(this.target, this.detail, this.asset, this.classNames);

  String get key => '${target.name}_${detail.name}';
}

class InferenceResult {
  final String label;
  final int classId;
  final double confidence;
  final double x, y, width, height;

  const InferenceResult({
    required this.label, required this.classId, required this.confidence,
    required this.x, required this.y, required this.width, required this.height,
  });
}

class InferenceService {
  static const _channel = MethodChannel('com.tfg.tfg_app/inference');

  // ---------------------------------------------------------------------------
  // VERIFY each classNames order against the model's data.yaml after export.
  // Roboflow alphabetises: droneBird -> {bird,drone}; heliPlane ->
  // {airplane,helicopter}; unified (AOD4) -> {airplane,bird,drone,helicopter}.
  // ---------------------------------------------------------------------------
  static const List<_ModelSpec> _specs = [
    _ModelSpec(TargetSet.droneBird, DetailMode.acquisition,  'best_int8.tflite',        ['bird', 'drone']),
    _ModelSpec(TargetSet.droneBird, DetailMode.confirmation, 'best_int8_512.tflite',    ['bird', 'drone']),
    _ModelSpec(TargetSet.heliPlane, DetailMode.acquisition,  'heli_int8.tflite',        ['airplane', 'helicopter']),
    _ModelSpec(TargetSet.heliPlane, DetailMode.confirmation, 'heli_int8_512.tflite',    ['airplane', 'helicopter']),
    _ModelSpec(TargetSet.unified,   DetailMode.acquisition,  'unified_int8.tflite',     ['airplane', 'bird', 'drone', 'helicopter']),
    _ModelSpec(TargetSet.unified,   DetailMode.confirmation, 'unified_int8_512.tflite', ['airplane', 'bird', 'drone', 'helicopter']),
  ];

  final Set<String> _available = {};
  bool _loaded = false;

  TargetSet _target = TargetSet.droneBird;
  DetailMode _detail = DetailMode.acquisition;

  bool get isLoaded => _loaded;
  TargetSet get target => _target;
  DetailMode get detail => _detail;

  String _keyFor(TargetSet t, DetailMode d) => '${t.name}_${d.name}';

  bool isAvailable(TargetSet t, DetailMode d) =>
      _available.contains(_keyFor(t, d));

  bool isTargetAvailable(TargetSet t) =>
      DetailMode.values.any((d) => isAvailable(t, d));

  /// Class names for a target set (for legend / UI). Falls back to the spec.
  List<String> classNamesFor(TargetSet t) =>
      _specs.firstWhere((s) => s.target == t).classNames;

  /// Loads every model in the registry. Missing assets are tolerated.
  Future<void> loadModel() async {
    for (final spec in _specs) {
      try {
        final ok = await _channel.invokeMethod('loadModel', {
              'modelName': spec.asset,
              'mode': spec.key,
              'classNames': spec.classNames,
            }) ??
            false;
        if (ok == true) {
          _available.add(spec.key);
        } else {
          print('[InferenceService] not bundled: ${spec.asset} (${spec.key})');
        }
      } catch (e) {
        print('[InferenceService] load error for ${spec.key}: $e');
      }
    }
    _loaded = isAvailable(TargetSet.droneBird, DetailMode.acquisition);
  }

  Future<void> setActive(TargetSet target, DetailMode detail) async {
    _target = target;
    _detail = detail;
    try {
      await _channel.invokeMethod('setMode', {'mode': _keyFor(target, detail)});
    } catch (e) {
      print('[InferenceService] ERROR setting active model: $e');
    }
  }

  Future<List<InferenceResult>> runOnFrame(
      CameraImage image, int rotationDegrees) async {
    if (!_loaded) return [];
    try {
      final List<dynamic> raw = await _channel.invokeMethod('runInference', {
        'yBytes':          image.planes[0].bytes,
        'uBytes':          image.planes[1].bytes,
        'vBytes':          image.planes[2].bytes,
        'width':           image.width,
        'height':          image.height,
        'yRowStride':      image.planes[0].bytesPerRow,
        'uvRowStride':     image.planes[1].bytesPerRow,
        'uvPixelStride':   image.planes[1].bytesPerPixel ?? 2,
        'rotationDegrees': rotationDegrees,
      });

      return raw
          .map((d) => InferenceResult(
                label:      d['label'] as String,
                classId:    d['classId'] as int,
                confidence: (d['confidence'] as num).toDouble(),
                x:          (d['x'] as num).toDouble(),
                y:          (d['y'] as num).toDouble(),
                width:      (d['width'] as num).toDouble(),
                height:     (d['height'] as num).toDouble(),
              ))
          .toList();
    } catch (e) {
      print('[InferenceService] ERROR in inference: $e');
      return [];
    }
  }

  Future<void> setConfThreshold(double threshold) async {
    try {
      await _channel.invokeMethod('setConfThreshold', {'threshold': threshold});
    } catch (e) {
      print('[InferenceService] ERROR setting threshold: $e');
    }
  }

  void dispose() {
    _channel.invokeMethod('dispose');
  }
}