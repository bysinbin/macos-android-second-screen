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
    var pointerSpeed: Float = 1.0f

    var onDragStateChanged: ((Boolean) -> Unit)? = null
    var onGestureTriggered: ((String) -> Unit)? = null
    var onConnectionLost: (() -> Unit)? = null

    // Multi-touch stroke tracking
    private var maxPointersInStroke = 0
    private var strokeStartTime = 0L
    private var strokeStartX = 0f
    private var strokeStartY = 0f

    // 1-Finger tracking
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var isDragging = false
    private var isDragCandidate = false
    private var lastTapUpTime = 0L
    private var lastTapUpX = 0f
    private var lastTapUpY = 0f

    // 2-Finger tracking
    private var twoFingerDownTime = 0L
    private var twoFingerStartX = 0f
    private var twoFingerStartY = 0f
    private var lastTwoFingerX = 0f
    private var lastTwoFingerY = 0f
    private var twoFingerScrolled = false

    // 3-Finger tracking
    private var threeFingerDownTime = 0L
    private var threeFingerStartX = 0f
    private var threeFingerStartY = 0f
    private var threeFingerTriggered = false

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
                android.util.Log.e("TouchSender", "Socket write failed: ${e.message}")
                onConnectionLost?.invoke()
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

        if (!isTrackpadMode) {
            // DIRECT TOUCHSCREEN MODE (for Touch Bar or Direct Screen)
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

        // ==========================================
        // TRACKPAD MODE
        // ==========================================

        // Request parent to not intercept touch events
        view.parent?.requestDisallowInterceptTouchEvent(true)

        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            maxPointersInStroke = 1
        } else {
            maxPointersInStroke = maxOf(maxPointersInStroke, event.pointerCount)
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                strokeStartTime = System.currentTimeMillis()
                strokeStartX = event.x
                strokeStartY = event.y
                lastTouchX = event.x
                lastTouchY = event.y
                twoFingerScrolled = false
                threeFingerTriggered = false

                val timeSinceLastTap = strokeStartTime - lastTapUpTime
                val distFromLastTap = hypot(event.x - lastTapUpX, event.y - lastTapUpY)
                isDragCandidate = (timeSinceLastTap < 320 && distFromLastTap < 80f)

                if (!isDragLockActive && !isLeftButtonDown) {
                    cancelLongPress()
                    longPressRunnable = Runnable {
                        if (maxPointersInStroke == 1 && !isDragging) {
                            isDragging = true
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            sendPacket(0x0B.toByte(), 0f, 0f, 0f) // Mouse Down
                            onDragStateChanged?.invoke(true)
                        }
                    }
                    handler.postDelayed(longPressRunnable!!, 350)
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                cancelLongPress()
                if (event.pointerCount == 2) {
                    twoFingerDownTime = System.currentTimeMillis()
                    val midX = (event.getX(0) + event.getX(1)) / 2f
                    val midY = (event.getY(0) + event.getY(1)) / 2f
                    twoFingerStartX = midX
                    twoFingerStartY = midY
                    lastTwoFingerX = midX
                    lastTwoFingerY = midY
                    twoFingerScrolled = false
                } else if (event.pointerCount >= 3) {
                    threeFingerDownTime = System.currentTimeMillis()
                    val count = minOf(event.pointerCount, 4)
                    var midX = 0f
                    var midY = 0f
                    for (i in 0 until count) {
                        midX += event.getX(i)
                        midY += event.getY(i)
                    }
                    threeFingerStartX = midX / count
                    threeFingerStartY = midY / count
                    threeFingerTriggered = false
                    android.util.Log.d("TouchSender", "3+ Fingers Down! count=${event.pointerCount}")
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (maxPointersInStroke >= 3) {
                    // 3 or 4 fingers swipe gestures
                    val count = minOf(event.pointerCount, 4)
                    if (count >= 2) {
                        var midX = 0f
                        var midY = 0f
                        for (i in 0 until count) {
                            midX += event.getX(i)
                            midY += event.getY(i)
                        }
                        midX /= count
                        midY /= count

                        if (threeFingerStartX == 0f && threeFingerStartY == 0f) {
                            threeFingerStartX = midX
                            threeFingerStartY = midY
                        }

                        val dx = midX - threeFingerStartX
                        val dy = midY - threeFingerStartY
                        val dist = hypot(dx, dy)

                        if (!threeFingerTriggered && dist > 25f) {
                            threeFingerTriggered = true
                            android.util.Log.i("TouchSender", "3-Finger Gesture: dx=$dx, dy=$dy")
                            if (abs(dy) >= abs(dx)) {
                                if (dy < 0) {
                                    // Swipe UP -> Mission Control
                                    sendPacket(0x0D.toByte(), 0f, -1f, 0f)
                                    onGestureTriggered?.invoke("🪄 Mission Control")
                                    view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                } else {
                                    // Swipe DOWN -> App Exposé
                                    sendPacket(0x0D.toByte(), 0f, 1f, 0f)
                                    onGestureTriggered?.invoke("🪟 Uygulama Pencereleri")
                                    view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                }
                            } else {
                                if (dx < 0) {
                                    // Swipe LEFT -> Move Space Right
                                    sendPacket(0x0D.toByte(), -1f, 0f, 0f)
                                    onGestureTriggered?.invoke("Sonraki Masaüstü ⇨")
                                    view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                                } else {
                                    // Swipe RIGHT -> Move Space Left
                                    sendPacket(0x0D.toByte(), 1f, 0f, 0f)
                                    onGestureTriggered?.invoke("⇦ Önceki Masaüstü")
                                    view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                                }
                            }
                        }
                    }
                } else if (maxPointersInStroke == 2 && event.pointerCount >= 2) {
                    // 2-Finger Scroll
                    val midX = (event.getX(0) + event.getX(1)) / 2f
                    val midY = (event.getY(0) + event.getY(1)) / 2f
                    val deltaX = (midX - lastTwoFingerX) * 1.5f
                    val deltaY = (midY - lastTwoFingerY) * 1.5f
                    lastTwoFingerX = midX
                    lastTwoFingerY = midY

                    if (hypot(midX - twoFingerStartX, midY - twoFingerStartY) > 15f) {
                        twoFingerScrolled = true
                    }
                    if (abs(deltaY) > 0.3f || abs(deltaX) > 0.3f) {
                        sendPacket(0x05.toByte(), deltaX, 0f, deltaY)
                    }
                } else if (maxPointersInStroke == 1 && event.pointerCount == 1) {
                    // 1-Finger Move & Drag
                    val totalMoveDist = hypot(event.x - strokeStartX, event.y - strokeStartY)
                    if (totalMoveDist > 12f) {
                        cancelLongPress()
                        if (isDragCandidate && !isDragging && !isDragLockActive && !isLeftButtonDown) {
                            isDragging = true
                            isDragCandidate = false
                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            sendPacket(0x0B.toByte(), 0f, 0f, 0f) // Mouse Down
                            onDragStateChanged?.invoke(true)
                        }
                    }

                    val rawDx = (event.x - lastTouchX) / width
                    val rawDy = (event.y - lastTouchY) / height
                    val dx = rawDx * pointerSpeed
                    val dy = rawDy * pointerSpeed
                    lastTouchX = event.x
                    lastTouchY = event.y

                    if (abs(rawDx * width) > 0.8f || abs(rawDy * height) > 0.8f) {
                        if (isDragging || isDragLockActive || isLeftButtonDown) {
                            sendPacket(0x0A.toByte(), dx, dy, 0f)
                        } else {
                            sendPacket(0x07.toByte(), dx, dy, 0f)
                        }
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (maxPointersInStroke >= 3) {
                    val duration = System.currentTimeMillis() - threeFingerDownTime
                    val count = minOf(event.pointerCount, 4)
                    var midX = 0f
                    var midY = 0f
                    for (i in 0 until count) {
                        midX += event.getX(i)
                        midY += event.getY(i)
                    }
                    midX /= count
                    midY /= count
                    val dist = hypot(midX - threeFingerStartX, midY - threeFingerStartY)
                    if (!threeFingerTriggered && duration < 380 && dist < 30f) {
                        threeFingerTriggered = true
                        sendPacket(0x0D.toByte(), 0f, 0f, 0f) // 3-Finger Tap -> Look Up
                        onGestureTriggered?.invoke("🔍 Sözlük / Arama")
                        view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                    }
                } else if (maxPointersInStroke == 2 && event.pointerCount == 2) {
                    val duration = System.currentTimeMillis() - twoFingerDownTime
                    val midX = (event.getX(0) + event.getX(1)) / 2f
                    val midY = (event.getY(0) + event.getY(1)) / 2f
                    val dist = hypot(midX - twoFingerStartX, midY - twoFingerStartY)
                    if (!twoFingerScrolled && duration < 380 && dist < 30f) {
                        twoFingerScrolled = true
                        sendPacket(0x09.toByte(), 0f, 0f, 0f) // 2-Finger Tap -> Right Click
                        view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                    }
                }
            }

            MotionEvent.ACTION_UP -> {
                cancelLongPress()
                if (maxPointersInStroke == 1) {
                    val duration = System.currentTimeMillis() - strokeStartTime
                    val totalDist = hypot(event.x - strokeStartX, event.y - strokeStartY)

                    if (isDragLockActive || isLeftButtonDown) {
                        // Clutching while physical drag lock or left button is held
                    } else if (isDragging) {
                        isDragging = false
                        sendPacket(0x0C.toByte(), 0f, 0f, 0f) // Mouse Up
                        onDragStateChanged?.invoke(false)
                    } else if (isDragCandidate && totalDist < 25f) {
                        // Double tap without moving -> register click
                        sendPacket(0x08.toByte(), 0f, 0f, 0f)
                        isDragCandidate = false
                        lastTapUpTime = 0L
                    } else if (totalDist < 25f && duration < 350) {
                        // Single-Finger Tap to Click!
                        sendPacket(0x08.toByte(), 0f, 0f, 0f)
                        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        lastTapUpTime = System.currentTimeMillis()
                        lastTapUpX = event.x
                        lastTapUpY = event.y
                    }
                }

                // Reset stroke state
                maxPointersInStroke = 0
                threeFingerTriggered = false
                twoFingerScrolled = false
            }

            MotionEvent.ACTION_CANCEL -> {
                cancelLongPress()
                if (!isDragLockActive && !isLeftButtonDown && isDragging) {
                    isDragging = false
                    sendPacket(0x0C.toByte(), 0f, 0f, 0f)
                    onDragStateChanged?.invoke(false)
                }
                maxPointersInStroke = 0
                threeFingerTriggered = false
                twoFingerScrolled = false
            }
        }
        return true
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

    fun sendClick() {
        sendPacket(0x08.toByte(), 0f, 0f, 0f)
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
