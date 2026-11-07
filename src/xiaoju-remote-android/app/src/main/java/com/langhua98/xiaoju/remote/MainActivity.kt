package com.langhua98.xiaoju.remote

import android.Manifest
import android.annotation.TargetApi
import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView

/** 设置界面：云盘地址、令牌、设备名、配对口令、授权、待命开关、记录。只用系统自带控件，4.2 也能跑。 */
class MainActivity : Activity() {

    private lateinit var base: EditText
    private lateinit var token: EditText
    private lateinit var device: EditText
    private lateinit var pair: EditText
    private lateinit var toggle: Button
    private lateinit var status: TextView
    private lateinit var log: TextView
    private lateinit var prefs: Prefs

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        base = findViewById(R.id.base)
        token = findViewById(R.id.token)
        device = findViewById(R.id.device)
        pair = findViewById(R.id.pair)
        toggle = findViewById(R.id.toggle)
        status = findViewById(R.id.status)
        log = findViewById(R.id.log)

        base.setText(prefs.base)
        token.setText(prefs.token)
        device.setText(prefs.device)
        pair.setText(prefs.pair)

        findViewById<Button>(R.id.perms).setOnClickListener { requestPerms() }
        toggle.setOnClickListener { onToggle() }

        Bus.onLog = { lines -> log.text = lines.takeLast(80).joinToString("\n"); refresh() }
        log.text = Bus.snapshot().takeLast(80).joinToString("\n")
        refresh()
    }

    override fun onResume() { super.onResume(); refresh() }
    override fun onDestroy() { Bus.onLog = null; super.onDestroy() }

    private fun save() {
        prefs.base = base.text.toString()
        prefs.token = token.text.toString()
        prefs.device = device.text.toString()
        prefs.pair = pair.text.toString()
    }

    private fun refresh() {
        status.text = if (Bus.running) "● 待命中（设备名：${prefs.device}）" else "○ 未运行"
        toggle.text = if (Bus.running) "停止待命" else "开始待命"
    }

    private fun onToggle() {
        save()
        if (Bus.running) { RemoteService.stop(this); toggle.postDelayed({ refresh() }, 400); return }
        if (prefs.token.isBlank()) { Bus.push("先填云盘令牌"); return }
        toggle.isEnabled = false
        Bus.push("连接云盘…")
        // 先测一下能不能连上，再启动服务
        Thread {
            val err = try { Net.init(this); Cloud(prefs.base, prefs.token).me(); null } catch (e: Exception) { e.message ?: e.javaClass.simpleName }
            runOnUiThread {
                toggle.isEnabled = true
                if (err == null) { RemoteService.start(this); toggle.postDelayed({ refresh() }, 400) }
                else Bus.push("连不上，没启动：$err")
            }
        }.start()
    }

    private fun requestPerms() {
        if (Build.VERSION.SDK_INT < 23) { Bus.push("这个系统版本装 App 时就授权了，不用再点"); return }
        PermsApi23.request(this)
    }
}

@TargetApi(23)
private object PermsApi23 {
    fun request(a: Activity) {
        val perms = mutableListOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) perms.add("android.permission.POST_NOTIFICATIONS")
        a.requestPermissions(perms.toTypedArray(), 1)
    }
}
