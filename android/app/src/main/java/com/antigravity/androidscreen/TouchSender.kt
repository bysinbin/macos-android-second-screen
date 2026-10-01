package com.antigravity.androidscreen

import android.view.MotionEvent
import android.view.View
import java.io.DataOutputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue

class TouchSender(outputStream: OutputStream) {
    private val dataOut = DataOutputStream(outputStream)
    private val eventQueue = LinkedBlockingQueue<ByteArray>(128)
    @Volatile private var isRunning = true
    private var lastTwoFingerY = 0f

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
        priority = Thread.MAX_PRIORITY
        start()
    }

    fun handleTouchEvent(view: View, event: MotionEvent): Boolean {
        val width = view.width.toFloat()
        val height = view.height.toFloat()
        if (width <= 0 || height <= 0) return false

        // Check if two-finger gesture for scrolling
        if (event.pointerCount >= 2) {
            val midY = (event.getY(0) + event.getY(1)) / 2f
            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN -> {
                    lastTwoFingerY = midY
                }
                MotionEvent.ACTION_MOVE -> {
                    val deltaY = (midY - lastTwoFingerY) / 10f
                    lastTwoFingerY = midY
                    if (Math.abs(deltaY) > 0.1f) {
                        sendPacket(0x05.toByte(), (event.getX(0) / width).coerceIn(0f, 1f), (midY / height).coerceIn(0f, 1f), deltaY)
                    }
                }
            }
            return true
        }

        val normX = (event.x / width).coerceIn(0f, 1f)
        val normY = (event.y / height).coerceIn(0f, 1f)

        val actionType: Byte = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> 0x01
            MotionEvent.ACTION_MOVE -> 0x02
            MotionEvent.ACTION_UP   -> 0x03
            MotionEvent.ACTION_CANCEL -> 0x03
            else -> return false
        }

        sendPacket(actionType, normX, normY, 0f)
        return true
    }

    private fun sendPacket(actionType: Byte, normX: Float, normY: Float, deltaY: Float) {
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

        val dyBits = java.lang.Float.floatToIntBits(deltaY)
        packet[9]  = (dyBits ushr 24).toByte()
        packet[10] = (dyBits ushr 16).toByte()
        packet[11] = (dyBits ushr 8).toByte()
        packet[12] = dyBits.toByte()

        eventQueue.offer(packet)
    }

    fun stop() {
        isRunning = false
        senderThread.interrupt()
    }
}
