package com.antigravity.androidscreen

import android.view.MotionEvent
import android.view.View
import java.io.DataOutputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue

class TouchSender(outputStream: OutputStream) {
    private val dataOut = DataOutputStream(outputStream)
    private val eventQueue = LinkedBlockingQueue<ByteArray>(64)
    @Volatile private var isRunning = true

    private val senderThread = Thread {
        while (isRunning) {
            try {
                val packet = eventQueue.take()
                synchronized(dataOut) {
                    dataOut.write(packet)
                    dataOut.flush()
                }
            } catch (e: InterruptedException) {
                break
            } catch (e: Exception) {
                break
            }
        }
    }.apply {
        name = "TouchSenderThread"
        priority = Thread.NORM_PRIORITY
        start()
    }

    fun handleTouchEvent(view: View, event: MotionEvent): Boolean {
        val width = view.width.toFloat()
        val height = view.height.toFloat()
        if (width <= 0 || height <= 0) return false

        val normX = (event.x / width).coerceIn(0f, 1f)
        val normY = (event.y / height).coerceIn(0f, 1f)

        val actionType: Byte = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> 0x01
            MotionEvent.ACTION_MOVE -> 0x02
            MotionEvent.ACTION_UP   -> 0x03
            MotionEvent.ACTION_CANCEL -> 0x03
            else -> return false
        }

        // 13 bytes: [1 byte type][4 bytes float X][4 bytes float Y][4 bytes float deltaY]
        val packet = ByteArray(13)
        packet[0] = actionType

        val xBits = java.lang.Float.floatToIntBits(normX)
        packet[1] = (xBits ushr 24).toByte()
        packet[2] = (xBits ushr 16).toByte()
        packet[3] = (xBits ushr 8).toByte()
        packet[4] = xBits.toByte()

        val yBits = java.lang.Float.floatToIntBits(normY)
        packet[5] = (yBits ushr 24).toByte()
        packet[6] = (yBits ushr 16).toByte()
        packet[7] = (yBits ushr 8).toByte()
        packet[8] = yBits.toByte()

        val dyBits = java.lang.Float.floatToIntBits(0.0f)
        packet[9]  = (dyBits ushr 24).toByte()
        packet[10] = (dyBits ushr 16).toByte()
        packet[11] = (dyBits ushr 8).toByte()
        packet[12] = dyBits.toByte()

        eventQueue.offer(packet)
        return true
    }

    fun stop() {
        isRunning = false
        senderThread.interrupt()
    }
}
