package com.abelgeorgeantony.floorpaper

import android.app.WallpaperManager
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.graphics.Rect
import android.os.Build
import android.util.DisplayMetrics

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val channelName = "floorpaper/wallpaper"
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

        // Real display size, including the area behind the status/nav bars.
    private fun realScreenSize(): Pair<Int, Int> {
        val width: Int
        val height: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.maximumWindowMetrics.bounds
            width = bounds.width()
            height = bounds.height()
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(metrics)
            width = metrics.widthPixels
            height = metrics.heightPixels
        }
        // Wallpapers are portrait, even if the app is open in landscape.
        return if (width > height) Pair(height, width) else Pair(width, height)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWallpaperInfo" -> {
                    try {
                        val (screenW, screenH) = realScreenSize()
                        val wm = WallpaperManager.getInstance(applicationContext)
                        result.success(
                            mapOf(
                                "screenWidth" to screenW,
                                "screenHeight" to screenH,
                                "suggestedWidth" to wm.desiredMinimumWidth,
                                "suggestedHeight" to wm.desiredMinimumHeight
                            )
                        )
                    } catch (e: Exception) {
                        result.error("WALLPAPER_INFO_ERROR", e.message, null)
                    }
                }

                "setWallpaperFromFile" -> {
                    val path = call.argument<String>("path")
                    val target = call.argument<String>("target")
                    val hintWidth = call.argument<Int>("hintWidth")
                    val hintHeight = call.argument<Int>("hintHeight")

                    if (path == null || target == null) {
                        result.error("INVALID_ARGUMENTS", "path and target are required", null)
                        return@setMethodCallHandler
                    }

                    executor.execute {
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                throw IllegalStateException("Wallpaper file does not exist")
                            }

                            // Full-quality decode (RGB_565 caused colour banding).
                            val bitmap = BitmapFactory.decodeFile(file.absolutePath)
                                ?: throw IllegalStateException("Could not decode wallpaper bitmap")

                            val wm = WallpaperManager.getInstance(applicationContext)

                            // Tells Android how wide the wallpaper is meant to be:
                            // one screen = no sideways scroll, N screens = N pages.
                            if (hintWidth != null && hintHeight != null) {
                                wm.suggestDesiredDimensions(hintWidth, hintHeight)
                            }

                            val flags = when (target) {
                                "home" -> WallpaperManager.FLAG_SYSTEM
                                "lock" -> WallpaperManager.FLAG_LOCK
                                "both" -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                                else -> {
                                    bitmap.recycle()
                                    throw IllegalArgumentException("Unknown wallpaper target")
                                }
                            }

                            // Crop hint = the whole image, so Android doesn't pick its own crop.
                            wm.setBitmap(bitmap, Rect(0, 0, bitmap.width, bitmap.height), true, flags)
                            bitmap.recycle()

                            mainHandler.post { result.success(true) }
                        } catch (e: SecurityException) {
                            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("SET_WALLPAPER_FAILED", e.message, null) }
                        }
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}