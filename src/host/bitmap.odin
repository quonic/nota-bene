package host

import "core:image"
// Imported for their registrations: they teach image.load_from_bytes PNG and JPEG.
@(require) import "core:image/jpeg"
@(require) import "core:image/png"

import "../abi"

// Decoded pixels for an Image node: RGBA8, row-major, straight alpha.
// Pages hand over an encoded PNG or baseline JPEG with Image_Set_Data; the
// host decodes it once, and the browser draws these pixels.
Bitmap :: struct {
	width:   int,
	height:  int,
	pixels:  []u8,
	version: u64, // the paint_version when the pixels were set, for texture caches
}

// Decodes `data` into the Image node's bitmap, replacing what it had. Empty
// `data` clears it, so the node shows its placeholder again.
node_set_image :: proc(p: ^Page, h: abi.Handle, data: []u8) -> abi.Errno {
	n := node_get(p, h)
	if n == nil {
		return .BADH
	}
	if n.kind != .Image {
		return .INVAL
	}
	if len(data) > abi.MAX_IMAGE_BYTES {
		return .RANGE
	}
	bm: Bitmap
	if len(data) > 0 {
		err: abi.Errno
		if bm, err = bitmap_decode(data, p.allocator); err != .OK {
			return err
		}
		if p.bitmap_bytes - len(n.bitmap.pixels) + len(bm.pixels) > abi.MAX_IMAGE_TOTAL {
			delete(bm.pixels, p.allocator)
			return .NOMEM
		}
	}
	bitmap_free(p, n)
	p.bitmap_bytes += len(bm.pixels)
	p.paint_version += 1
	bm.version = p.paint_version
	n.bitmap = bm
	p.tree_version += 1 // the natural size may have changed
	return .OK
}

@(private)
bitmap_free :: proc(p: ^Page, n: ^Node) {
	p.bitmap_bytes -= len(n.bitmap.pixels)
	delete(n.bitmap.pixels, p.allocator)
	n.bitmap = {}
}

// Decodes a PNG or baseline JPEG into RGBA8. The size is read from the
// header first, so an oversized image is refused before anything is
// allocated for its pixels.
@(private)
bitmap_decode :: proc(data: []u8, allocator := context.allocator) -> (bm: Bitmap, err: abi.Errno) {
	#partial switch image.which_bytes(data) {
	case .PNG, .JPEG:
	case:
		return {}, .INVAL
	}

	info, ierr := image.load_from_bytes(data, {.info}, context.temp_allocator)
	defer image.destroy(info, context.temp_allocator)
	if ierr != nil || info == nil {
		return {}, .INVAL
	}
	if info.width <= 0 || info.height <= 0 {
		return {}, .INVAL
	}
	if info.width > abi.MAX_IMAGE_DIM || info.height > abi.MAX_IMAGE_DIM {
		return {}, .RANGE
	}

	img, lerr := image.load_from_bytes(data, {}, allocator)
	defer image.destroy(img, allocator)
	if lerr != nil || img == nil {
		return {}, .INVAL
	}
	if img.width != info.width || img.height != info.height {
		return {}, .INVAL
	}
	bytes_per := img.depth / 8
	if img.channels < 1 || img.channels > 4 || (img.depth != 8 && img.depth != 16) {
		return {}, .INVAL
	}
	src := img.pixels.buf[:]
	count := img.width * img.height
	if len(src) < count * img.channels * bytes_per {
		return {}, .INVAL
	}

	bm = {width = img.width, height = img.height}
	bm.pixels = make([]u8, count * 4, allocator)
	// The decoders leave 16-bit channels in native byte order; keep the high byte.
	hi := 0 if bytes_per == 1 else (1 when ODIN_ENDIAN == .Little else 0)
	for i in 0 ..< count {
		px := src[i * img.channels * bytes_per:]
		ch :: #force_inline proc(px: []u8, c, bytes_per, hi: int) -> u8 {
			return px[c * bytes_per + hi]
		}
		out := bm.pixels[i * 4:][:4]
		switch img.channels {
		case 1:
			g := ch(px, 0, bytes_per, hi)
			out[0], out[1], out[2], out[3] = g, g, g, 255
		case 2:
			g := ch(px, 0, bytes_per, hi)
			out[0], out[1], out[2], out[3] = g, g, g, ch(px, 1, bytes_per, hi)
		case 3:
			out[0], out[1], out[2], out[3] = ch(px, 0, bytes_per, hi), ch(px, 1, bytes_per, hi), ch(px, 2, bytes_per, hi), 255
		case 4:
			out[0], out[1], out[2], out[3] = ch(px, 0, bytes_per, hi), ch(px, 1, bytes_per, hi), ch(px, 2, bytes_per, hi), ch(px, 3, bytes_per, hi)
		}
	}
	return bm, .OK
}
