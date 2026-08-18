/*
This file is part of https://github.com/mocompute/odin-http.
*/
package main

import "../../src/http"

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:nbio"
import "core:thread"

Ctx :: struct {
	server: ^http.Server,
}
global_ctx: Ctx

serve :: proc(server: ^http.Server) {
	fmt.println("Listening on port 8123...")
	err := http.server_listen(server, {nbio.IP4_Any, 8123})
	if err != nil {
		fmt.eprintfln("listen error: %s", err)
	}
}

interrupt :: proc "c" (sig: libc.int) {
	context = runtime.default_context()
	fmt.eprintln("Caught Control-C, shutting down...")
	http.server_shutdown(global_ctx.server)
}

handler_echo :: proc(req: http.Request) -> (res: http.Response) {
	if req.is_websocket {
		// Websocket session already established.
		// Send response in res.content.
		// Set res.keep_alive to true to keep connection open.
		// RFC6455 Sec. 5.5.1 Close protocol is not supported, but is not required by RFC.
		// Default response frame is text; set res.ws_is_binary to select binary.
		res.keep_alive = true
		res.content = req.content // echo
		res.ws_is_binary = req.ws_is_binary
	} else {
		// Check for websocket upgrade request
		is_upgrade: bool
		status: int
		res, is_upgrade, status = http.maybe_websocket_upgrade(req, context.temp_allocator)
		if is_upgrade {
			// http will send the handshake reply back to the client
		} else {
			// give an error because this endpoint only accepts websocket connections
			res.status = 400
			res.keep_alive = false
		}
	}

	return
}

main :: proc() {
	libc.signal(libc.SIGINT, interrupt)

	server: http.Server
	http.server_init(&server, handler_echo)
	defer http.server_deinit(&server)
	global_ctx.server = &server

	th := thread.create_and_start_with_poly_data(&server, serve)
	thread.join(th)

	fmt.eprintln("Shutdown.")
}
