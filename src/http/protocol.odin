/*
This file is part of https://github.com/mocompute/odin-http.
Version: 0.1

From the perspective of an implementer, the HTTP/1.1 protocol involves several RFCs,
including RCF9112, RFC9110, RFC5234.

All section references are to sections of RFC9112 unless otherwise noted.
*/
package http

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"

PROTOCOL_VERSION :: "HTTP/1.1"
MAX_REQUEST_TARGET_LEN :: 2048

@private
Http_Request :: struct {
	request_line: Http_Request_Line,
	headers: map[string]string,
	content_length: int,
	is_chunked: bool,
	rest: []u8,
}

Http_Method :: enum {
	Get, Head, Post, Put, Delete, Connect, Options, Trace,
}

Http_Request_Line :: struct {
	method: Http_Method,
	request_target: string,
	http_version: string,
}

Protocol_Error :: enum {
	None,
	Not_Implemented,
	Invalid_Method,
	Incomplete,
	Expected_Single_Space,
	Expected_Crlf,
	Invalid_Request_Target,
	Invalid_Http_Version,
	Invalid_Content_Length,
	Bad_Field_Syntax,
	Transfer_Encoding_And_Content_Length,
	Bad_Chunk_Size,
	Too_Much_Content,
}

parse_http_message :: proc(message: []u8, allocator: mem.Allocator) -> (request: Request, err: Protocol_Error) {
	req: Http_Request
	req = parse_message_head(message[:], allocator) or_return

	content := make([dynamic]u8, allocator)
	if req.is_chunked {
		err = parse_chunked_content(req.rest, &content)
		if err != nil do return

	} else if req.content_length != 0 {
		if len(req.rest) < req.content_length {
			err = .Incomplete
			return
		} else if len(req.rest) > req.content_length {
			err = .Too_Much_Content
			return
		}
		append(&content, ..req.rest)
	}

	request = {
		method = req.request_line.method,
		target = req.request_line.request_target,
		headers = req.headers,
		content = string(content[:]),
	}
	return
}

protocol_error_to_response :: proc(err: Protocol_Error, allocator: mem.Allocator) -> string {
	status_line: string

	code: int
	#partial switch err {
	case .None:            code=200
	case .Not_Implemented: code=501
	case:                  code=400
	}
	status_line = status_to_line(code)

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, PROTOCOL_VERSION)
	strings.write_string(&sb, " ")
	strings.write_string(&sb, status_line)
	strings.write_string(&sb, "\r\n")
	strings.write_string(&sb, "Connection: close\r\n")
	strings.write_string(&sb, "\r\n")
	return strings.to_string(sb)
}




/*

Lifetimes: the strings in the returned Http_Request are slices into the message
argument.

*/
parse_message_head :: proc(message: []u8, allocator: mem.Allocator) -> (req: Http_Request, err: Protocol_Error) {
	// https://www.rfc-editor.org/info/rfc9112/#section-2.1-1
	// HTTP-message   = start-line CRLF
	//                  *( field-line CRLF )
	//                  CRLF
	//                  [ message-body ]

	// Skip zero or more initial CRLF:
	// https://www.rfc-editor.org/info/rfc9112/#section-2.2-6
	rest := skip_crlf_zom(message)

	// Request line:
	// https://www.rfc-editor.org/info/rfc9112/#section-3
	req_line: Http_Request_Line
	req_line, rest = parse_request_line(rest) or_return

	fields: map[string]string
	fields, rest = parse_zom_field_lines(rest, allocator) or_return

	req = {
		request_line = req_line,
		headers = fields,
		rest = rest,
	}

	fval, ok := req.headers["content-length"]
	if ok {
		val, ok1 := strconv.parse_uint(fval)
		if ok1 {
			// overflow
			if val > uint(max(int)) do val = 0
			req.content_length = int(val)
		} else {
			err = .Invalid_Content_Length
			return
		}
	} else {
		req.content_length = 0
	}


	// Transfer-Encoding: chunked
	fval, ok = req.headers["transfer-encoding"]
	if ok {
		if fval != "chunked" {
			err = .Not_Implemented
			return
		} else {
			req.is_chunked = true
			req.content_length = 0
		}
	}
	return
}

skip_crlf_zom :: proc(data: []u8) -> (rest: []u8) {
	rest = data
	for len(rest) > 1 {
		if rest[0] == '\r' && rest[1] == '\n' {
			rest = rest[2:]
		} else {
			break
		}
	}
	return
}

parse_request_line :: proc(data: []u8) -> (request_line: Http_Request_Line, rest: []u8, err: Protocol_Error) {
	// https://www.rfc-editor.org/info/rfc9112/#section-3
	// request-line   = method SP request-target SP HTTP-version

	// Ignore any line if it is preceeded by whitespace. Do not trim.
	// https://www.rfc-editor.org/info/rfc9112/#section-2.2-8

	method: Http_Method
	target: string
	version: string

	method, rest = parse_method(data) or_return
	rest = parse_sp(rest) or_return
	target, rest = parse_request_target(rest) or_return
	rest = parse_sp(rest) or_return
	version, rest = parse_http_version(rest) or_return
	rest = parse_crlf(rest) or_return

	request_line = {
		method = method,
		request_target = target,
		http_version = version,
	}
	return
}

