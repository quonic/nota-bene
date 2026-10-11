package host

import "core:strconv"

import "../abi"

// The size a Canvas node should have according to its attributes.
canvas_wanted_size :: proc(n: ^Node) -> (w, h: int) {
	dim :: proc(n: ^Node, attr: abi.Attr, default: int) -> int {
		s, ok := n.attrs[attr]
		if !ok {
			return default
		}
		v, vok := strconv.parse_int(s, 10)
		if !vok {
			return default
		}
		return clamp(v, 1, abi.MAX_CANVAS_DIM)
	}
	return dim(n, .Width, abi.DEFAULT_CANVAS_WIDTH), dim(n, .Height, abi.DEFAULT_CANVAS_HEIGHT)
}

// Makes sure the canvas buffer matches the node's attributes, reallocating
// (and clearing to transparent) when the size changed.
canvas_sync :: proc(p: ^Page, n: ^Node) -> ^Canvas {
	w, h := canvas_wanted_size(n)
	c := &n.canvas
	if c.width != w || c.height != h || c.pixels == nil {
		delete(c.pixels, p.allocator)
		c.pixels = make([]u8, w * h * 4, p.allocator)
		c.width, c.height = w, h
		p.paint_version += 1
	}
	return c
}

@(private)
canvas_node :: proc(p: ^Page, h: abi.Handle) -> (^Canvas, abi.Errno) {
	n := node_get(p, h)
	if n == nil {
		return nil, .BADH
	}
	if n.kind != .Canvas {
		return nil, .INVAL
	}
	return canvas_sync(p, n), .OK
}

@(private)
rgba_bytes :: proc "contextless" (rgba: u64) -> [4]u8 {
	return {u8(rgba >> 24), u8(rgba >> 16), u8(rgba >> 8), u8(rgba)}
}

canvas_fill_rect :: proc(p: ^Page, c: ^Canvas, x, y, w, h: i64, rgba: u64) {
	x0 := clamp(x, 0, i64(c.width))
	y0 := clamp(y, 0, i64(c.height))
	x1 := clamp(x + max(w, 0), 0, i64(c.width))
	y1 := clamp(y + max(h, 0), 0, i64(c.height))
	if x0 >= x1 || y0 >= y1 {
		return
	}
	px := rgba_bytes(rgba)
	for row in y0 ..< y1 {
		line := c.pixels[int(row) * c.width * 4:]
		for col in x0 ..< x1 {
			copy(line[int(col) * 4:][:4], px[:])
		}
	}
	p.paint_version += 1
}
