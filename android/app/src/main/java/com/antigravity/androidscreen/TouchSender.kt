package com.antigravity.androidscreen

import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import java.io.DataOutputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.abs
import kotlin.math.hypot

class TouchSender(outputStream: OutputStream) {
    private val dataOut = DataOutputStream(outputStream)
    private val eventQueue = LinkedBlockingQueue<ByteArray>(128)
    @Volatile private var isRunning = true

    var isTrackpadMode: Boolean = false
    var isDragLockActive: Boolean = false
        private set
    var isLeftButtonDown: Boolean = false
        private set

    var onDragStateChanged: ((Boolean) -> Unit)? = null

    // Trackpad tracking state
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var downTouchX = 0f
    private var downTouchY = 0f
    private var downTimestamp = 0L
    private var hasMoved = false

    private var isDragging = false
    private var isDragCandidate = false
    private var lastTapUpTime = 0L
    private var lastTapUpX = 0f
    private var lastTapUpY = 0f

    private var lastTwoFingerY = 0f
    private var isTwoFingerGesture = false

    private val handler = Handler(Looper.getMainLooper())
    private var longPressRunnable: Runnable? = null

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
            cancelLongPress()
            if (!isDragLockActive && !isLeftButtonDown && isDragging) {
                isDragging = false
                sendPacket(0x0C.toByte(), 0f, 0f, 0f) // Mouse Up
                onDragStateChanged?.invoke(false)
            }

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
                    downTouchX = event.x
                    downTouchY = event.y
                    downTimestamp = System.currentTimeMillis()
                    hasMoved = false
                    isTwoFingerGesture = false

                    val timeSinceLastTap = System.currentTimeMillis() - lastTapUpTime
                    val distFromLastTap = hypot(event.x - lastTapUpX, event.y - lastTapUpY)

                    // Double-tap candidate: user tapped and touched down again within 300ms
                    if (timeSinceLastTap < 300 && distFromLastTap < 80f) {
                        isDragCandidate = true
                    } else {
                        isDragCandidate = false
                    }

                    // Schedule long-press to start drag/selection if held still
                    if (!isDragLockActive && !isLeftButtonDown) {
                        cancelLongPress()
                        longPressRunnable = Runnable {
                            if (!isTwoFingerGesture && !hasMoved && !isDragging) {
                                isDragging = true
                                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                sendPacket(0x0B.toByte(), 0f, 0f, 0f) // Mouse Down
                                onDragStateChanged?.invoke(true)
                            }
                        }
                        handler.postDelayed(longPressRunnable!!, 320)
                    }
                }

                MotionEvent.ACTION_MOVE -> {
                    if (isTwoFingerGesture) return true

                    val totalMoveDist = hypot(event.x - downTouchX, event.y - downTouchY)
                    if (totalMoveDist > 12f) {
                        cancelLongPress()
                        // Double-tap and drag gesture: start drag immediately upon movement
                        if (isDragCandidate && !isDragging && !isDragLockActive && !isLeftButtonDown) {
                            isDragging = true
                            isDragCandidate = false
                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            sendPacket(0x0B.toByte(), 0f, 0f, 0f) // Mouse Down
                            onDragStateChanged?.invoke(true)
                        }
                    }

                    val dx = (event.x - lastTouchX) / width
                    val dy = (event.y - lastTouchY) / height
                    lastTouchX = event.x
                    lastTouchY = event.y

                    if (abs(dx * width) > 1.5f || abs(dy * height) > 1.5f) {
                        hasMoved = true
                        if (isDragging || isDragLockActive || isLeftButtonDown) {
                            // Drag / selection move (left mouse button held down)
                            sendPacket(0x0A.toByte(), dx, dy, 0f)
                        } else {
                            // Normal cursor relative move
                            sendPacket(0x07.toByte(), dx, dy, 0f)
                        }
                    }
                }

                MotionEvent.ACTION_UP -> {
                    cancelLongPress()
                    if (isTwoFingerGesture) return true

                    val duration = System.currentTimeMillis() - downTimestamp

                    if (isDragLockActive || isLeftButtonDown) {
                        // User is clutching (lifting finger to re-swipe while drag lock or left button is held)
                        // Do NOT cancel dragging or send mouse up!
                    } else if (isDragging) {
                        isDragging = false
                        sendPacket(0x0C.toByte(), 0f, 0f, 0f) // Mouse Up
                        onDragStateChanged?.invoke(false)
                    } else if (isDragCandidate) {
                        // Double tap without moving -> register as click (double-click on Mac)
                        sendPacket(0x08.toByte(), 0f, 0f, 0f)
                        isDragCandidate = false
                        lastTapUpTime = 0L
                    } else {
                        // Single tap click
                        if (!hasMoved && duration < 250) {
                            sendPacket(0x08.toByte(), 0f, 0f, 0f)
                            lastTapUpTime = System.currentTimeMillis()
                            lastTapUpX = event.x
                            lastTapUpY = event.y
                        }
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    cancelLongPress()
                    if (!isDragLockActive && !isLeftButtonDown) {
                        if (isDragging) {
                            isDragging = false
                            sendPacket(0x0C.toByte(), 0f, 0f, 0f)
                            onDragStateChanged?.invoke(false)
                        }
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

    private fun cancelLongPress() {
        longPressRunnable?.let {
            handler.removeCallbacks(it)
            longPressRunnable = null
        }
    }

    fun setDragLock(enabled: Boolean) {
        isDragLockActive = enabled
        if (enabled) {
            isDragging = true
            sendPacket(0x0B.toByte(), 0f, 0f, 0f) // Mouse Down
            onDragStateChanged?.invoke(true)
        } else {
            if (!isLeftButtonDown) {
                isDragging = false
                sendPacket(0x0C.toByte(), 0f, 0f, 0f) // Mouse Up
                onDragStateChanged?.invoke(false)
            }
        }
    }

    fun sendMouseDown() {
        isLeftButtonDown = true
        isDragging = true
        sendPacket(0x0B.toByte(), 0f, 0f, 0f)
    }

    fun sendMouseUp() {
        isLeftButtonDown = false
        if (!isDragLockActive) {
            isDragging = false
            sendPacket(0x0C.toByte(), 0f, 0f, 0f)
        }
    }

    fun sendRightClick() {
        sendPacket(0x09.toByte(), 0f, 0f, 0f)
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

        val isMovePacket = actionType == 0x02.toByte() ||
                           actionType == 0x07.toByte() ||
                           actionType == 0x0A.toByte() ||
                           actionType == 0x05.toByte()

        if (isMovePacket) {
            // Keep queue fresh for move packets
            if (eventQueue.size > 40) {
                eventQueue.poll()
            }
            eventQueue.offer(packet)
        } else {
            // Critical button up/down/click packets must NEVER be dropped
            try {
                eventQueue.put(packet)
            } catch (e: InterruptedException) {
                eventQueue.offer(packet)
            }
        }
    }

    fun stop() {
        isRunning = false
        cancelLongPress()
        senderThread.interrupt()
    }
}
