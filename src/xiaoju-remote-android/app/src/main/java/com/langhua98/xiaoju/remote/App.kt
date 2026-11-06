package com.langhua98.xiaoju.remote

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "小橘遥控", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "被远程使用时显示" }
        )
    }

    companion object {
        const val CHANNEL = "xiaoju-remote"
    }
}
