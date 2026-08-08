/*
This file is part of https://github.com/mocompute/odin-http.
Version: 0.1.1
*/
package http

import "core:container/xar"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:net"
import "core:nbio"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "core:testing"

INITIAL_BUFFER_SIZE :: 4 * 1024
INITIAL_CONNECTION_BUFFERS :: 8
CHUNK_SIZE :: 1024

Request :: struct {
	method: Http_Method,
	target: string,
	headers: map[string]string,
	content: string,
}

Response :: struct {
	status: int,
	headers: map[string]string,
	content: string,
	keep_alive: bool,
}

Handler :: proc(Request) -> Response

Error :: union #shared_nil {
	Protocol_Error,
	nbio.Error,
	nbio.General_Error,
	net.Network_Error,
}

Server :: struct {
	parent_allocator: mem.Allocator,
	tz_region: ^datetime.TZ_Region,

	loop: ^nbio.Event_Loop,
	accept_op: ^nbio.Operation,

	// stable pointers required due to concurrency and the free_list
	connections: xar.Array(Connection, 4), // 1 << 4 == 16

	free_list: [dynamic]^Connection,       // connections that are reusable

	null_fd: ^os.File,		       // spare file descriptor in case of fd exhaustion
	server_503: []u8,		       // preallocate a 503 message for server overload

	request_handler: Handler,
	shutdown: bool,			       // atomic shutdown signal
}

Connection :: struct {
	server: ^Server,
	arena: virtual.Arena,
	socket: nbio.TCP_Socket,
	current_op: ^nbio.Operation,
	buffers: [dynamic][]u8,
	read: [dynamic]u8,
}

// Initialize a brand new connection: creates a virtual arena.
connection_init :: proc(conn: ^Connection, server: ^Server, socket: nbio.TCP_Socket) {
	err := virtual.arena_init_growing(&conn.arena)
	if err != nil do panic("oom")

	connection_reinit(conn, server, socket)
}

// Reinitialize a connection that is about to be reused. The connection was previously
// released with `connection_release`.
connection_reinit :: proc(conn: ^Connection, server: ^Server, socket: nbio.TCP_Socket) {
	conn.server = server
	conn.socket = socket
	conn.current_op = nil

	allocator := virtual.arena_allocator(&conn.arena)
	conn.buffers = make([dynamic][]u8, 0, 8, allocator)
	conn.read = make([dynamic]u8, 0, CHUNK_SIZE, allocator)

	append(&conn.buffers, make([]u8, INITIAL_BUFFER_SIZE, allocator))
}

// Release buffers allocated by connection and add self to server's free list. Prepare
// for future `connection_reinit`.
connection_release :: proc(conn: ^Connection, add_to_free_list := true) {
	if add_to_free_list {
		append(&conn.server.free_list, conn)
	}

	// A nice feature of the growing arena is that this free_all call is very fast,
	// and it decommits all but the very first block in the arena.
	virtual.arena_free_all(&conn.arena)

	conn.server = nil
	conn.socket = {}
	conn.current_op = nil
	conn.buffers = nil
	clear(&conn.read)
}

// Release buffers to prepare connection for another message on the same socket.
connection_recycle :: proc(conn: ^Connection) {
	server := conn.server
	socket := conn.socket
	connection_release(conn, add_to_free_list=false)
	connection_reinit(conn, server, socket)
}

// Deallocate all buffers allocated by the connection.
connection_deinit :: proc(conn: ^Connection) {
	connection_release(conn, add_to_free_list=false)
	virtual.arena_destroy(&conn.arena)
}

server_init :: proc(self: ^Server, handler: Handler = handler_echo, allocator := context.allocator) {
	self.parent_allocator = allocator
	self.request_handler = handler
	self.free_list = make([dynamic]^Connection, 0, 16, allocator)

	err: os.Error
	self.null_fd, err = open_dev_null()
	if err != nil {
		panic("failed to open /dev/null")
	}

	for _ in 0..<INITIAL_CONNECTION_BUFFERS {
		conn := xar.append_and_get_ptr(&self.connections, Connection{}) or_else panic("oom")
		connection_init(conn, self, {})
		append(&self.free_list, conn)
	}

	// "local" retrieves the local time zone region
	self.tz_region = timezone.region_load("local", self.parent_allocator) or_else panic("timezone.region_load failed")

	// preallocate a 503 message for server overload
	res_error := Response {status=503}
	self.server_503 = serialize_response(self^, res_error, allocator, omit_date=true)
}

server_deinit :: proc(self: ^Server) {
	os.close(self.null_fd)
	delete(self.free_list)

	it := xar.iterator(&self.connections)
	for c in xar.iterate_by_ptr(&it) {
		connection_deinit(c)
	}
	xar.array_destroy(&self.connections)

	timezone.region_destroy(self.tz_region, self.parent_allocator)
	delete(self.server_503)
}