parse_method :: proc(s: []u8) -> (method: Http_Method, rest: []u8, err: Protocol_Error) {
	// Request token is case sensitive
	// https://www.rfc-editor.org/info/rfc9110/#section-9.1-5

	sz := len(s)
	if sz < 3 {
		err = .Incomplete
		return
	}
	if transmute(string)s[:3] == "GET" {
		method = .Get
		rest = s[3:]
		return
	} else if transmute(string)s[:3] == "PUT" {
		method = .Put
		rest = s[3:]
		return
	}

	if sz < 4 {
		err = .Incomplete
		return
	}
	if transmute(string)s[:4] == "HEAD" {
		method = .Head
		rest = s[4:]
		return
	} else	if transmute(string)s[:4] == "POST" {
		method = .Post
		rest = s[4:]
		return
	}

	if sz < 5 {
		err = .Incomplete
		return
	}
	if transmute(string)s[:5] == "TRACE" {
		method = .Trace
		rest = s[5:]
		return
	}

	if sz < 6 {
		err = .Incomplete
		return
	}
	if transmute(string)s[:6] == "DELETE" {
		method = .Delete
		rest = s[6:]
		return
	}

	if sz < 7 {
		err = .Incomplete
		return
	}
	if transmute(string)s[:7] == "CONNECT" {
		method = .Connect
		rest = s[7:]
		return
	} else if transmute(string)s[:7] == "OPTIONS" {
		method = .Options
		rest = s[7:]
		return
	} else {
		err = .Invalid_Method
		return
	}

	return
}

parse_sp :: proc(s: []u8) -> (rest: []u8, err: Protocol_Error) {
	if len(s) == 0 {
		err = .Incomplete
		return
	}
	if s[0] == ' ' {
		rest = s[1:]
	} else {
		err = .Expected_Single_Space
	}
	return
}

parse_crlf :: proc(s: []u8) -> (rest: []u8, err: Protocol_Error) {
	if len(s) < 2 {
		err = .Incomplete
		return
	}

	if s[0] == '\r' && s[1] == '\n' {
		rest = s[2:]
	} else {
		err = .Expected_Crlf
	}
	return
}

parse_request_target :: proc(s: []u8) -> (request_target: string, rest: []u8, err: Protocol_Error) {
	for sp in 0..<len(s) {
		if s[sp] == ' ' {
			request_target = string(s[:sp])
			rest = s[sp:]
			return
		}
	}

	if len(s) > MAX_REQUEST_TARGET_LEN {
		// No ' ' found, and data is too long: protocol error
		err = .Invalid_Request_Target
		return
	}

	err = .Incomplete
	return
}

parse_http_version :: proc(s: []u8) -> (http_version: string, rest: []u8, err: Protocol_Error) {

	// https://www.rfc-editor.org/info/rfc9112/#section-2.3
	// E.g.: HTTP/1.1
	if len(s) < 8 {
		err = .Incomplete
		return
	}
	if mem.compare(s[:5], {'H','T','T','P','/'}) != 0 {
		err = .Invalid_Http_Version
		return
	}
	if !is_digit(s[5]) || (s[6] != '.') || !is_digit(s[7]) {
		err = .Invalid_Http_Version
		return
	}
	http_version = string(s[:8])
	rest = s[8:]
	return
}

parse_zom_field_lines :: proc(s: []u8, allocator: mem.Allocator, discard: bool = false) -> (fields: map[string]string, rest: []u8, err: Protocol_Error) {
	if len(s) == 0 {
		err = .Incomplete
		return
	}

	if discard != true {
		fields = make(map[string]string, allocator)
		reserve(&fields, 8)
	}

	rest = s

	for len(rest) > 0 {
		if len(rest) < 2 {
			err = .Incomplete
			if discard != true {
				delete(fields)
			}
			fields = nil
			return
		}
		if rest[0] == '\r' && rest[1] == '\n' {
			rest = rest[2:]
			return
		}

		key, value: string
		key, value, rest, err = parse_field_line(rest)
		if err != nil {
			if discard != true {
				delete(fields)
			}
			fields = nil
			return
		}
		if discard != true {
			// Field names are case-insensitive
			// https://www.rfc-editor.org/rfc/rfc9110.html#section-5.1-3
			fields[strings.to_lower(key, allocator)] = value
		}
		rest = parse_crlf(rest) or_return
	}
	return
}

