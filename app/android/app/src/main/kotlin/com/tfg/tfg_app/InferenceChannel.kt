package com.tfg.tfg_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Environment
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * On-device YOLOv8 inference over a Platform Channel.
 *
 * Supports an arbitrary set of models held at once, each keyed by a string.
 * Per model we store the interpreter, its input size, its class names, and
 * its input layout (NHWC vs NCHW), all read from the interpreter -- so models
 * exported by different toolchains (different axis order) all run unchanged.
 *
 * Coordinate scale is also auto-detected per model (normalized [0,1] vs pixel
 * space [0,inputSize]).
 */
class InferenceChannel(private val context: Context) {

    companion object {
        const val CHANNEL = "com.tfg.tfg_app/inference"
        const val IOU_THRESHOLD = 0.45f
        const val SHARPEN_K = 0.6f

        @JvmStatic var debugFrameSaved = false
        @JvmStatic var confThreshold = 0.25f
    }

    // Per-key state.
    private val interpreters = HashMap<String, Interpreter>()
    private val inputSizes   = HashMap<String, Int>()
    private val inputIsNchw  = HashMap<String, Boolean>()  // true = [1,3,H,W]; false = [1,H,W,3]
    private val classNames   = HashMap<String, Array<String>>()
    private var activeKey: String = ""

    private val coordScaleIsPixel = HashMap<String, Boolean>()
    private val diagFrameCount = HashMap<String, Int>()
    private val diagLogCount   = HashMap<String, Int>()

    // Letterbox bookkeeping for the current frame.
    private var lbLeft: Float = 0f
    private var lbTop: Float = 0f
    private var lbNewW: Int = 0
    private var lbNewH: Int = 0

    // -- Load model ------------------------------------------------------------

    fun loadModel(modelName: String, key: String, names: Array<String>): Boolean {
        return try {
            val options = Interpreter.Options().apply { numThreads = 4 }
            val interp = Interpreter(loadModelFile(modelName), options)

            // Robustly derive input size and layout from the input shape.
            // NHWC = [1, H, W, 3]  -> spatial size is shape[1] (== shape[2])
            // NCHW = [1, 3, H, W]  -> spatial size is shape[2] (== shape[3])
            // In both cases the spatial size is the LARGEST value in the shape
            // (512 or 320), never the 1 (batch) or 3 (channels). Detecting NCHW
            // by "channels axis is at index 1" lets us feed the buffer correctly.
            val inShape = interp.getInputTensor(0).shape()   // rank-4
            val isNchw = inShape.size == 4 && inShape[1] == 3 && inShape[3] != 3
            val inputSize = inShape.max()   // largest axis = spatial side

            interpreters[key]?.close()
            interpreters[key] = interp
            inputSizes[key]   = inputSize
            inputIsNchw[key]  = isNchw
            classNames[key]   = names
            coordScaleIsPixel.remove(key)
            diagFrameCount.remove(key)
            diagLogCount.remove(key)

            if (interpreters.size == 1) activeKey = key

            android.util.Log.d("YOLO",
                "Loaded '$modelName' as '$key' (input ${inputSize}px, " +
                        "layout ${if (isNchw) "NCHW" else "NHWC"}, shape ${inShape.joinToString()}, " +
                        "classes ${names.joinToString()})")
            true
        } catch (e: Exception) {
            android.util.Log.w("YOLO", "Could not load '$modelName' for '$key': ${e.message}")
            false
        }
    }

    fun setMode(key: String): String {
        activeKey = when {
            interpreters.containsKey(key) -> key
            interpreters.isNotEmpty()     -> interpreters.keys.first()
            else                          -> activeKey
        }
        android.util.Log.d("YOLO", "Active model -> $activeKey (requested $key)")
        return activeKey
    }

