package com.antigravity.androidscreen

import android.annotation.SuppressLint
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val TAG = "MainActivity"

    private lateinit var surfaceView: SurfaceView
    private lateinit var hudContainer: LinearLayout
    private lateinit var btnShowHud: TextView
    private lateinit var tvStatus: TextView
    private lateinit var tvStats: TextView
    private lateinit var btnUsb: Button
    private lateinit var btnWifiDiscover: Button
    private lateinit var etManualIp: EditText
    private lateinit var btnConnectManual: Button
    private lateinit var btnRotate: Button
    private lateinit var btnHideHud: Button
    private lateinit var btnDisconnect: Button
    private lateinit var layoutConnectedActions: LinearLayout
    private lateinit var btnToggleMode: Button
    private lateinit var btnFloatingMode: TextView
    private lateinit var btnFloatingDrag: TextView
    private lateinit var tvDragIndicator: TextView
    private lateinit var layoutFloatingPills: LinearLayout
    private lateinit var layoutTrackpadButtons: LinearLayout
    private lateinit var btnTrackpadLeft: Button
    private lateinit var btnTrackpadDragLock: Button
    private lateinit var btnTrackpadRight: Button

    private var isTrackpadMode = false

    private var socket: Socket? = null
    private var videoDecoder: VideoDecoder? = null
    private var touchSender: TouchSender? = null
    private var bonjourDiscovery: BonjourDiscovery? = null
    private var isConnected = false
    private var surfaceReady = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private val autoHideRunnable = Runnable { hideHud() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        applyFullscreen()

        initViews()
        setupListeners()
        updateModeUI()
    }

    private fun initViews() {
        surfaceView = findViewById(R.id.surface_view)
        hudContainer = findViewById(R.id.hud_container)
        btnShowHud = findViewById(R.id.btn_show_hud)
        tvStatus = findViewById(R.id.tv_status)
        tvStats = findViewById(R.id.tv_stats)
        btnUsb = findViewById(R.id.btn_usb)
        btnWifiDiscover = findViewById(R.id.btn_wifi_discover)
        etManualIp = findViewById(R.id.et_manual_ip)
        btnConnectManual = findViewById(R.id.btn_connect_manual)
        btnRotate = findViewById(R.id.btn_rotate)
        btnHideHud = findViewById(R.id.btn_hide_hud)
        btnDisconnect = findViewById(R.id.btn_disconnect)
        layoutConnectedActions = findViewById(R.id.layout_connected_actions)
        btnToggleMode = findViewById(R.id.btn_toggle_mode)
        btnFloatingMode = findViewById(R.id.btn_floating_mode)
        btnFloatingDrag = findViewById(R.id.btn_floating_drag)
        tvDragIndicator = findViewById(R.id.tv_drag_indicator)
        layoutFloatingPills = findViewById(R.id.layout_floating_pills)
        layoutTrackpadButtons = findViewById(R.id.layout_trackpad_buttons)
        btnTrackpadLeft = findViewById(R.id.btn_trackpad_left)
        btnTrackpadDragLock = findViewById(R.id.btn_trackpad_drag_lock)
        btnTrackpadRight = findViewById(R.id.btn_trackpad_right)

        surfaceView.holder.addCallback(this)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupListeners() {
        val toggleModeAction = {
            isTrackpadMode = !isTrackpadMode
            touchSender?.isTrackpadMode = isTrackpadMode
            updateModeUI()
            val msg = if (isTrackpadMode) "🖱️ Mouse (Trackpad) Moduna geçildi" else "📱 Dokunmatik (Touch) Moduna geçildi"
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        }

        btnToggleMode.setOnClickListener { toggleModeAction() }
        btnFloatingMode.setOnClickListener { toggleModeAction() }

        val toggleDragLockAction = {
            val sender = touchSender
            if (sender != null) {
                val newState = !sender.isDragLockActive
                sender.setDragLock(newState)
                updateDragLockUI(newState)
            } else {
                Toast.makeText(this, "Önce Mac'e bağlanın", Toast.LENGTH_SHORT).show()
            }
        }

        btnFloatingDrag.setOnClickListener { toggleDragLockAction() }
        btnTrackpadDragLock.setOnClickListener { toggleDragLockAction() }

        // Trackpad Left button (Hold to drag / click)
        btnTrackpadLeft.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    v.setBackgroundResource(R.drawable.btn_cyan)
                    (v as? Button)?.setTextColor(0xFF000000.toInt())
                    touchSender?.sendMouseDown()
                    updateDragIndicator(true)
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.setBackgroundResource(R.drawable.btn_outline)
                    (v as? Button)?.setTextColor(resources.getColor(R.color.text_primary, theme))
                    touchSender?.sendMouseUp()
                    if (touchSender?.isDragLockActive != true) {
                        updateDragIndicator(false)
                    }
                    true
                }
                else -> false
            }
        }

        // Trackpad Right click
        btnTrackpadRight.setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            touchSender?.sendRightClick()
        }

        btnUsb.setOnClickListener {
            connectToServer("127.0.0.1", 8888, "USB (Kablolu)")
        }

        btnWifiDiscover.setOnClickListener {
            startWifiAutoDiscovery()
        }

        btnConnectManual.setOnClickListener {
            val input = etManualIp.text.toString().trim()
            if (input.isEmpty()) {
                Toast.makeText(this, "Lütfen IP adresi girin", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val parts = input.split(":")
            val host = parts[0]
            val port = if (parts.size > 1) parts[1].toIntOrNull() ?: 8888 else 8888
            connectToServer(host, port, "Wi-Fi ($host)")
        }

        btnRotate.setOnClickListener {
            requestedOrientation = if (requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE) {
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
        }

        btnHideHud.setOnClickListener {
            hideHud()
        }

        btnShowHud.setOnClickListener {
            showHud()
        }

        btnDisconnect.setOnClickListener {
            disconnect()
        }

        surfaceView.setOnTouchListener { v, event ->
            if (isConnected) {
                touchSender?.handleTouchEvent(v, event) ?: false
            } else {
                false
            }
        }
    }

    private fun updateModeUI() {
        if (isTrackpadMode) {
            btnToggleMode.text = "🖱️ Mod: Mouse / Touchpad"
            btnFloatingMode.text = "🖱️ Mouse"
            if (hudContainer.visibility == View.GONE) {
                btnFloatingDrag.visibility = View.VISIBLE
                if (isConnected) layoutTrackpadButtons.visibility = View.VISIBLE
            }
        } else {
            btnToggleMode.text = "📱 Mod: Dokunmatik (Touch)"
            btnFloatingMode.text = "📱 Dokunmatik"
            btnFloatingDrag.visibility = View.GONE
            layoutTrackpadButtons.visibility = View.GONE
            tvDragIndicator.visibility = View.GONE
        }
    }

    private fun updateDragIndicator(isDragging: Boolean) {
        if (isDragging && isTrackpadMode) {
            tvDragIndicator.text = if (touchSender?.isDragLockActive == true) "🔒 Seçim Modu: Sürükleyin" else "✋ Seçim Yapılıyor..."
            tvDragIndicator.visibility = View.VISIBLE
        } else {
            tvDragIndicator.visibility = View.GONE
        }
    }

    private fun updateDragLockUI(isActive: Boolean) {
        if (isActive) {
            btnFloatingDrag.text = "🔒 Seçim Açık"
            btnFloatingDrag.setTextColor(0xFF00FFCC.toInt())
            btnTrackpadDragLock.text = "🔒 Seçim Açık"
            btnTrackpadDragLock.setBackgroundResource(R.drawable.btn_cyan)
            btnTrackpadDragLock.setTextColor(0xFF000000.toInt())
            updateDragIndicator(true)
            Toast.makeText(this, "🔒 Seçim kilidi açık: Parmağınızı sürükleyerek seçin", Toast.LENGTH_SHORT).show()
        } else {
            btnFloatingDrag.text = "✋ Seç / Sürükle"
            btnFloatingDrag.setTextColor(resources.getColor(R.color.accent_cyan, theme))
            btnTrackpadDragLock.text = "✋ Seçim Kilidi"
            btnTrackpadDragLock.setBackgroundResource(R.drawable.btn_outline)
            btnTrackpadDragLock.setTextColor(resources.getColor(R.color.accent_cyan, theme))
            updateDragIndicator(false)
        }
    }

    private fun startWifiAutoDiscovery() {
        tvStatus.text = "🔍 Mac aranıyor (Wi-Fi Bonjour)..."
        btnWifiDiscover.isEnabled = false

        bonjourDiscovery?.stopDiscovery()
        bonjourDiscovery = BonjourDiscovery(this) { host, port ->
            mainHandler.post {
                bonjourDiscovery?.stopDiscovery()
                btnWifiDiscover.isEnabled = true
                tvStatus.text = "Mac bulundu: $host:$port. Bağlanılıyor..."
                connectToServer(host, port, "Wi-Fi (Otomatik)")
            }
        }
        bonjourDiscovery?.startDiscovery()

        // 10 second timeout for discovery
        mainHandler.postDelayed({
            if (!isConnected && btnWifiDiscover.isEnabled == false) {
                btnWifiDiscover.isEnabled = true
                tvStatus.text = "Mac otomatik bulunamadı. Lütfen elle IP girin veya USB deneyin."
            }
        }, 10000)
    }

    private fun connectToServer(host: String, port: Int, modeLabel: String) {
        if (!surfaceReady) {
            Toast.makeText(this, "Görüntü paneli hazırlanıyor...", Toast.LENGTH_SHORT).show()
            return
        }

        disconnect()
        tvStatus.text = "⏳ $modeLabel bağlanıyor..."

        Thread {
            try {
                val newSocket = Socket()
                newSocket.tcpNoDelay = true
                newSocket.connect(InetSocketAddress(host, port), 5000)
                this.socket = newSocket

                val inputStream = newSocket.getInputStream()
                val outputStream = newSocket.getOutputStream()

                val sender = TouchSender(outputStream)
                sender.isTrackpadMode = isTrackpadMode
                sender.onDragStateChanged = { isDragging ->
                    mainHandler.post {
                        updateDragIndicator(isDragging)
                        if (!isDragging && touchSender?.isDragLockActive != true) {
                            updateDragLockUI(false)
                        }
                    }
                }
                this.touchSender = sender

                val decoder = VideoDecoder(
                    surface = surfaceView.holder.surface,
                    onStreamReady = { w, h, fps ->
                        mainHandler.post {
                            if (w > h) {
                                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                            } else {
                                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            }
                            tvStatus.text = "🟢 Bağlandı: ${w}x${h} @ ${fps}fps ($modeLabel)"
                            layoutConnectedActions.visibility = View.VISIBLE
                            tvStats.visibility = View.VISIBLE
                            scheduleAutoHideHud()
                        }
                    },
                    onFpsUpdate = { fps ->
                        mainHandler.post {
                            tvStats.text = "⚡ FPS: $fps | Gecikme: ~15ms"
                        }
                    },
                    onError = { e ->
                        mainHandler.post {
                            tvStatus.text = "❌ Bağlantı koptu: ${e.message}"
                            disconnect()
                        }
                    }
                )
                this.videoDecoder = decoder
                this.isConnected = true

                decoder.start(inputStream)

            } catch (e: Exception) {
                mainHandler.post {
                    tvStatus.text = "❌ Bağlantı hatası: ${e.localizedMessage}"
                    disconnect()
                }
            }
        }.start()
    }

    private fun disconnect() {
        isConnected = false
        mainHandler.removeCallbacks(autoHideRunnable)

        try {
            touchSender?.stop()
            touchSender = null
            videoDecoder?.stop()
            videoDecoder = null
            socket?.close()
            socket = null
        } catch (ignored: Exception) {}

        bonjourDiscovery?.stopDiscovery()

        mainHandler.post {
            tvStatus.text = getString(R.string.status_ready)
            tvStats.visibility = View.GONE
            layoutConnectedActions.visibility = View.GONE
            layoutTrackpadButtons.visibility = View.GONE
            btnFloatingDrag.visibility = View.GONE
            tvDragIndicator.visibility = View.GONE
            showHud()
        }
    }

    private fun hideHud() {
        hudContainer.visibility = View.GONE
        layoutFloatingPills.visibility = View.VISIBLE
        if (isTrackpadMode && isConnected) {
            btnFloatingDrag.visibility = View.VISIBLE
            layoutTrackpadButtons.visibility = View.VISIBLE
        } else {
            btnFloatingDrag.visibility = View.GONE
            layoutTrackpadButtons.visibility = View.GONE
        }
    }

    private fun showHud() {
        hudContainer.visibility = View.VISIBLE
        layoutFloatingPills.visibility = View.GONE
        layoutTrackpadButtons.visibility = View.GONE
        mainHandler.removeCallbacks(autoHideRunnable)
    }

    private fun scheduleAutoHideHud() {
        mainHandler.removeCallbacks(autoHideRunnable)
        mainHandler.postDelayed(autoHideRunnable, 3500)
    }

    private fun applyFullscreen() {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyFullscreen()
    }

    // MARK: - SurfaceHolder.Callback
    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        if (!isConnected) {
            mainHandler.postDelayed({
                if (!isConnected && surfaceReady) {
                    connectToServer("127.0.0.1", 8888, "USB (Otomatik)")
                }
            }, 600)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        disconnect()
    }

    override fun onDestroy() {
        super.onDestroy()
        disconnect()
    }
}