parse_field_line :: proc(s: []u8) -> (key: string, value: string, rest: []u8, err: Protocol_Error) {
	// Field name is a token.
	// https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.2-1
	// VCHAR: %x21-7E
	//
	// Disallow space before colon:
	// https://www.rfc-editor.org/info/rfc9112/#section-5.1-2

	rest = s
	for pos := 0; pos < len(rest); pos += 1 {
		c := rest[pos]
		if c < 0x21 || c > 0x7e {
			err = .Bad_Field_Syntax
			return
		}
		if c == ':' {
			if pos == 0 {
				// Colon in first column is a violation
				err = .Bad_Field_Syntax
				return
			}
			key = string(rest[:pos])
			pos += 1 // skip colon
			rest = rest[pos:]
			break
		}
	}

	if key == "" {
		err = .Incomplete
		return
	}

	// skip OWS after colon
	for pos := 0; pos < len(rest); pos += 1 {
		c := rest[pos]
		if c != ' ' && c != '\t' {
			rest = rest[pos:]
			break
		}
	}

	for pos := 0; pos < len(rest); pos += 1 {
		c := rest[pos]
		if c == '\r' || c == '\n' {
			value = string(rest[:pos])
			rest = rest[pos:]
			break
		}
	}

	return
}


parse_chunked_content :: proc(s: []u8, into: ^[dynamic]u8) -> (err: Protocol_Error) {
	// https://www.rfc-editor.org/info/rfc9112/#section-7.1.3
	n, length: int

	rest := s
	n, rest = parse_chunk_size(rest) or_return
	for n > 0 {
		if n > len(rest) {
			err = .Incomplete
			return
		}
		append(into, ..rest[:n])
		rest = rest[n:]
		rest = parse_crlf(rest) or_return
		length += n
		n, rest = parse_chunk_size(rest) or_return
	}

	// Discard trailer fields.
	_, rest = parse_zom_field_lines(rest, {}, discard=true) or_return

	return
}

parse_chunk_size :: proc(s: []u8) -> (n: int, rest: []u8, err: Protocol_Error) {
	// https://www.rfc-editor.org/info/rfc9112/#section-7.1
	// Chunk size may have optional extension after semicolon, we discard.
	if len(s) < 3 {
		// E.g. "7\r\n"
		err = .Incomplete
		return
	}

	pos := 0
	for ; pos < len(s); pos += 1 {
		c := s[pos]
		if c == ';' || c == '\r' {
			break
		}
	}

	length_s := s[0:pos]

	for c in length_s {
		d: u8
		if c >= '0' && c <= '9' do d = c - '0'
		else if c >= 'A' && c <= 'F' do d = 10 + c - 'A'
		else if c >= 'a' && c <= 'f' do d = 10 + c - 'a'
		else {
			err = .Bad_Chunk_Size
			return
		}
		n <<= 4
		n |= int(d)
	}

	// skip optional extension, if any, until crlf
	for ; pos < len(s); pos += 1 {
		if s[pos] == '\r' {
			break
		}
	}

	// rest will point to beginning of data for this chunk
	rest, err = parse_crlf(s[pos:])
	return
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

status_to_line :: proc(code: int) -> (s: string) {
	// https://www.rfc-editor.org/rfc/rfc9110.html#section-15
	switch code {
	case 100: s="100 Continue"
	case 101: s="101 Switching Protocols"

	case 200: s="200 OK"
	case 201: s="201 Created"
	case 202: s="202 Accepted"
	case 203: s="203 Non-Authoritative Information"
	case 204: s="204 No Content"
	case 205: s="205 Reset Content"
	case 206: s="206 Partial Content"

	case 300: s="300 Multiple Choices"
	case 301: s="301 Moved Permanently"
	case 302: s="302 Found"
	case 303: s="303 See Other"
	case 304: s="304 Not Modified"
	case 305: s="305 Use Proxy"
	case 306: s="306"	// Unused
	case 307: s="307 Temporary Redirect"
	case 308: s="308 Permanent Redirect"

	case 400: s="400 Bad Request"
	case 401: s="401 Unauthorized"
	case 402: s="402 Payment Required"
	case 403: s="403 Forbidden"
	case 404: s="404 Not Found"
	case 405: s="405 Method Not Allowed"
	case 406: s="406 Not Acceptable"
	case 407: s="407 Proxy Authentication Required"
	case 408: s="408 Request Timeout"
	case 409: s="409 Conflict"
	case 410: s="410 Gone"
	case 411: s="411 Length Required"
	case 412: s="412 Precondition Failed"
	case 413: s="413 Content Too Large"
	case 414: s="414 URI Too Long"
	case 415: s="415 Unsupported Media Type"
	case 416: s="416 Range Not Satisfiable"
	case 417: s="417 Expectation Failed"
	case 418: s="418"	// Unused
	case 421: s="421 Misdirected Request"
	case 422: s="422 Unprocessable Content"
	case 426: s="426 Upgrade Required"

	case 501: s="501 Not Implemented"
	case 502: s="502 Bad Gateway"
	case 503: s="503 Service Unavailable"
	case 504: s="504 Gateway Timeout"
	case 505: s="505 HTTP Version Not Supported"
	case:     s="500 Internal Server Error"
	}
	return
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