server_listen :: proc(server: ^Server, endpoint: net.Endpoint) -> (err: Error) {
	err = nbio.acquire_thread_event_loop()
	fmt.ensuref(err == nil, "Could not initialize nbio: %v", err)
	defer nbio.release_thread_event_loop()

	server.loop = nbio.current_thread_event_loop()

	sock := nbio.listen_tcp(endpoint) or_return
	server.accept_op = nbio.accept_poly(sock, server, on_accept)

	nbio.run() or_return
	return
}

server_shutdown :: proc(server: ^Server) {
	on_shutdown :: proc(op: ^nbio.Operation, server: ^Server) {
		// Remove all pending connection operations, and then remove server's listen operation.
		it := xar.iterator(&server.connections)
		for conn in xar.iterate_by_ptr(&it) {
			if conn.current_op != nil {
				nbio.remove(conn.current_op)
				conn.current_op = nil
			}
		}

		if server.accept_op != nil {
			nbio.remove(server.accept_op)
			server.accept_op = nil
		}
	}
	sync.atomic_store(&server.shutdown, true)
	nbio.next_tick_poly(server, on_shutdown, l = server.loop)
}

on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	if sync.atomic_load(&server.shutdown) do return
	if op.accept.err == .Insufficient_Resources {
		// Socket exhaustion handling.
		//
		// Release our spare file descriptor so we can accept the client socket, in
		// order to close it immediately.

		os.close(server.null_fd)

		on_accept_to_close :: proc(op: ^nbio.Operation, server: ^Server) {
			if op.accept.err != nil {
				fmt.eprintfln("on_accept_to_close failed with %s", op.accept.err)
				// fallthrough
			}

			// Close the client connection immediately.
			send_503_and_close(server^, op.accept.client)

			// Reopen our spare file descriptor.
			server.null_fd = open_dev_null() or_else panic("failed to open /dev/null")

			if sync.atomic_load(&server.shutdown) do return

			// Queue an accept for the next client.
			nbio.accept_poly(op.accept.socket, server, on_accept)
		}

		nbio.accept_poly(op.accept.socket, server, on_accept_to_close)
		return
	} else if op.accept.err != nil {
		// Another error occurred which is not recoverable. Abandon and re-queue.
		nbio.accept_poly(op.accept.socket, server, on_accept)
		return
	}

	// Queue an accept for the next client.
	server.accept_op = nbio.accept_poly(op.accept.socket, server, on_accept)

	// Make a Connection to handle this client.
	// Reuse a slot in the connections array if possible.
	conn: ^Connection
	if len(server.free_list) != 0 {
		conn = pop(&server.free_list)
		connection_reinit(conn, server, op.accept.client)
	} else {
		conn = xar.append_and_get_ptr(&server.connections, Connection{}) or_else panic("oom")
		connection_init(conn, server, op.accept.client)
	}

	// Receive data on client socket.
	conn.current_op = nbio.recv_poly(op.accept.client, conn.buffers[:], conn, on_recv)
}

on_recv :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if sync.atomic_load(&conn.server.shutdown) do return
	is_timeout := op.recv.err == net.TCP_Recv_Error.Timeout

	if !is_timeout {
		if op.recv.err != nil {
			connection_release(conn)
			nbio.close(op.recv.socket.(net.TCP_Socket))
			conn.current_op = nil
			return
		}
		if op.recv.received == 0 {
			// Connection closed by peer: close our side too to release the socket.
			connection_release(conn)
			nbio.close(op.recv.socket.(net.TCP_Socket))
			conn.current_op = nil
			return
		}
	}

	allocator := virtual.arena_allocator(&conn.arena)

	// Drain buffer into read buffer. We only ever use a single recv buffer.
	ensure(1 == len(conn.buffers))
	append(&conn.read, ..conn.buffers[0][:op.recv.received])
	conn.buffers[0] = nil	// arena

	request, err := parse_http_message(conn.read[:], allocator)
	if is_timeout && err == .Incomplete {
		// Message is still incomplete, even after a timed out recv. We need to
		// hang up from our side and send a 408.
		send_and_close(conn, 408)
		return
	}
	if err == .Incomplete {
		// Message is incomplete. Queue another recv, with a timeout.
		conn.buffers[0] = make([]u8, CHUNK_SIZE)
		conn.current_op = nbio.recv_poly(conn.socket, conn.buffers[:], conn, on_recv, timeout=5*time.Second)
		return
	}
	if err != nil {
		message := protocol_error_to_response(err, allocator)
		conn.current_op = nbio.send_poly(conn.socket, {transmute([]u8)message}, conn, on_sent_close)
		return
	}

	response := conn.server.request_handler(request)
	bytes := serialize_response(conn.server^, response, allocator)
	if response.keep_alive {
		conn.current_op = nbio.send_poly(conn.socket, {bytes}, conn, on_sent)
	} else {
		conn.current_op = nbio.send_poly(conn.socket, {bytes}, conn, on_sent_close)
	}

}

