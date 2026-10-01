package com.antigravity.androidscreen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.io.DataInputStream
import java.io.InputStream
import java.nio.ByteBuffer

class VideoDecoder(
    private val surface: Surface,
    private val onStreamReady: (width: Int, height: Int, fps: Int) -> Unit,
    private val onFpsUpdate: (fps: Int) -> Unit,
    private val onError: (Exception) -> Unit
) {
    private val TAG = "VideoDecoder"
    @Volatile private var isRunning = false
    private var mediaCodec: MediaCodec? = null
    private var decodeThread: Thread? = null

    fun start(inputStream: InputStream) {
        isRunning = true
        decodeThread = Thread {
            try {
                runDecodeLoop(inputStream)
            } catch (e: Exception) {
                if (isRunning) {
                    Log.e(TAG, "Decode loop error", e)
                    onError(e)
                }
            } finally {
                release()
            }
        }.apply {
            name = "VideoDecoderThread"
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun runDecodeLoop(inputStream: InputStream) {
        val dataIn = DataInputStream(inputStream)

        // 1. Read 16-byte handshake: "ANDR" (4) + width (4) + height (4) + fps (4)
        val magic = ByteArray(4)
        dataIn.readFully(magic)
        if (magic[0] != 0x41.toByte() || magic[1] != 0x4E.toByte() ||
            magic[2] != 0x44.toByte() || magic[3] != 0x52.toByte()) {
            throw IllegalStateException("Invalid stream magic bytes: " + String(magic))
        }

        val width = dataIn.readInt()
        val height = dataIn.readInt()
        val fps = dataIn.readInt()

        Log.i(TAG, "Stream handshake received: ${width}x${height} @ ${fps}fps")
        onStreamReady(width, height, fps)

        // 2. Initialize MediaCodec
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }

        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, surface, null, 0)
        codec.start()
        mediaCodec = codec

        val bufferInfo = MediaCodec.BufferInfo()
        var frameCount = 0
        var lastFpsTime = System.currentTimeMillis()

        var frameBuffer = ByteArray(512 * 1024)

        while (isRunning) {
            // Read 4-byte frame length
            val frameLength = dataIn.readInt()
            if (frameLength <= 0 || frameLength > 10 * 1024 * 1024) {
                Log.w(TAG, "Suspicious frame length: $frameLength")
                continue
            }

            if (frameBuffer.size < frameLength) {
                frameBuffer = ByteArray(frameLength + 64 * 1024)
            }

            // Read entire frame NAL units
            dataIn.readFully(frameBuffer, 0, frameLength)

            // Feed to MediaCodec
            val inIndex = codec.dequeueInputBuffer(10_000)
            if (inIndex >= 0) {
                val inputBuf: ByteBuffer? = codec.getInputBuffer(inIndex)
                inputBuf?.clear()
                inputBuf?.put(frameBuffer, 0, frameLength)
                codec.queueInputBuffer(inIndex, 0, frameLength, System.nanoTime() / 1000, 0)
            }

            // Drain output buffers to surface
            var outIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
            while (outIndex >= 0) {
                // Render directly to surface (zero-copy)
                codec.releaseOutputBuffer(outIndex, true)
                frameCount++
                outIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
            }

            // Update FPS counter every second
            val now = System.currentTimeMillis()
            if (now - lastFpsTime >= 1000) {
                val currentFps = (frameCount * 1000f / (now - lastFpsTime)).toInt()
                onFpsUpdate(currentFps)
                frameCount = 0
                lastFpsTime = now
            }
        }
    }

    fun stop() {
        isRunning = false
        decodeThread?.interrupt()
        release()
    }

    private fun release() {
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (ignored: Exception) {}
        mediaCodec = null
    }
}
