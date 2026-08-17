#+test
package http

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:testing"
import "core:time"
import "core:fmt"

client_verify_handshake :: proc(key: string, server_key: string) -> bool {
	buf: [256]u8
	hash: [sha1.DIGEST_SIZE]u8
	ctx: sha1.Context

	copy(buf[:], transmute([]u8)key)

	uuid := WEBSOCKET_MAGIC
	copy(buf[len(key):], transmute([]u8)uuid)

	payload := buf[:len(key)+len(uuid)]
	sha1.init(&ctx)
	sha1.update(&ctx, payload)
	sha1.final(&ctx, hash[:])
	hash_b64, err := base64.encode_into_buf(buf[:], hash[:])
	if err != nil do return false
	return server_key == string(hash_b64)
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

@(test)
test_websocket_handshake :: proc (t: ^testing.T) {
	allocator := context.temp_allocator
	req: Request
	req.headers = make(map[string]string, allocator)

	buf: [256]u8
	key: [16]u8
	crypto.rand_bytes(key[:])
	key_b64, err := base64.encode_into_buf(buf[:], key[:])
	testing.expect(t, err == nil)

	req.headers["upgrade"] = "websocket"
	req.headers["connection"] = "Upgrade"
	req.headers["sec-websocket-key"] = string(key_b64)
	req.headers["sec-websocket-version"]  = "13"

	res, is_upgrade, status := maybe_websocket_upgrade(req, allocator)
	testing.expect(t, is_upgrade)
	testing.expect_value(t, status, 101)
	fmt.eprintfln("Sec-WebSocket-Accept = %v", res.headers["Sec-WebSocket-Accept"])

	testing.expect(t, client_verify_handshake(string(key_b64), res.headers["Sec-WebSocket-Accept"]))
}


@(test)
test_parse_chunk_length :: proc(t: ^testing.T) {
	n: int
	s: string
	err: Protocol_Error
	s = "0\r\n"
	n, _, err = parse_chunk_size(transmute([]u8)s)
	testing.expect_value(t, 0, n)

	s = "00\r\n"
	n, _, err = parse_chunk_size(transmute([]u8)s)
	testing.expect_value(t, 0, n)

	s = "1f\r\n"
	n, _, err = parse_chunk_size(transmute([]u8)s)
	testing.expect_value(t, 0x1f, n)

	s = "1F\r\n"
	n, _, err = parse_chunk_size(transmute([]u8)s)
	testing.expect_value(t, 0x1F, n)

	s = "1FX\r\n"
	n, _, err = parse_chunk_size(transmute([]u8)s)
	testing.expect_value(t, err, Protocol_Error.Bad_Chunk_Size)
}

@(test)
test_request_line_good :: proc(t: ^testing.T) {
	input := "GET /index.html HTTP/1.1\r\n"

	line, rest, err := parse_request_line(transmute([]u8) input)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, line.method, Http_Method.Get)
	testing.expect_value(t, line.request_target, "/index.html")
	testing.expect_value(t, line.http_version, "HTTP/1.1")
	testing.expect_value(t, 0, len(rest))
}

@(test)
test_field_lines_good :: proc(t: ^testing.T) {
	input := "Content-Length: 128\r\nCookie: monster\r\n"

	fields, rest, err := parse_zom_field_lines(transmute([]u8) input[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(fields), 2)
	testing.expect_value(t, len(rest), 0)
	testing.expect_value(t, fields["content-length"], "128")
	testing.expect_value(t, fields["cookie"], "monster")
}

@(test)
test_message_head :: proc(t: ^testing.T) {
	// HTTP-message   = start-line CRLF
	//                  *( field-line CRLF )
	//                  CRLF
	//                  [ message-body ]

	input := "PUT / HTTP/1.1\r\nContent-length: 128\r\n\r\n"

	req, err := parse_message_head(transmute([]u8) input[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	_ = req

}