    private fun loadModelFile(modelName: String): MappedByteBuffer {
        val afd = context.assets.openFd("flutter_assets/assets/$modelName")
        val inputStream = FileInputStream(afd.fileDescriptor)
        val fileChannel = inputStream.channel
        return fileChannel.map(FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
    }

    // -- Main inference --------------------------------------------------------

    fun runInference(
        yBytes: ByteArray, uBytes: ByteArray, vBytes: ByteArray,
        width: Int, height: Int,
        yRowStride: Int, uvRowStride: Int, uvPixelStride: Int,
        rotationDegrees: Int
    ): List<Map<String, Any>> {
        val interp = interpreters[activeKey] ?: return emptyList()
        val inputSize = inputSizes[activeKey] ?: return emptyList()
        val names = classNames[activeKey] ?: return emptyList()
        val isNchw = inputIsNchw[activeKey] ?: false

        // 1. YUV -> Bitmap
        val bitmap = yuvToBitmap(
            yBytes, uBytes, vBytes, width, height,
            yRowStride, uvRowStride, uvPixelStride
        )

        // 2. Rotate to portrait
        val rotated = if (rotationDegrees != 0) {
            val matrix = Matrix()
            matrix.postRotate(rotationDegrees.toFloat())
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } else bitmap

        // 3. Letterbox into inputSize x inputSize
        val rotW = rotated.width.toFloat()
        val rotH = rotated.height.toFloat()
        val scale = minOf(inputSize / rotW, inputSize / rotH)
        val newW = (rotW * scale).toInt()
        val newH = (rotH * scale).toInt()
        val resized = Bitmap.createScaledBitmap(rotated, newW, newH, true)
        val scaled = Bitmap.createBitmap(inputSize, inputSize, Bitmap.Config.ARGB_8888)
        val lbCanvas = Canvas(scaled)
        lbCanvas.drawColor(Color.BLACK)
        val left = (inputSize - newW) / 2f
        val top  = (inputSize - newH) / 2f
        lbCanvas.drawBitmap(resized, left, top, null)
        lbLeft = left; lbTop = top; lbNewW = newW; lbNewH = newH

        // 4. Enhance
        val enhanced = enhanceBitmap(scaled)

        // 5. Debug frame (once)
        if (!debugFrameSaved) {
            debugFrameSaved = true
            try {
                val dir = context.getExternalFilesDir(Environment.DIRECTORY_PICTURES)
                val file = File(dir, "debug_frame.png")
                FileOutputStream(file).use { enhanced.compress(Bitmap.CompressFormat.PNG, 100, it) }
                android.util.Log.d("YOLO", "debug_frame saved: ${file.absolutePath}")
            } catch (e: Exception) {
                android.util.Log.e("YOLO", "Error saving debug_frame", e)
            }
        }

        // 6. Bitmap -> ByteBuffer (layout-aware)
        val inputBuffer = bitmapToByteBuffer(enhanced, inputSize, isNchw)

        // 7. Allocate output from model shape [1, C, N] and run
        val outShape = interp.getOutputTensor(0).shape()
        val channels = outShape[1]
        val anchors  = outShape[2]
        val output = Array(1) { Array(channels) { FloatArray(anchors) } }
        interp.run(inputBuffer, output)

        // 8. Parse + NMS
        return parseAndNms(output[0], inputSize, names)
    }

    // -- Image enhancement -----------------------------------------------------

    private fun enhanceBitmap(src: Bitmap): Bitmap {
        val toned = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(toned)
        val paint  = Paint()
        val contrast   = 1.25f
        val brightness = 15f
        val cm = ColorMatrix(floatArrayOf(
            contrast, 0f, 0f, 0f, brightness,
            0f, contrast, 0f, 0f, brightness,
            0f, 0f, contrast, 0f, brightness,
            0f, 0f, 0f, 1f, 0f
        ))
        paint.colorFilter = ColorMatrixColorFilter(cm)
        canvas.drawBitmap(src, 0f, 0f, paint)
        return sharpen(toned, SHARPEN_K)
    }

    private fun sharpen(src: Bitmap, k: Float): Bitmap {
        val w = src.width; val h = src.height
        val px = IntArray(w * h); src.getPixels(px, 0, w, 0, 0, w, h)
        val out = px.copyOf()
        val center = 1f + 4f * k
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val i = y * w + x
                val c = px[i]; val up = px[i - w]; val dn = px[i + w]; val lf = px[i - 1]; val rt = px[i + 1]
                val r = clamp(center * ((c shr 16) and 0xFF) - k * (((up shr 16) and 0xFF) + ((dn shr 16) and 0xFF) + ((lf shr 16) and 0xFF) + ((rt shr 16) and 0xFF)))
                val g = clamp(center * ((c shr 8) and 0xFF) - k * (((up shr 8) and 0xFF) + ((dn shr 8) and 0xFF) + ((lf shr 8) and 0xFF) + ((rt shr 8) and 0xFF)))
                val b = clamp(center * (c and 0xFF) - k * ((up and 0xFF) + (dn and 0xFF) + (lf and 0xFF) + (rt and 0xFF)))
                out[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        val result = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        result.setPixels(out, 0, w, 0, 0, w, h)
        return result
    }

    private fun clamp(v: Float): Int = v.toInt().coerceIn(0, 255)

    // -- YUV -> Bitmap ---------------------------------------------------------

    private fun yuvToBitmap(
        yBytes: ByteArray, uBytes: ByteArray, vBytes: ByteArray,
        width: Int, height: Int,
        yRowStride: Int, uvRowStride: Int, uvPixelStride: Int
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val yIdx  = y * yRowStride + x
                val uvIdx = (y shr 1) * uvRowStride + (x shr 1) * uvPixelStride
                val yVal = yBytes[yIdx].toInt() and 0xFF
                val uVal = (uBytes[uvIdx].toInt() and 0xFF) - 128
                val vVal = (vBytes[uvIdx].toInt() and 0xFF) - 128
                val r = (yVal + 1.402f * vVal).toInt().coerceIn(0, 255)
                val g = (yVal - 0.344136f * uVal - 0.714136f * vVal).toInt().coerceIn(0, 255)
                val b = (yVal + 1.772f * uVal).toInt().coerceIn(0, 255)
                pixels[y * width + x] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        return bitmap
    }

    // -- Bitmap -> ByteBuffer (NHWC or NCHW) -----------------------------------

    private fun bitmapToByteBuffer(bitmap: Bitmap, inputSize: Int, isNchw: Boolean): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(inputSize * inputSize * 3 * 4)
        buffer.order(ByteOrder.nativeOrder())
        val pixels = IntArray(inputSize * inputSize)
        bitmap.getPixels(pixels, 0, inputSize, 0, 0, inputSize, inputSize)

        if (isNchw) {
            // NCHW: all R, then all G, then all B (channel-planar).
            for (pixel in pixels) buffer.putFloat(((pixel shr 16) and 0xFF) / 255f)
            for (pixel in pixels) buffer.putFloat(((pixel shr 8)  and 0xFF) / 255f)
            for (pixel in pixels) buffer.putFloat((pixel           and 0xFF) / 255f)
        } else {
            // NHWC: interleaved R,G,B per pixel.
            for (pixel in pixels) {
                buffer.putFloat(((pixel shr 16) and 0xFF) / 255f)
                buffer.putFloat(((pixel shr 8)  and 0xFF) / 255f)
                buffer.putFloat((pixel           and 0xFF) / 255f)
            }
        }
        buffer.rewind()
        return buffer
    }

    // -- Parse + NMS (generic over class count, robust to coord scale) ---------

    private fun parseAndNms(
        output: Array<FloatArray>, inputSize: Int, names: Array<String>
    ): List<Map<String, Any>> {
        data class Det(
            val cx: Float, val cy: Float, val w: Float, val h: Float,
            val classId: Int, val conf: Float
        )

        val numClasses = output.size - 4
        if (numClasses < 1) return emptyList()

        val n = output[0].size

        val isPixel = coordScaleIsPixel.getOrPut(activeKey) {
            var mx = 0f
            for (i in 0 until n) {
                val v = maxOf(output[0][i], output[1][i], output[2][i], output[3][i])
                if (v > mx) mx = v
            }
            mx > 2f
        }
        val norm = if (isPixel) inputSize.toFloat() else 1f

        val scaleX = inputSize.toFloat() / lbNewW
        val scaleY = inputSize.toFloat() / lbNewH
        val offX   = lbLeft / inputSize
        val offY   = lbTop  / inputSize

        val candidates = mutableListOf<Det>()
        var afterConf = 0
        var afterCoord = 0

        for (i in 0 until n) {
            val cx = (output[0][i] / norm - offX) * scaleX
            val cy = (output[1][i] / norm - offY) * scaleY
            val w  = (output[2][i] / norm) * scaleX
            val h  = (output[3][i] / norm) * scaleY

            var bestId = 0
            var bestScore = output[4][i]
            for (c in 1 until numClasses) {
                val s = output[4 + c][i]
                if (s > bestScore) { bestScore = s; bestId = c }
            }

            if (bestScore < confThreshold || w <= 0f || h <= 0f) continue
            afterConf++
            if (cx < 0f || cx > 1f || cy < 0f || cy > 1f) continue
            afterCoord++
            candidates.add(Det(cx, cy, w, h, bestId, bestScore))
        }

        candidates.sortByDescending { it.conf }
        val kept = mutableListOf<Det>()
        for (det in candidates) {
            var suppressed = false
            for (k in kept) {
                if (k.classId != det.classId) continue
                if (iou(det.cx, det.cy, det.w, det.h, k.cx, k.cy, k.w, k.h) > IOU_THRESHOLD) {
                    suppressed = true; break
                }
            }
            if (!suppressed) kept.add(det)
        }

        val fc = (diagFrameCount[activeKey] ?: 0) + 1
        diagFrameCount[activeKey] = fc
        val logged = diagLogCount[activeKey] ?: 0
        if ((fc == 1 || fc % 45 == 0) && logged < 6) {
            diagLogCount[activeKey] = logged + 1
            val sb = StringBuilder()
            for (c in output.indices) {
                var m = -Float.MAX_VALUE
                val ch = output[c]
                for (i in 0 until n) if (ch[i] > m) m = ch[i]
                sb.append("c$c=").append(m).append(' ')
            }
            android.util.Log.d("YOLODIAG",
                "key=$activeKey f=$fc coords=${if (isPixel) "PIXEL" else "NORM"} " +
                        "conf=$confThreshold afterConf=$afterConf afterCoord=$afterCoord kept=${kept.size} | $sb")
        }

        return kept.map { d ->
            mapOf(
                "label"      to (names.getOrElse(d.classId) { "class_${d.classId}" }),
                "classId"    to d.classId,
                "confidence" to d.conf.toDouble(),
                "x"          to d.cx.toDouble(),
                "y"          to d.cy.toDouble(),
                "width"      to d.w.toDouble(),
                "height"     to d.h.toDouble(),
            )
        }
    }

    private fun iou(
        cx1: Float, cy1: Float, w1: Float, h1: Float,
        cx2: Float, cy2: Float, w2: Float, h2: Float
    ): Float {
        val ax1 = cx1 - w1/2; val ay1 = cy1 - h1/2
        val ax2 = cx1 + w1/2; val ay2 = cy1 + h1/2
        val bx1 = cx2 - w2/2; val by1 = cy2 - h2/2
        val bx2 = cx2 + w2/2; val by2 = cy2 + h2/2
        val interW = maxOf(0f, minOf(ax2, bx2) - maxOf(ax1, bx1))
        val interH = maxOf(0f, minOf(ay2, by2) - maxOf(ay1, by1))
        val inter  = interW * interH
        if (inter == 0f) return 0f
        return inter / (w1 * h1 + w2 * h2 - inter)
    }

    fun dispose() {
        for (interp in interpreters.values) interp.close()
        interpreters.clear()
        inputSizes.clear()
        inputIsNchw.clear()
        classNames.clear()
        coordScaleIsPixel.clear()
        diagFrameCount.clear()
        diagLogCount.clear()
    }
}