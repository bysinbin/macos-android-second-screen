package com.antigravity.androidscreen

import android.view.MotionEvent
import android.view.View
import java.io.DataOutputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.abs

class TouchSender(outputStream: OutputStream) {
    private val dataOut = DataOutputStream(outputStream)
    private val eventQueue = LinkedBlockingQueue<ByteArray>(128)
    @Volatile private var isRunning = true

    var isTrackpadMode: Boolean = false

    // Trackpad tracking state
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var downTimestamp = 0L
    private var hasMoved = false
    private var lastTwoFingerY = 0f
    private var isTwoFingerGesture = false

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

        // Two-finger gestures (Scroll & Right click)
        if (event.pointerCount >= 2) {
            val midY = (event.getY(0) + event.getY(1)) / 2f
            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN -> {
                    isTwoFingerGesture = true
                    lastTwoFingerY = midY
                }
                MotionEvent.ACTION_MOVE -> {
                    val deltaY = (midY - lastTwoFingerY) / 8f
                    lastTwoFingerY = midY
                    if (abs(deltaY) > 0.1f) {
                        sendPacket(0x05.toByte(), 0f, 0f, deltaY)
                    }
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    if (event.eventTime - event.downTime < 300) {
                        // Two finger tap -> Right click
                        sendPacket(0x09.toByte(), 0f, 0f, 0f)
                    }
                }
            }
            return true
        }

        if (isTrackpadMode) {
            // MOUSE / TRACKPAD MODE
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchX = event.x
                    lastTouchY = event.y
                    downTimestamp = System.currentTimeMillis()
                    hasMoved = false
                    isTwoFingerGesture = false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isTwoFingerGesture) return true
                    val dx = (event.x - lastTouchX) / width
                    val dy = (event.y - lastTouchY) / height
                    lastTouchX = event.x
                    lastTouchY = event.y

                    if (abs(dx * width) > 2f || abs(dy * height) > 2f) {
                        hasMoved = true
                        // Relative mouse cursor move
                        sendPacket(0x07.toByte(), dx, dy, 0f)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (isTwoFingerGesture) return true
                    val duration = System.currentTimeMillis() - downTimestamp
                    if (!hasMoved && duration < 300) {
                        // Quick tap to left click
                        sendPacket(0x08.toByte(), 0f, 0f, 0f)
                    }
                }
            }
            return true
        } else {
            // DIRECT TOUCHSCREEN MODE
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
