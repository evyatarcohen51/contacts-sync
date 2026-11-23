package com.dvirchi.contactsync.receiver

import com.dvirchi.contactsync.receiver.MiniHttpServer.Request
import com.dvirchi.contactsync.receiver.MiniHttpServer.Response
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class MiniHttpServerTest {
    private val port = ServerSocket(0).use { it.localPort }
    private val handled = AtomicInteger()
    private val wrapped = AtomicInteger()
    private val interrupted = CountDownLatch(1)
    private lateinit var server: MiniHttpServer

    @Before
    fun start() {
        server = MiniHttpServer(
            port,
            preflight = { r -> if (r.header("x-reject") == "1") Response.error(401, "no") else null },
            around = { serve -> wrapped.incrementAndGet(); serve() },
            onInterrupted = { interrupted.countDown() },
        ) { r: Request ->
            handled.incrementAndGet()
            Response.json(200, "method" to r.method, "path" to r.path, "len" to r.body.size,
                "echo" to String(r.body, Charsets.UTF_8), "h" to r.header("X-Thing"))
        }
        server.start()
    }

    @After
    fun stop() = server.stop()

    /** Sends raw bytes and returns the whole reply (the server closes the connection). */
    private fun raw(request: String, closeOutput: Boolean = false): String =
        Socket("127.0.0.1", port).use { s ->
            s.soTimeout = 5_000
            s.getOutputStream().apply { write(request.toByteArray()); flush() }
            if (closeOutput) s.shutdownOutput()
            s.getInputStream().readBytes().toString(Charsets.UTF_8)
        }

    @Test
    fun servesARequestWithBodyAndHeaders() {
        val reply = raw("PUT /v1/x?y=1 HTTP/1.1\r\nHost: a\r\nx-thing: hi\r\nContent-Length: 5\r\n\r\nhello")
        assertTrue(reply, reply.startsWith("HTTP/1.1 200 OK\r\n"))
        assertTrue(reply.contains("Connection: close"))
        val body = reply.substringAfter("\r\n\r\n")
        assertTrue(body, body.contains("\"method\":\"PUT\""))
        assertTrue(body.contains("\"path\":\"\\/v1\\/x\"") || body.contains("\"path\":\"/v1/x\""))
        assertTrue(body.contains("\"len\":5") && body.contains("\"echo\":\"hello\"") && body.contains("\"h\":\"hi\""))
        assertEquals(1, wrapped.get())
    }

    @Test
    fun preflightRejectsBeforeTheBodyArrives() {
        // Announces 40 MB but sends none of it: the reply must come without waiting for the body.
        val t0 = System.nanoTime()
        val reply = raw("PUT /v1/contacts HTTP/1.1\r\nX-Reject: 1\r\nContent-Length: 40000000\r\n\r\n")
        assertTrue(reply, reply.startsWith("HTTP/1.1 401 "))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0) < 3_000)
        assertEquals(0, handled.get())
    }

    @Test
    fun refusesOversizedBodies() {
        val reply = raw("PUT /v1/contacts HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
        assertTrue(reply, reply.startsWith("HTTP/1.1 413 "))
        assertEquals(0, handled.get())
    }

    @Test
    fun reportsAnUploadThatBreaksOff() {
        val reply = raw("PUT /v1/contacts HTTP/1.1\r\nContent-Length: 100\r\n\r\nonly part", closeOutput = true)
        assertEquals("", reply)
        assertTrue(interrupted.await(5, TimeUnit.SECONDS))
        assertEquals(0, handled.get())
    }

    @Test
    fun survivesAConnectionThatSendsNothing() {
        // What the iPhone's address lookup does: connect, then hang up.
        assertEquals("", raw("", closeOutput = true))
        assertTrue(raw("GET /v1/hello HTTP/1.1\r\n\r\n").startsWith("HTTP/1.1 200 "))
    }

    @Test
    fun handlerErrorsBecome500() {
        val boom = AtomicBoolean()
        val p = ServerSocket(0).use { it.localPort }
        val s = MiniHttpServer(p) { boom.set(true); error("kaboom") }
        s.start()
        try {
            val reply = Socket("127.0.0.1", p).use { c ->
                c.getOutputStream().apply { write("GET / HTTP/1.1\r\n\r\n".toByteArray()); flush() }
                c.getInputStream().readBytes().toString(Charsets.UTF_8)
            }
            assertTrue(reply, reply.startsWith("HTTP/1.1 500 "))
            assertTrue(reply.contains("kaboom"))
            assertTrue(boom.get())
            assertFalse(reply.contains("Exception in thread"))
        } finally {
            s.stop()
        }
    }
}
