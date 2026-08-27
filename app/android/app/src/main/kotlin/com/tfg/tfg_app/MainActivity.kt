package com.tfg.tfg_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var inferenceChannel: InferenceChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        inferenceChannel = InferenceChannel(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, InferenceChannel.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "loadModel" -> {
                        val modelName = call.argument<String>("modelName")
                            ?: "best_int8.tflite"
                        // Composite key: "<targetSet>_<detailMode>", e.g. "heliPlane_confirmation".
                        val key = call.argument<String>("mode") ?: "droneBird_acquisition"
                        // Class names in the model's own index order (must match data.yaml).
                        val names = (call.argument<List<String>>("classNames")
                            ?: listOf("bird", "drone")).toTypedArray()
                        result.success(inferenceChannel.loadModel(modelName, key, names))
                    }
                    "setMode" -> {
                        val key = call.argument<String>("mode") ?: "droneBird_acquisition"
                        result.success(inferenceChannel.setMode(key))
                    }
                    "runInference" -> {
                        val detections = inferenceChannel.runInference(
                            yBytes          = call.argument<ByteArray>("yBytes")!!,
                            uBytes          = call.argument<ByteArray>("uBytes")!!,
                            vBytes          = call.argument<ByteArray>("vBytes")!!,
                            width           = call.argument<Int>("width")!!,
                            height          = call.argument<Int>("height")!!,
                            yRowStride      = call.argument<Int>("yRowStride")!!,
                            uvRowStride     = call.argument<Int>("uvRowStride")!!,
                            uvPixelStride   = call.argument<Int>("uvPixelStride")!!,
                            rotationDegrees = call.argument<Int>("rotationDegrees") ?: 0,
                        )
                        result.success(detections)
                    }
                    "setConfThreshold" -> {
                        val threshold = call.argument<Double>("threshold") ?: 0.25
                        InferenceChannel.confThreshold = threshold.toFloat().coerceIn(0.05f, 0.95f)
                        result.success(null)
                    }
                    "dispose" -> {
                        inferenceChannel.dispose()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}