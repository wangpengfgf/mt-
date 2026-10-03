package com.binmt.mtforum

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import com.gopeed.libgopeed.InvokeResultListener
import com.gopeed.libgopeed.Libgopeed
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 基于 Gopeed 官方内核的更新包下载器。
 *
 * 内核由 gomobile 打包为 libgopeed.aar，以内嵌方式运行在 App 进程内：
 * 既不开监听端口，也不走本地 HTTP，而是通过 Libgopeed.invokeAsync 直接调用
 * Gopeed 内部的 REST 路由来建任务/查进度，HTTP 下载由内核按多连接分段完成。
 */
internal class GopeedDownloader(context: Context) {

    private val appContext = context.applicationContext
    private var started = false

    /** 任务 id -> 落盘文件，用于下载完成后拉起安装。 */
    private val taskFiles = ConcurrentHashMap<String, File>()

    @Synchronized
    private fun ensureStarted() {
        if (started) return

        val storageDir = File(appContext.filesDir, "gopeed").apply { mkdirs() }
        // 内核默认使用 os.TempDir()，在 Android 上并不可写，必须显式指定应用缓存目录。
        val tempDir = File(appContext.cacheDir, "gopeed-tmp").apply { mkdirs() }

        val config = JSONObject()
            .put("network", "tcp")
            .put("address", "127.0.0.1:0")
            .put("apiEnable", false)
            .put("storage", "mem")
            .put("storageDir", storageDir.absolutePath)
            .put("tempDir", tempDir.absolutePath)
            .put("refreshInterval", 350)
            .toString()

        Libgopeed.start(config)
        started = true
    }

    @Synchronized
    fun shutdown() {
        if (!started) return
        started = false
        taskFiles.clear()
        Libgopeed.stop()
    }

    /** 创建下载任务，返回内核任务 id。 */
    fun start(url: String, fileName: String): String {
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") {
            throw IllegalArgumentException("软件更新下载地址仅支持 http/https：${uri.scheme ?: "无协议"}")
        }

        val dir = appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: throw IOException("无法访问应用下载目录")
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("无法创建下载目录：${dir.absolutePath}")
        }

        // 同名文件会触发内核自动重命名，先清理以保证预期的落盘路径。
        val target = File(dir, fileName)
        if (target.exists()) target.delete()

        ensureStarted()

        val body = JSONObject()
            .put("req", JSONObject().put("url", url))
            .put(
                "opts",
                JSONObject()
                    .put("name", fileName)
                    .put("path", dir.absolutePath)
                    .put("extra", JSONObject().put("connections", CONNECTIONS)),
            )
            .toString()

        val taskId = call("POST", "/api/v1/tasks", body).getString("data")
        taskFiles[taskId] = target
        return taskId
    }

    /** 查询下载进度，state 为 running/done/error。 */
    fun query(taskId: String): Map<String, Any> {
        val data = call("GET", "/api/v1/tasks/$taskId/status").getJSONObject("data")
        val state = when (data.optString("status")) {
            "done" -> "done"
            "error" -> "error"
            else -> "running"
        }
        return mapOf(
            "state" to state,
            "downloaded" to data.optLong("downloaded"),
            "total" to data.optLong("total"),
        )
    }

    /** 拉起系统安装器安装已下载的更新包，返回 started/permission/failed。 */
    fun install(taskId: String): String {
        val file = taskFiles[taskId] ?: return "failed"
        if (!file.exists() || file.length() <= 0L) return "failed"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !appContext.packageManager.canRequestPackageInstalls()
        ) {
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${appContext.packageName}")
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(settingsIntent)
            return "permission"
        }

        val uri = FileProvider.getUriForFile(
            appContext,
            "${appContext.packageName}.fileprovider",
            file
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appContext.startActivity(installIntent)
        return "started"
    }

    /** 把内核的异步回调式调用包成同步调用，并解出统一响应体。 */
    private fun call(method: String, path: String, body: String = ""): JSONObject {
        val latch = CountDownLatch(1)
        var payload: String? = null
        var failure: String? = null

        Libgopeed.invokeAsync(
            method,
            path,
            "",
            body,
            System.nanoTime(),
            object : InvokeResultListener {
                override fun onResult(requestID: Long, success: Boolean, result: String?) {
                    if (success) payload = result else failure = result
                    latch.countDown()
                }
            },
        )

        if (!latch.await(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            throw IOException("Gopeed 内核响应超时")
        }
        failure?.let { throw IOException(it) }

        val response = JSONObject(payload ?: "")
        val code = response.optInt("code")
        if (code != 0) {
            throw IOException(response.optString("msg").ifBlank { "Gopeed 内核调用失败（$code）" })
        }
        return response
    }

    private companion object {
        /**
         * 并发连接数。内核会从 1 开始按 1/2/4/16… 逐步扩张到该上限，
         * 既能多段加速，也不至于因瞬间并发过高被 CDN 限速。
         */
        const val CONNECTIONS = 64
        const val CALL_TIMEOUT_SECONDS = 30L
    }
}
