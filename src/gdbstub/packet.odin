package gdbstub

// GDB Remote Serial Protocol framing: `$payload#xx`, where xx is the sum of
// the payload bytes mod 256 in hex. The receiver answers `+` (good) or `-`
// (resend) unless no-ack mode is on. A lone 0x03 byte is an interrupt.

// Packets longer than this are refused; it is also the PacketSize we advertise.
PACKET_SIZE :: 0x4000

Input :: enum {
	None,      // byte consumed, nothing complete yet
	Packet,    // Decoder.body holds a packet with a good checksum
	Bad,       // a packet arrived with a bad checksum or was too long
	Ack,       // '+'
	Nak,       // '-': resend the last packet
	Interrupt, // 0x03 outside a packet
}

Decoder :: struct {
	state:    enum u8 {Idle, Body, Check_Hi, Check_Lo},
	body:     [dynamic]u8,
	sum:      u8,
	check:    u8,
	overflow: bool,
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.body)
	d^ = {}
}

// Feeds one byte. When it returns .Packet the payload is in d.body until the
// next call.
decode_byte :: proc(d: ^Decoder, b: u8) -> Input {
	switch d.state {
	case .Idle:
		switch b {
		case '$':
			start_packet(d)
		case '+':
			return .Ack
		case '-':
			return .Nak
		case 0x03:
			return .Interrupt
		}
	case .Body:
		switch b {
		case '#':
			d.state = .Check_Hi
		case '$':
			// The previous packet was cut short; this one replaces it.
			start_packet(d)
		case:
			d.sum += b
			if len(d.body) < PACKET_SIZE {
				append(&d.body, b)
			} else {
				d.overflow = true
			}
		}
	case .Check_Hi:
		v, ok := hex_digit(b)
		d.check = v << 4
		d.state = .Check_Lo
		if !ok {
			d.overflow = true // reuse the flag: the packet is bad either way
		}
	case .Check_Lo:
		v, ok := hex_digit(b)
		d.check |= v
		d.state = .Idle
		if !ok || d.overflow || d.check != d.sum {
			return .Bad
		}
		return .Packet
	}
	return .None
}

@(private)
start_packet :: proc(d: ^Decoder) {
	clear(&d.body)
	d.sum = 0
	d.overflow = false
	d.state = .Body
}

// Appends `$payload#xx` to out. `$`, `#`, `}` and `*` in the payload are
// escaped as `}` followed by the byte xor 0x20, which GDB undoes for the
// binary replies (qXfer) where they can occur; other replies never contain them.
encode_packet :: proc(out: ^[dynamic]u8, payload: string) {
	append(out, '$')
	sum: u8
	for i in 0 ..< len(payload) {
		b := payload[i]
		if b == '$' || b == '#' || b == '}' || b == '*' {
			append(out, '}')
			sum += '}'
			b ~= 0x20
		}
		append(out, b)
		sum += b
	}
	append(out, u8('#'), HEX[sum >> 4], HEX[sum & 15])
}

@(private, rodata)
HEX := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

hex_digit :: proc(b: u8) -> (u8, bool) {
	switch b {
	case '0' ..= '9': return b - '0', true
	case 'a' ..= 'f': return b - 'a' + 10, true
	case 'A' ..= 'F': return b - 'A' + 10, true
	}
	return 0, false
}