on_sent :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if op.send.err != nil {
		connection_release(conn)
		nbio.close(op.send.socket.(net.TCP_Socket))
		conn.current_op = nil
		return
	}

	connection_recycle(conn)

	// Queue the receive for the next message from the client.
	if sync.atomic_load(&conn.server.shutdown) do return
	conn.current_op = nbio.recv_poly(op.send.socket, conn.buffers[:], conn, on_recv)
}

on_sent_close :: proc(op: ^nbio.Operation, conn: ^Connection) {
	connection_release(conn)
	nbio.close(op.send.socket.(net.TCP_Socket))
	conn.current_op = nil
}

on_sent_close_no_conn :: proc(op: ^nbio.Operation) {
	nbio.close(op.send.socket.(net.TCP_Socket))
}

send_and_close :: proc(conn: ^Connection, status_code: int) {
	response := Response{status = status_code}
	bytes := serialize_response(conn.server^, response, virtual.arena_allocator(&conn.arena))
	conn.current_op = nbio.send_poly(conn.socket, {bytes}, conn, on_sent_close)
}

send_503_and_close :: proc(server: Server, socket: net.TCP_Socket)  {
	nbio.send(socket, {server.server_503}, on_sent_close_no_conn)
	// tick immediately, because we need a free socket back
	nbio.tick()
}



open_dev_null :: proc() -> (^os.File, os.Error) {
	dev_null := "/dev/null"
	when ODIN_OS == .Windows {
		dev_null = "NUL"
	}
	return os.open(dev_null, {.Read})
}

handler_echo :: proc(req: Request) -> (res: Response) {
	if len(req.content) > 0 {
		res = {
			status = 200,
			content = req.content,
			keep_alive = true,
		}
	} else {
		res = {
			status = 204,
			keep_alive = true,
		}
	}
	return
}

serialize_response :: proc(server: Server, res: Response, allocator: mem.Allocator, omit_date := false) -> []u8 {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, PROTOCOL_VERSION)
	strings.write_string(&sb, " ")
	strings.write_string(&sb, status_to_line(res.status))
	strings.write_string(&sb, "\r\n")

	// Always write Date header, except in case of 503, which we pre-render to avoid
	// allocating during an overload condition.
	// https://www.rfc-editor.org/info/rfc5322/#section-3.3
	if !omit_date {
		now := time.now()
		s := rfc5322(server, now, allocator)
		strings.write_string(&sb, "Date: ")
		strings.write_string(&sb, s)
		strings.write_string(&sb, "\r\n")
	}

	// Connection and Content-Length headers
	if res.keep_alive {
		strings.write_string(&sb, "Connection: keep-alive\r\n")
	} else {
		strings.write_string(&sb, "Connection: close\r\n")
	}
	if res.keep_alive || len(res.content) != 0 {
		// Always write Content-length for keep-alive connections
		strings.write_string(&sb, "Content-length: ")
		strings.write_int(&sb, len(res.content))
		strings.write_string(&sb, "\r\n")
	}

	for k, v in res.headers {
		strings.write_string(&sb, k)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, v)
		strings.write_string(&sb, "\r\n")
	}
	strings.write_string(&sb, "\r\n")

	strings.write_string(&sb, res.content)

	return transmute([]u8) strings.to_string(sb)
}


@(rodata)
MONTHS := [12]string{"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}

rfc5322 :: proc(server: Server, t: time.Time, allocator: mem.Allocator) -> string {
	// https://www.rfc-editor.org/info/rfc5322/#section-3.3
	dt := time.time_to_datetime(t) or_else panic("time_to_datetime failed")
	year, month, day := time.date(t)

	dt = timezone.datetime_to_tz(dt, server.tz_region) or_else panic("datetime_to_tz failed")
	dt = timezone.datetime_to_utc(dt) or_else panic("datetime_to_utc failed")

	return fmt.aprintf("%2.d %s %4.d %2.d:%2.d:%2.d +0000",
			   day, MONTHS[int(month)-1], year,
			   dt.hour, dt.minute, dt.second, allocator=allocator)
}



@(test)
test_rfc5322 :: proc(t: ^testing.T) {
	server: Server
	server_init(&server)
	defer server_deinit(&server)

	now := time.now()
	s := rfc5322(server, now, context.temp_allocator)

	fmt.eprintln("res = ", s)
}
