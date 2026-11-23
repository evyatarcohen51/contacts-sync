package com.dvirchi.contactsync.receiver

import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Tiny dependency-free HTTP/1.1 server (one request per connection).
 *
 * [preflight] runs after the headers are read and before the body is: returning a
 * response rejects the request without buffering its body (so an unauthenticated
 * caller cannot make the phone allocate a large upload). [around] wraps the whole
 * connection, e.g. to hold a wake lock while a request is being received.
 * [onInterrupted] is told when a request passed preflight but its body never fully arrived.
 */
class MiniHttpServer(
    private val port: Int,
    private val preflight: (Request) -> Response? = { null },
    private val around: (() -> Unit) -> Unit = { it() },
    private val onInterrupted: (Request) -> Unit = {},
    private val handler: (Request) -> Response,
) {
    class Request(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val body: ByteArray,
        val remote: InetAddress?,
    ) {
        fun header(name: String) = headers[name.lowercase()]
        fun json(): JSONObject = if (body.isEmpty()) JSONObject() else JSONObject(String(body, Charsets.UTF_8))
    }

    class Response(val status: Int, val body: ByteArray = ByteArray(0), val contentType: String = "application/json") {
        companion object {
            fun json(status: Int, vararg pairs: Pair<String, Any?>): Response {
                val o = JSONObject()
                pairs.forEach { (k, v) -> o.put(k, v ?: JSONObject.NULL) }
                return Response(status, o.toString().toByteArray())
            }
            fun error(status: Int, msg: String) = json(status, "error" to msg)
        }
    }

    companion object {
        private const val TAG = "MiniHttpServer"
        private const val MAX_BODY = 50 * 1024 * 1024
        private val REASONS = mapOf(
            200 to "OK", 202 to "Accepted", 400 to "Bad Request", 401 to "Unauthorized",
            403 to "Forbidden", 404 to "Not Found", 409 to "Conflict", 410 to "Gone",
            413 to "Payload Too Large", 422 to "Unprocessable Entity", 500 to "Internal Server Error",
            503 to "Service Unavailable",
        )
    }

    private var socket: ServerSocket? = null
    private var pool: ExecutorService? = null

    @Synchronized
    fun start() {
        if (socket != null) return
        val ss = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(port))
        }
        socket = ss
        val p = Executors.newFixedThreadPool(4).also { pool = it }
        thread(name = "http-accept", isDaemon = true) {
            while (!ss.isClosed) {
                try {
                    val s = ss.accept()
                    p.execute { around { serve(s) } }
                } catch (e: IOException) {
                    if (ss.isClosed) break
                    Log.w(TAG, "accept failed", e)
                }
            }
        }
        Log.i(TAG, "listening on :$port")
    }

    @Synchronized
    fun stop() {
        runCatching { socket?.close() }
        pool?.shutdownNow()
        socket = null
        pool = null
    }

    private fun serve(s: Socket) {
        s.use { sock ->
            try {
                sock.soTimeout = 30_000
                val input = DataInputStream(BufferedInputStream(sock.getInputStream()))
                val requestLine = readLine(input) ?: return
                val parts = requestLine.split(" ")
                if (parts.size < 2) return write(sock, Response.error(400, "bad request"))
                val headers = HashMap<String, String>()
                while (true) {
                    val line = readLine(input) ?: break
                    if (line.isEmpty()) break
                    val i = line.indexOf(':')
                    if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
                }
                val method = parts[0].uppercase()
                val path = parts[1].substringBefore('?')
                val len = headers["content-length"]?.toIntOrNull() ?: 0
                if (len < 0 || len > MAX_BODY) return write(sock, Response.error(413, "too large"))

                val head = Request(method, path, headers, ByteArray(0), sock.inetAddress)
                val resp = try {
                    preflight(head) ?: run {
                        val body = try {
                            ByteArray(len).also { input.readFully(it) }
                        } catch (e: IOException) {
                            runCatching { onInterrupted(head) }
                            throw e
                        }
                        handler(Request(method, path, headers, body, sock.inetAddress))
                    }
                } catch (e: IOException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "handler failed", e)
                    Response.error(500, e.message ?: "internal error")
                } catch (e: OutOfMemoryError) {
                    Log.e(TAG, "out of memory handling $method $path", e)
                    Response.error(500, "The Samsung ran out of memory. Turn off contact photos and try again.")
                }
                write(sock, resp)
            } catch (e: IOException) {
                Log.w(TAG, "connection error: ${e.message}")
            }
        }
    }

    private fun readLine(input: InputStream): String? {
        val buf = java.io.ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1) return if (buf.size() == 0) null else buf.toString("ISO-8859-1")
            if (b == '\n'.code) break
            if (b != '\r'.code) buf.write(b)
            if (buf.size() > 8192) throw IOException("header line too long")
        }
        return buf.toString("ISO-8859-1")
    }

    private fun write(sock: Socket, r: Response) {
        val head = "HTTP/1.1 ${r.status} ${REASONS[r.status] ?: "Status"}\r\n" +
            "Content-Type: ${r.contentType}\r\n" +
            "Content-Length: ${r.body.size}\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        val out = sock.getOutputStream()
        out.write(head.toByteArray(Charsets.ISO_8859_1))
        out.write(r.body)
        out.flush()
    }
}
