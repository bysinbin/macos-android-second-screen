package com.antigravity.androidscreen

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.net.InetSocketAddress
import java.net.Socket

class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val TAG = "MainActivity"

    enum class AppMode {
        SCREEN,                 // 1. Sadece 2. Ekran
        TOUCHBAR,               // 2. Sadece Touch Bar
        TOUCHPAD,               // 3. Sadece Touchpad (Tam ekran)
        SPLIT_TOUCHBAR_SCREEN,  // 4. 2. Ekran (Üstte) + Touch Bar (Altta)
        SPLIT_TOUCHBAR_TOUCHPAD // 5. Touch Bar (Üstte) + Touchpad (Altta)
    }
    private var currentAppMode = AppMode.SCREEN

    // Containers
    private lateinit var containerPrimary: FrameLayout
    private lateinit var containerSecondary: FrameLayout
    private lateinit var viewSplitDivider: View

    // Surfaces
    private lateinit var surfaceView: SurfaceView
    private lateinit var surfaceViewSecondary: SurfaceView
    private lateinit var includeTouchpadPrimary: View
    private lateinit var includeTouchpadSecondary: View

    // HUD & Controls
    private lateinit var hudContainer: LinearLayout
    private lateinit var btnShowHud: TextView
    private lateinit var tvStatus: TextView
    private lateinit var tvStats: TextView
    private lateinit var layoutDiscoveredServers: LinearLayout

    // Mode Buttons
    private lateinit var btnModeScreen: Button
    private lateinit var btnModeTouchBar: Button
    private lateinit var btnModeTouchpad: Button
    private lateinit var btnModeSplitScreen: Button
    private lateinit var btnModeSplitTouchpad: Button

    // Action Buttons
    private lateinit var btnUsb: Button
    private lateinit var btnWifiDiscover: Button
    private lateinit var etManualIp: EditText
    private lateinit var btnConnectManual: Button
    private lateinit var btnRotate: Button
    private lateinit var btnHideHud: Button
    private lateinit var btnDisconnect: Button
    private lateinit var layoutConnectedActions: LinearLayout

    // Floating Indicators
    private lateinit var btnToggleMode: Button
    private lateinit var btnFloatingMode: TextView
    private lateinit var btnFloatingDrag: TextView
    private lateinit var tvDragIndicator: TextView
    private lateinit var layoutFloatingPills: LinearLayout

    // Trackpad Floating Buttons (Screen Mode)
    private lateinit var layoutTrackpadButtons: LinearLayout
    private lateinit var btnTrackpadLeft: Button
    private lateinit var btnTrackpadDragLock: Button
    private lateinit var btnTrackpadRight: Button

    // Touchpad Speed Control
    private lateinit var layoutTouchpadSpeed: LinearLayout
    private lateinit var tvTouchpadSpeedVal: TextView
    private lateinit var sbTouchpadSpeed: SeekBar
    private var touchpadSpeed: Float = 1.0f

    private var isTrackpadMode = false

    // Primary Connection
    private var socket: Socket? = null
    private var videoDecoder: VideoDecoder? = null
    private var touchSender: TouchSender? = null

    // Secondary Connection (for Dual / Split Mode)
    private var socketSecondary: Socket? = null
    private var videoDecoderSecondary: VideoDecoder? = null
    private var touchSenderSecondary: TouchSender? = null

    private var bonjourDiscovery: BonjourDiscovery? = null
    private var isConnected = false
    private var surfaceReady = false
    private var secondarySurfaceReady = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private val autoHideRunnable = Runnable { hideHud() }

    private val prefs by lazy { getSharedPreferences("mac_screen_prefs", Context.MODE_PRIVATE) }
    private var lastConnectedHost: String = "127.0.0.1"

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
        containerPrimary = findViewById(R.id.container_primary)
        containerSecondary = findViewById(R.id.container_secondary)
        viewSplitDivider = findViewById(R.id.view_split_divider)

        surfaceView = findViewById(R.id.surface_view)
        surfaceViewSecondary = findViewById(R.id.surface_view_secondary)
        includeTouchpadPrimary = findViewById(R.id.include_touchpad_primary)
        includeTouchpadSecondary = findViewById(R.id.include_touchpad_secondary)

        hudContainer = findViewById(R.id.hud_container)
        btnShowHud = findViewById(R.id.btn_show_hud)
        tvStatus = findViewById(R.id.tv_status)
        tvStats = findViewById(R.id.tv_stats)
        layoutDiscoveredServers = findViewById(R.id.layout_discovered_servers)

        btnModeScreen = findViewById(R.id.btn_mode_screen)
        btnModeTouchBar = findViewById(R.id.btn_mode_touchbar)
        btnModeTouchpad = findViewById(R.id.btn_mode_touchpad)
        btnModeSplitScreen = findViewById(R.id.btn_mode_split_screen)
        btnModeSplitTouchpad = findViewById(R.id.btn_mode_split_touchpad)

        btnUsb = findViewById(R.id.btn_usb)
        btnWifiDiscover = findViewById(R.id.btn_wifi_discover)
        etManualIp = findViewById(R.id.et_manual_ip)
        btnConnectManual = findViewById(R.id.btn_connect_manual)
        btnRotate = findViewById(R.id.btn_rotate)
        btnHideHud = findViewById(R.id.btn_hide_hud)
        btnDisconnect = findViewById(R.id.btn_disconnect)
        layoutConnectedActions = findViewById(R.id.layout_connected_actions)

        val savedIp = prefs.getString("last_ip", "")
        if (!savedIp.isNullOrEmpty()) {
            etManualIp.setText(savedIp)
        }

        btnToggleMode = findViewById(R.id.btn_toggle_mode)
        btnFloatingMode = findViewById(R.id.btn_floating_mode)
        btnFloatingDrag = findViewById(R.id.btn_floating_drag)
        tvDragIndicator = findViewById(R.id.tv_drag_indicator)
        layoutFloatingPills = findViewById(R.id.layout_floating_pills)

        layoutTrackpadButtons = findViewById(R.id.layout_trackpad_buttons)
        btnTrackpadLeft = findViewById(R.id.btn_trackpad_left)
        btnTrackpadDragLock = findViewById(R.id.btn_trackpad_drag_lock)
        btnTrackpadRight = findViewById(R.id.btn_trackpad_right)

        layoutTouchpadSpeed = findViewById(R.id.layout_touchpad_speed)
        tvTouchpadSpeedVal = findViewById(R.id.tv_touchpad_speed_val)
        sbTouchpadSpeed = findViewById(R.id.sb_touchpad_speed)

        touchpadSpeed = prefs.getFloat("touchpad_speed", 1.0f)
        val initialProgress = (touchpadSpeed * 100).toInt().coerceIn(50, 250)
        sbTouchpadSpeed.progress = initialProgress
        tvTouchpadSpeedVal.text = "$initialProgress%"

        surfaceView.holder.addCallback(this)
        surfaceViewSecondary.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                secondarySurfaceReady = true
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                secondarySurfaceReady = false
            }
        })
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupListeners() {
        btnModeScreen.setOnClickListener { switchAppMode(AppMode.SCREEN) }
        btnModeTouchBar.setOnClickListener { switchAppMode(AppMode.TOUCHBAR) }
        btnModeTouchpad.setOnClickListener { switchAppMode(AppMode.TOUCHPAD) }
        btnModeSplitScreen.setOnClickListener { switchAppMode(AppMode.SPLIT_TOUCHBAR_SCREEN) }
        btnModeSplitTouchpad.setOnClickListener { switchAppMode(AppMode.SPLIT_TOUCHBAR_TOUCHPAD) }

        val toggleModeAction = {
            if (currentAppMode == AppMode.SCREEN) {
                isTrackpadMode = !isTrackpadMode
                touchSender?.isTrackpadMode = isTrackpadMode
                updateModeUI()
                val msg = if (isTrackpadMode) "🖱️ Mouse (Trackpad) Moduna geçildi" else "📱 Dokunmatik (Touch) Moduna geçildi"
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
            }
        }

        btnToggleMode.setOnClickListener { toggleModeAction() }
        btnFloatingMode.setOnClickListener {
            if (currentAppMode == AppMode.SCREEN) {
                toggleModeAction()
            } else {
                showHud()
            }
        }

        btnFloatingDrag.setOnClickListener {
            touchSender?.let { sender ->
                val newState = !sender.isDragLockActive
                sender.setDragLock(newState)
                updateDragLockUI(newState)
                it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
        }

        btnTrackpadLeft.setOnClickListener {
            vibrateTap(it)
            touchSender?.sendMouseDown()
            mainHandler.postDelayed({ touchSender?.sendMouseUp() }, 50)
        }

        btnTrackpadRight.setOnClickListener {
            vibrateTap(it)
            touchSender?.sendRightClick()
        }

        btnTrackpadDragLock.setOnClickListener {
            touchSender?.let { sender ->
                val newState = !sender.isDragLockActive
                sender.setDragLock(newState)
                updateDragLockUI(newState)
                vibrateTap(it)
            }
        }

        // Dedicated Touchpad Layout Buttons
        setupTouchpadLayout(includeTouchpadPrimary)
        setupTouchpadLayout(includeTouchpadSecondary)

        sbTouchpadSpeed.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser) {
                    touchpadSpeed = progress / 100f
                    tvTouchpadSpeedVal.text = "$progress%"
                    applyTouchpadSpeed()
                    prefs.edit().putFloat("touchpad_speed", touchpadSpeed).apply()
                }
            }
            override fun onStartTrackingTouch(seekBar: SeekBar?) {}
            override fun onStopTrackingTouch(seekBar: SeekBar?) {}
        })

        btnUsb.setOnClickListener {
            connectUsbAuto()
        }

        btnWifiDiscover.setOnClickListener {
            startWifiDiscovery()
        }

        btnConnectManual.setOnClickListener {
            val input = etManualIp.text.toString().trim()
            if (input.isEmpty()) {
                Toast.makeText(this, "Lütfen IP adresi girin", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val parts = input.split(":")
            val host = parts[0]
            val defaultPort = if (currentAppMode == AppMode.SCREEN) 8888 else 8889
            val port = if (parts.size > 1) parts[1].toIntOrNull() ?: defaultPort else defaultPort
            connectWithMode(host, port, "Wi-Fi")
        }

        btnRotate.setOnClickListener {
            requestedOrientation = if (requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE) {
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
        }

        btnHideHud.setOnClickListener { hideHud() }
        btnShowHud.setOnClickListener { showHud() }
        btnDisconnect.setOnClickListener { disconnect() }

        // Primary Surface Touch
        surfaceView.setOnTouchListener { v, event ->
            if (isConnected) {
                if ((currentAppMode == AppMode.TOUCHBAR || currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) && event.actionMasked == MotionEvent.ACTION_DOWN) {
                    v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                }
                touchSender?.handleTouchEvent(v, event) ?: false
            } else {
                false
            }
        }

        // Secondary Surface Touch (for Touch Bar in Split Screen)
        surfaceViewSecondary.setOnTouchListener { v, event ->
            if (isConnected) {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                }
                touchSenderSecondary?.handleTouchEvent(v, event) ?: false
            } else {
                false
            }
        }
    }

    private fun setupTouchpadLayout(view: View) {
        val btnLeft = view.findViewById<Button>(R.id.btn_trackpad_left)
        val btnRight = view.findViewById<Button>(R.id.btn_trackpad_right)

        btnLeft?.setOnClickListener {
            vibrateTap(it)
            val sender = if (currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) (touchSenderSecondary ?: touchSender) else touchSender
            sender?.sendClick()
        }

        btnRight?.setOnClickListener {
            vibrateTap(it)
            val sender = if (currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) (touchSenderSecondary ?: touchSender) else touchSender
            sender?.sendRightClick()
        }

        view.setOnTouchListener { v, event ->
            val sender = if (currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) (touchSenderSecondary ?: touchSender) else touchSender
            sender?.handleTouchEvent(v, event) ?: false
        }
    }

    private fun switchAppMode(mode: AppMode) {
        if (currentAppMode == mode) return
        val wasConnected = isConnected
        if (wasConnected) {
            disconnect()
        }
        currentAppMode = mode
        updateModeUI()

        if (wasConnected) {
            mainHandler.postDelayed({
                connectWithMode(lastConnectedHost, null, if (lastConnectedHost == "127.0.0.1") "USB" else "Wi-Fi")
            }, 300)
        }
    }

    private fun updateModeUI() {
        val activeBg = R.drawable.btn_cyan
        val inactiveBg = R.drawable.btn_outline
        val activeText = 0xFF000000.toInt()
        val inactiveText = resources.getColor(R.color.accent_cyan, theme)

        btnModeScreen.setBackgroundResource(if (currentAppMode == AppMode.SCREEN) activeBg else inactiveBg)
        btnModeScreen.setTextColor(if (currentAppMode == AppMode.SCREEN) activeText else inactiveText)

        btnModeTouchBar.setBackgroundResource(if (currentAppMode == AppMode.TOUCHBAR) activeBg else inactiveBg)
        btnModeTouchBar.setTextColor(if (currentAppMode == AppMode.TOUCHBAR) activeText else inactiveText)

        btnModeTouchpad.setBackgroundResource(if (currentAppMode == AppMode.TOUCHPAD) activeBg else inactiveBg)
        btnModeTouchpad.setTextColor(if (currentAppMode == AppMode.TOUCHPAD) activeText else inactiveText)

        btnModeSplitScreen.setBackgroundResource(if (currentAppMode == AppMode.SPLIT_TOUCHBAR_SCREEN) activeBg else inactiveBg)
        btnModeSplitScreen.setTextColor(if (currentAppMode == AppMode.SPLIT_TOUCHBAR_SCREEN) activeText else inactiveText)

        btnModeSplitTouchpad.setBackgroundResource(if (currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) activeBg else inactiveBg)
        btnModeSplitTouchpad.setTextColor(if (currentAppMode == AppMode.SPLIT_TOUCHBAR_TOUCHPAD) activeText else inactiveText)

        val paramPrimary = containerPrimary.layoutParams as LinearLayout.LayoutParams
        val paramSecondary = containerSecondary.layoutParams as LinearLayout.LayoutParams
        val barHeightPx = (110 * resources.displayMetrics.density).toInt()

        // Sizing & Visibility of Surface / Touchpad areas
        when (currentAppMode) {
            AppMode.SCREEN, AppMode.TOUCHBAR -> {
                paramPrimary.height = 0
                paramPrimary.weight = 1f
                paramSecondary.height = 0
                paramSecondary.weight = 0f

                surfaceView.visibility = View.VISIBLE
                includeTouchpadPrimary.visibility = View.GONE
                containerSecondary.visibility = View.GONE
                viewSplitDivider.visibility = View.GONE
            }
            AppMode.TOUCHPAD -> {
                paramPrimary.height = 0
                paramPrimary.weight = 1f
                paramSecondary.height = 0
                paramSecondary.weight = 0f

                surfaceView.visibility = View.GONE
                includeTouchpadPrimary.visibility = View.VISIBLE
                containerSecondary.visibility = View.GONE
                viewSplitDivider.visibility = View.GONE
            }
            AppMode.SPLIT_TOUCHBAR_SCREEN -> {
                paramPrimary.height = 0
                paramPrimary.weight = 1f
                paramSecondary.height = barHeightPx
                paramSecondary.weight = 0f

                surfaceView.visibility = View.VISIBLE
                includeTouchpadPrimary.visibility = View.GONE
                containerSecondary.visibility = View.VISIBLE
                viewSplitDivider.visibility = View.VISIBLE
                surfaceViewSecondary.visibility = View.VISIBLE
                includeTouchpadSecondary.visibility = View.GONE
            }
            AppMode.SPLIT_TOUCHBAR_TOUCHPAD -> {
                paramPrimary.height = barHeightPx
                paramPrimary.weight = 0f
                paramSecondary.height = 0
                paramSecondary.weight = 1f

                surfaceView.visibility = View.VISIBLE
                includeTouchpadPrimary.visibility = View.GONE
                containerSecondary.visibility = View.VISIBLE
                viewSplitDivider.visibility = View.VISIBLE
                surfaceViewSecondary.visibility = View.GONE
                includeTouchpadSecondary.visibility = View.VISIBLE
            }
        }
        containerPrimary.layoutParams = paramPrimary
        containerSecondary.layoutParams = paramSecondary

        if (currentAppMode == AppMode.TOUCHBAR) {
            val h = (120 * resources.displayMetrics.density).toInt()
            surfaceView.layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, h, android.view.Gravity.CENTER)
        } else {
            surfaceView.layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        }

        // Submode button visibility
        if (currentAppMode == AppMode.SCREEN) {
            btnToggleMode.visibility = View.VISIBLE
            btnFloatingMode.text = if (isTrackpadMode) "🖱️ Mouse" else "📱 Touch"
            btnFloatingDrag.visibility = if (isTrackpadMode) View.VISIBLE else View.GONE
        } else {
            btnToggleMode.visibility = View.GONE
            btnFloatingMode.text = when (currentAppMode) {
                AppMode.TOUCHBAR -> "🪄 TouchBar"
                AppMode.TOUCHPAD -> "🖱️ Touchpad"
                AppMode.SPLIT_TOUCHBAR_SCREEN -> "📱 Çift Ekran"
                AppMode.SPLIT_TOUCHBAR_TOUCHPAD -> "📱 Bar+Pad"
                else -> "📱 Mod"
            }
            btnFloatingDrag.visibility = View.GONE
            layoutTrackpadButtons.visibility = View.GONE
            tvDragIndicator.visibility = View.GONE
        }
    }

    private fun applyTouchpadSpeed() {
        touchSender?.pointerSpeed = touchpadSpeed
        touchSenderSecondary?.pointerSpeed = touchpadSpeed
    }

    private fun connectWithMode(host: String, port: Int? = null, label: String) {
        lastConnectedHost = host
        if (host != "127.0.0.1" && host != "localhost") {
            prefs.edit().putString("last_ip", host).apply()
        }

        when (currentAppMode) {
            AppMode.SCREEN -> {
                val p = port ?: 8888
                connectToServer(host, p, "$label 2. Ekran")
            }
            AppMode.TOUCHBAR -> {
                val p = port ?: 8889
                connectToServer(host, p, "$label Touch Bar")
            }
            AppMode.TOUCHPAD -> {
                val p = port ?: 8889
                connectTouchpadOnly(host, p, "$label Touchpad")
            }
            AppMode.SPLIT_TOUCHBAR_SCREEN -> {
                connectSplitMode(host, 8888, 8889, "$label Ekran + Touch Bar")
            }
            AppMode.SPLIT_TOUCHBAR_TOUCHPAD -> {
                val p = port ?: 8889
                connectTouchBarWithTouchpad(host, p, "$label Touch Bar + Touchpad")
            }
        }
    }

    private fun connectUsbAuto() {
        connectWithMode("127.0.0.1", null, "USB")
    }

    private fun startWifiDiscovery() {
        btnWifiDiscover.isEnabled = false
        tvStatus.text = "🔍 Mac yayınları aranıyor..."
        layoutDiscoveredServers.removeAllViews()
        layoutDiscoveredServers.visibility = View.VISIBLE

        bonjourDiscovery?.stopDiscovery()
        bonjourDiscovery = BonjourDiscovery(this) { service ->
            mainHandler.post {
                if (etManualIp.text.isNullOrEmpty()) {
                    etManualIp.setText(service.host)
                }
                addDiscoveredServerUI(service)
            }
        }
        bonjourDiscovery?.startDiscovery()

        mainHandler.postDelayed({
            btnWifiDiscover.isEnabled = true
        }, 8000)
    }

    private fun addDiscoveredServerUI(service: DiscoveredService) {
        val existing = layoutDiscoveredServers.findViewWithTag<View>("${service.host}:${service.port}")
        if (existing != null) return

        val btn = Button(this).apply {
            tag = "${service.host}:${service.port}"
            val icon = if (service.isTouchBar) "🪄" else "🖥️"
            text = "$icon ${service.name} (${service.host}:${service.port})"
            setBackgroundResource(R.drawable.btn_outline)
            setTextColor(resources.getColor(R.color.accent_cyan, theme))
            textSize = 12f
            isAllCaps = false
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = 6
            }
            setOnClickListener {
                if (currentAppMode == AppMode.SCREEN && service.isTouchBar) {
                    currentAppMode = AppMode.TOUCHBAR
                    updateModeUI()
                }
                connectWithMode(service.host, service.port, service.name)
            }
        }
        layoutDiscoveredServers.addView(btn)
    }

    // Connect Single Video + Touch Stream
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

                val sender = TouchSender(newSocket.getOutputStream())
                sender.isTrackpadMode = if (currentAppMode == AppMode.TOUCHBAR) false else isTrackpadMode
                sender.pointerSpeed = touchpadSpeed
                sender.onGestureTriggered = { msg -> mainHandler.post { Toast.makeText(this@MainActivity, msg, Toast.LENGTH_SHORT).show() } }
                this.touchSender = sender

                val decoder = VideoDecoder(
                    surface = surfaceView.holder.surface,
                    onStreamReady = { w, h, fps ->
                        mainHandler.post {
                            if (currentAppMode == AppMode.TOUCHBAR || w > h) {
                                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                            } else {
                                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            }
                            tvStatus.text = "$modeLabel: ${w}x${h} @ ${fps}fps"
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
                decoder.start(newSocket.getInputStream())

            } catch (e: Exception) {
                mainHandler.post {
                    tvStatus.text = "❌ Bağlantı hatası: ${e.localizedMessage}"
                    disconnect()
                }
            }
        }.start()
    }

    // Connect Pure Touchpad Mode (Zero Video overhead)
    private fun connectTouchpadOnly(host: String, port: Int = 8889, label: String = "Touchpad") {
        disconnect()
        tvStatus.text = "⏳ $label bağlanıyor..."

        Thread {
            try {
                var targetPort = port
                var newSocket = Socket()
                newSocket.tcpNoDelay = true
                try {
                    newSocket.connect(InetSocketAddress(host, targetPort), 3000)
                } catch (e: Exception) {
                    targetPort = if (port == 8889) 8888 else 8889
                    newSocket = Socket()
                    newSocket.tcpNoDelay = true
                    newSocket.connect(InetSocketAddress(host, targetPort), 3000)
                }
                this.socket = newSocket

                val sender = TouchSender(newSocket.getOutputStream())
                sender.isTrackpadMode = true
                sender.pointerSpeed = touchpadSpeed
                sender.onGestureTriggered = { msg -> mainHandler.post { Toast.makeText(this@MainActivity, msg, Toast.LENGTH_SHORT).show() } }
                sender.onConnectionLost = {
                    mainHandler.post {
                        if (isConnected) {
                            tvStatus.text = "❌ Bağlantı koptu"
                            disconnect()
                        }
                    }
                }
                this.touchSender = sender
                this.isConnected = true

                // Drain incoming video/handshake packets so TCP buffer never backs up
                Thread {
                    val buf = ByteArray(65536)
                    try {
                        val input = newSocket.getInputStream()
                        while (isConnected && input.read(buf) != -1) {
                            // discard
                        }
                    } catch (ignored: Exception) {}
                    if (isConnected) {
                        mainHandler.post {
                            tvStatus.text = "❌ Bağlantı kapandı"
                            disconnect()
                        }
                    }
                }.start()

                mainHandler.post {
                    tvStatus.text = "🖱️ $label Bağlandı (Port $targetPort)"
                    layoutConnectedActions.visibility = View.VISIBLE
                    hideHud()
                    Toast.makeText(this@MainActivity, "🖱️ $label Bağlandı", Toast.LENGTH_SHORT).show()
                }
            } catch (e: Exception) {
                mainHandler.post {
                    tvStatus.text = "❌ Bağlantı hatası: ${e.localizedMessage}"
                    disconnect()
                }
            }
        }.start()
    }

    // Connect Dual / Split Mode: Screen (Top) + TouchBar (Bottom)
    private fun connectSplitMode(host: String, screenPort: Int, touchBarPort: Int, label: String) {
        disconnect()
        tvStatus.text = "⏳ $label bağlanıyor..."

        Thread {
            try {
                // 1. Primary: Screen
                val s1 = Socket()
                s1.tcpNoDelay = true
                s1.connect(InetSocketAddress(host, screenPort), 5000)
                this.socket = s1

                val sender1 = TouchSender(s1.getOutputStream())
                sender1.isTrackpadMode = isTrackpadMode
                sender1.pointerSpeed = touchpadSpeed
                sender1.onGestureTriggered = { msg -> mainHandler.post { Toast.makeText(this@MainActivity, msg, Toast.LENGTH_SHORT).show() } }
                this.touchSender = sender1

                val decoder1 = VideoDecoder(
                    surface = surfaceView.holder.surface,
                    onStreamReady = { w, h, fps ->
                        mainHandler.post {
                            tvStatus.text = "📱 2. Ekran + Touch Bar Aktif"
                            layoutConnectedActions.visibility = View.VISIBLE
                            scheduleAutoHideHud()
                        }
                    },
                    onFpsUpdate = { fps ->
                        mainHandler.post { tvStats.text = "⚡ FPS: $fps" }
                    },
                    onError = { disconnect() }
                )
                this.videoDecoder = decoder1
                decoder1.start(s1.getInputStream())

                // 2. Secondary: Touch Bar
                val s2 = Socket()
                s2.tcpNoDelay = true
                s2.connect(InetSocketAddress(host, touchBarPort), 5000)
                this.socketSecondary = s2

                val sender2 = TouchSender(s2.getOutputStream())
                sender2.isTrackpadMode = false
                sender2.onGestureTriggered = { msg -> mainHandler.post { Toast.makeText(this@MainActivity, msg, Toast.LENGTH_SHORT).show() } }
                this.touchSenderSecondary = sender2

                val decoder2 = VideoDecoder(
                    surface = surfaceViewSecondary.holder.surface,
                    onStreamReady = { _, _, _ -> },
                    onFpsUpdate = {},
                    onError = { disconnect() }
                )
                this.videoDecoderSecondary = decoder2
                decoder2.start(s2.getInputStream())

                this.isConnected = true
            } catch (e: Exception) {
                mainHandler.post {
                    tvStatus.text = "❌ Bağlantı hatası: ${e.localizedMessage}"
                    disconnect()
                }
            }
        }.start()
    }

    // Connect Dual Mode: Touch Bar (Top) + Touchpad (Bottom)
    private fun connectTouchBarWithTouchpad(host: String, touchBarPort: Int = 8889, label: String = "Touch Bar + Touchpad") {
        disconnect()
        tvStatus.text = "⏳ $label bağlanıyor..."

        Thread {
            try {
                val s1 = Socket()
                s1.tcpNoDelay = true
                s1.connect(InetSocketAddress(host, touchBarPort), 5000)
                this.socket = s1

                // 1. Touch Bar Sender (Primary Surface = Direct Touch on Touch Bar)
                val senderBar = TouchSender(s1.getOutputStream())
                senderBar.isTrackpadMode = false
                this.touchSender = senderBar

                // 2. Touchpad Sender (Secondary Surface = Relative Trackpad + Clicks + Gestures)
                val senderPad = TouchSender(s1.getOutputStream())
                senderPad.isTrackpadMode = true
                senderPad.pointerSpeed = touchpadSpeed
                senderPad.onGestureTriggered = { msg -> mainHandler.post { Toast.makeText(this@MainActivity, msg, Toast.LENGTH_SHORT).show() } }
                this.touchSenderSecondary = senderPad

                val decoder1 = VideoDecoder(
                    surface = surfaceView.holder.surface,
                    onStreamReady = { _, _, _ ->
                        mainHandler.post {
                            tvStatus.text = "📱 Touch Bar + Touchpad Aktif"
                            layoutConnectedActions.visibility = View.VISIBLE
                            scheduleAutoHideHud()
                        }
                    },
                    onFpsUpdate = { fps ->
                        mainHandler.post { tvStats.text = "⚡ FPS: $fps" }
                    },
                    onError = { disconnect() }
                )
                this.videoDecoder = decoder1
                decoder1.start(s1.getInputStream())

                this.isConnected = true
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

            touchSenderSecondary?.stop()
            touchSenderSecondary = null
            videoDecoderSecondary?.stop()
            videoDecoderSecondary = null
            socketSecondary?.close()
            socketSecondary = null
        } catch (ignored: Exception) {}

        bonjourDiscovery?.stopDiscovery()

        mainHandler.post {
            tvStatus.text = getString(R.string.status_ready)
            tvStats.visibility = View.GONE
            layoutConnectedActions.visibility = View.GONE
            layoutTrackpadButtons.visibility = View.GONE
            layoutFloatingPills.visibility = View.GONE
            showHud()
        }
    }

    private fun scheduleAutoHideHud() {
        mainHandler.removeCallbacks(autoHideRunnable)
        mainHandler.postDelayed(autoHideRunnable, 2500)
    }

    private fun hideHud() {
        hudContainer.visibility = View.GONE
        findViewById<View>(R.id.hud_scroll_wrapper)?.visibility = View.GONE
        if (isConnected) {
            layoutFloatingPills.visibility = View.VISIBLE
        }
    }

    private fun showHud() {
        findViewById<View>(R.id.hud_scroll_wrapper)?.visibility = View.VISIBLE
        hudContainer.visibility = View.VISIBLE
        layoutFloatingPills.visibility = View.GONE
    }

    private fun updateDragLockUI(isActive: Boolean) {
        btnTrackpadDragLock.text = if (isActive) "🔓 Çöz" else "🔒 Seçim"
        btnTrackpadDragLock.setTextColor(
            if (isActive) resources.getColor(R.color.accent_green, theme)
            else resources.getColor(R.color.accent_cyan, theme)
        )
    }

    private fun vibrateTap(view: View) {
        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
    }

    private fun applyFullscreen() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_FULLSCREEN
                )
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
    }

    override fun onDestroy() {
        super.onDestroy()
        disconnect()
    }
}
