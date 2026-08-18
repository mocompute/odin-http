package http

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:mem"
import "core:strings"
import "core:unicode"

Websocket_Data_Frame :: struct {
	fin, rsv1, rsv2, rsv3, mask: bool,
	opcode: Websocket_Opcode,
	length: u64,
	masking_key: [4]u8,
	encoded: []u8,
}

Websocket_Opcode :: enum {
	Invalid,
	Continuation,
	Text,
	Binary,
	Close,			// not yet supported
	Ping,
	Pong,
}

data_frame_parse :: proc(buf: []u8) -> (df: Websocket_Data_Frame, complete: bool, bytes_read: u64) {
	if len(buf) < 4 do return

	b0 := buf[0]
	fin    := b0 & 0b1000_0000
	rsv1   := b0 & 0b0100_0000
	rsv2   := b0 & 0b0010_0000
	rsv3   := b0 & 0b0001_0000
	opcode := b0 & 0b0000_1111

	b1 := buf[1]
	mask   := b1 & 0b1000_0000
	plen   := b1 & 0b0111_1111

	payload_length: u64
	pos := 2		// continue reading from byte 2
	if uint(plen) <= 125 {
		payload_length = u64(plen)
	} else if uint(plen) == 126 {
		if len(buf) < pos + 2 do return
		payload_length = u64(endian.unchecked_get_u16be(buf[pos:]))
		pos += 2
	} else if uint(plen) == 127 {
		if len(buf) < pos + 8 do return
		payload_length = u64(endian.unchecked_get_u64be(buf[pos:]))
		pos += 8
		payload_length &= 0x7fff_ffff_ffff_ffff // clear most significant bit
	}

	if len(buf) < pos + 4 do return
	masking_key: [4]u8
	if mask != 0 {
		copy(masking_key[:], buf[pos:pos+4])
		pos += 4
	}

	if u64(len(buf)) < u64(pos) + payload_length do return

	encoded: []u8
	complete = true
	bytes_read = u64(pos)+payload_length
	encoded = buf[pos:bytes_read]

	df.fin = fin != 0
	df.rsv1 = rsv1 != 0
	df.rsv2 = rsv2 != 0
	df.rsv3 = rsv3 != 0
	df.mask = mask != 0
	df.opcode = data_frame_opcode(opcode)
	df.length = payload_length
	df.masking_key = masking_key
	df.encoded = encoded
	return
}

data_frame_decode :: proc(df: ^Websocket_Data_Frame) {
	if !df.mask do return

	key: [4]u8 = df.masking_key
	for &b, i in df.encoded {
		b ~= key[i % 4]
	}
}

data_frame_opcode :: proc(b: u8) -> (op: Websocket_Opcode) {
	switch b {
	case 0:  op = .Continuation
	case 1:  op = .Text
	case 2:  op = .Binary
	case 8:  op = .Close
	case 9:  op = .Ping
	case 10: op = .Pong
	case:    op = .Invalid
	}
	return
}

data_frame_encode :: proc(op: Websocket_Opcode, payload: []u8, allocator: mem.Allocator) -> []u8 {
	length := u64(len(payload))
	if op == .Ping || op == .Pong {
		// max payload len for ping and pong
		length = min(125, length)
	}

	data := make([]u8, length + 16, allocator) // max header size is 14 bytes

	opcode: u8
	switch op {
	case .Continuation: opcode = 0
	case .Text:         opcode = 1
	case .Binary:       opcode = 2
	case .Close:        opcode = 8
	case .Ping:         opcode = 9
	case .Pong:         opcode = 10
	case .Invalid:      ensure(false, "invalid opcode")
	}

	b0: u8
	b0 |= 0b1000_0000	// fin = 1
	b0 |= (opcode & 0x0f)

	pos := 0
	data[pos] = b0
	pos += 1

	if length > u64(max(u16)) {
		data[pos] = 127
		pos += 1
		endian.unchecked_put_u64be(data[pos:], length)
		pos += 8
	} else if length > 125 {
		data[pos] = 126
		pos += 1
		endian.unchecked_put_u16be(data[pos:], u16(length))
		pos += 2
	} else {
		data[pos] = u8(length)
		pos += 1
	}

	copy(data[pos:], payload)
	return data[:pos+len(payload)]
}



maybe_websocket_upgrade :: proc(req: Request, allocator: mem.Allocator) -> (res: Response, is_upgrade: bool, status: int) {
	is_websocket_upgrade :: proc(req: Request) -> bool {
		buf: [32]u8
		value, lc: string
		ok: bool

		if value, ok = req.headers["upgrade"]; ok {
			lc = to_lower(value, buf[:])
			if lc == "websocket" {
				if value, ok = req.headers["connection"]; ok {
					lc = to_lower(value, buf[:])
					if lc == "upgrade" {
						return true
					}
				}
			}
		}
		return false
	}
	is_good_version :: proc(req: Request) -> bool {
		if version, has_version := req.headers["sec-websocket-version"]; has_version {
			if version == "13" {
				return true
			}
		}
		return false
	}
	has_handshake_key :: proc(req: Request) -> bool {
		_, ok := req.headers["sec-websocket-key"]
		return ok
	}
	handshake :: proc(req: Request, allocator: mem.Allocator) -> (res: Response) {
		buf: [256]u8
		hash: [sha1.DIGEST_SIZE]u8
		ctx: sha1.Context

		key := req.headers["sec-websocket-key"]
		copy(buf[:], transmute([]u8)key)

		uuid := WEBSOCKET_MAGIC
		copy(buf[len(key):], transmute([]u8)uuid)

		payload := buf[:len(key)+len(uuid)]

		sha1.init(&ctx)
		sha1.update(&ctx, payload)
		sha1.final(&ctx, hash[:])
		hash_b64, err := base64.encode_into_buf(buf[:], hash[:])
		if err != nil {
			res.status = 500
			return
		}

		res.headers = make(map[string]string, allocator)
		res.headers["Sec-WebSocket-Accept"] = strings.clone(string(hash_b64), allocator)
		res.headers["Upgrade"] = "websocket"
		res.headers["Connection"] = "Upgrade"
		res.is_websocket_handshake = true
		res.status = 101
		return
	}

	if !is_websocket_upgrade(req) do return {}, false, 0
	if !is_good_version(req) do return {}, false, 400
	if !has_handshake_key(req) do return {}, false, 400

	res = handshake(req, allocator)
	return res, true, res.status
}

// A non-allocating version of strings.to_lower
to_lower :: proc(s: string, buf: []u8) -> (res: string)  {
	b := strings.builder_from_bytes(buf)
	for r in s {
		strings.write_rune(&b, unicode.to_lower(r))
	}
	return strings.to_string(b)
}
