/*
This file is part of https://github.com/mocompute/odin-http.
Version: 0.1
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
