package com.langhua98.xiaoju.remote

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.langhua98.xiaoju.remote.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.lifecycleScope

class MainActivity : AppCompatActivity() {

    private lateinit var b: ActivityMainBinding
    private lateinit var prefs: Prefs

    private val askPerms = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { res ->
        val granted = res.count { it.value }
        Bus.push("授权：$granted/${res.size} 项已允许")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityMainBinding.inflate(layoutInflater)
        setContentView(b.root)
        prefs = Prefs(this)

        b.base.setText(prefs.base)
        b.token.setText(prefs.token)
        b.device.setText(prefs.device)
        b.pair.setText(prefs.pair)

        b.perms.setOnClickListener { requestPerms() }
        b.toggle.setOnClickListener { toggle() }

        Bus.onLog = { lines -> runOnUiThread { b.log.text = lines.takeLast(80).joinToString("\n") } }
        b.log.text = Bus.snapshot().takeLast(80).joinToString("\n")
        refreshStatus()
    }

    override fun onResume() { super.onResume(); refreshStatus() }
    override fun onDestroy() { Bus.onLog = null; super.onDestroy() }

    private fun save() {
        prefs.base = b.base.text.toString()
        prefs.token = b.token.text.toString()
        prefs.device = b.device.text.toString()
        prefs.pair = b.pair.text.toString()
    }

    private fun refreshStatus() {
        b.status.text = if (Bus.running) "● 待命中（设备名：${prefs.device}）" else "○ 未运行"
        b.toggle.text = if (Bus.running) "停止待命" else "开始待命"
    }

    private fun requestPerms() {
        val perms = mutableListOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
        askPerms.launch(perms.toTypedArray())
    }

    private fun toggle() {
        save()
        if (Bus.running) {
            RemoteService.stop(this)
            Bus.push("已停止")
            b.toggle.postDelayed({ refreshStatus() }, 400)
            return
        }
        if (prefs.token.isBlank()) { Bus.push("先填云盘令牌"); return }
        // 先测一下连接，再起服务
        lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching { Cloud(prefs.base, prefs.token).me() }
            }
            ok.onSuccess { Bus.push("连接成功：$it"); RemoteService.start(this@MainActivity); refreshStatus() }
                .onFailure { Bus.push("连不上，没启动：${it.message}") }
        }
    }
}
