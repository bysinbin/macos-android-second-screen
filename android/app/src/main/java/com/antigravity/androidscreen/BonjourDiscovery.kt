package com.antigravity.androidscreen

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

data class DiscoveredService(
    val name: String,
    val host: String,
    val port: Int,
    val isTouchBar: Boolean
)

class BonjourDiscovery(
    private val context: Context,
    private val onServerFound: (service: DiscoveredService) -> Unit
) {
    private val TAG = "BonjourDiscovery"
    private var nsdManager: NsdManager? = null
    private var screenListener: NsdManager.DiscoveryListener? = null
    private var touchbarListener: NsdManager.DiscoveryListener? = null
    private var isDiscovering = false

    fun startDiscovery() {
        if (isDiscovering) return
        nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager

        screenListener = createListener(isTouchBar = false)
        touchbarListener = createListener(isTouchBar = true)

        try {
            nsdManager?.discoverServices("_androidscreen._tcp.", NsdManager.PROTOCOL_DNS_SD, screenListener)
            nsdManager?.discoverServices("_androidtouchbar._tcp.", NsdManager.PROTOCOL_DNS_SD, touchbarListener)
            isDiscovering = true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery", e)
        }
    }

    private fun createListener(isTouchBar: Boolean): NsdManager.DiscoveryListener {
        return object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.e(TAG, "Discovery start failed for $serviceType: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.e(TAG, "Discovery stop failed: $errorCode")
            }

            override fun onDiscoveryStarted(serviceType: String?) {
                Log.i(TAG, "Discovery started for: $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String?) {
                Log.i(TAG, "Discovery stopped for: $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                Log.i(TAG, "Service found: ${serviceInfo?.serviceName}")
                nsdManager?.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                        Log.e(TAG, "Resolve failed: $errorCode")
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                        val host = serviceInfo?.host?.hostAddress
                        val port = serviceInfo?.port ?: (if (isTouchBar) 8889 else 8888)
                        val name = serviceInfo?.serviceName ?: (if (isTouchBar) "Mac Touch Bar" else "Mac Ekran")
                        if (host != null) {
                            Log.i(TAG, "Resolved server: $name at $host:$port")
                            val service = DiscoveredService(
                                name = name,
                                host = host,
                                port = port,
                                isTouchBar = isTouchBar || port == 8889
                            )
                            onServerFound(service)
                        }
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                Log.w(TAG, "Service lost: ${serviceInfo?.serviceName}")
            }
        }
    }

    fun stopDiscovery() {
        if (!isDiscovering) return
        try {
            screenListener?.let { nsdManager?.stopServiceDiscovery(it) }
            touchbarListener?.let { nsdManager?.stopServiceDiscovery(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping discovery", e)
        }
        isDiscovering = false
        screenListener = null
        touchbarListener = null
    }
}
