package nb

import "base:runtime"

// A small general-purpose allocator over Mem_Grow.
//
// Blocks come in power-of-two size classes (32 B .. 1 GiB) with one free list
// per class. Memory is never returned to the browser; freed blocks are reused
// for later allocations of the same class. Simple and fast, at the cost of up
// to 2x internal fragmentation.
Heap :: struct {
	free:     [MAX_CLASS + 1]uintptr, // free list heads; the next pointer is stored in the block
	cur, end: uintptr,                // unused tail of the most recent Mem_Grow region
}

@(private) MIN_CLASS :: 5  // 32 bytes
@(private) MAX_CLASS :: 30 // 1 GiB
@(private) HEADER    :: 16
@(private) REFILL    :: 256 * 1024

// Sits directly before every pointer handed out.
@(private)
Block_Header :: struct {
	class:  u32,
	_:      u32,
	offset: u64, // from the start of the raw block to the user pointer
}
#assert(size_of(Block_Header) == HEADER)

heap_allocator :: proc "contextless" (h: ^Heap) -> runtime.Allocator {
	return {procedure = heap_allocator_proc, data = h}
}

@(private)
align_up :: #force_inline proc "contextless" (v, a: uintptr) -> uintptr {
	return (v + a - 1) &~ (a - 1)
}

@(private)
class_for :: proc "contextless" (need: uint) -> (int, bool) {
	c := MIN_CLASS
	for (uint(1) << uint(c)) < need {
		c += 1
		if c > MAX_CLASS {
			return 0, false
		}
	}
	return c, true
}

@(private)
heap_take :: proc "contextless" (h: ^Heap, class: int) -> uintptr {
	if b := h.free[class]; b != 0 {
		h.free[class] = (^uintptr)(b)^
		return b
	}
	size := uintptr(1) << uint(class)
	if h.end - h.cur < size {
		chunk := max(uint(size), REFILL)
		p, err := mem_grow(chunk)
		if err != .OK {
			return 0
		}
		base := uintptr(p)
		if base != h.end {
			h.cur = base // not contiguous with the previous region; abandon its tail
		}
		h.end = base + align_up(uintptr(chunk), 4096)
	}
	// Regions are page-aligned and every class is a multiple of 32, so blocks are 32-byte aligned.
	b := h.cur
	h.cur += size
	return b
}

@(private)
heap_alloc :: proc "contextless" (h: ^Heap, size, alignment: int, zero: bool) -> ([]byte, runtime.Allocator_Error) {
	align := uintptr(max(alignment, 16))
	need := uint(size) + HEADER + uint(align - 16)
	class, ok := class_for(need)
	if !ok {
		return nil, .Out_Of_Memory
	}
	raw := heap_take(h, class)
	if raw == 0 {
		return nil, .Out_Of_Memory
	}
	user := align_up(raw + HEADER, align)
	hdr := (^Block_Header)(user - HEADER)
	hdr.class = u32(class)
	hdr.offset = u64(user - raw)
	if zero {
		runtime.mem_zero(rawptr(user), size)
	}
	return ([^]byte)(rawptr(user))[:size], nil
}

@(private)
heap_free :: proc "contextless" (h: ^Heap, ptr: rawptr) {
	if ptr == nil {
		return
	}
	hdr := (^Block_Header)(uintptr(ptr) - HEADER)
	class := int(hdr.class)
	raw := uintptr(ptr) - uintptr(hdr.offset)
	(^uintptr)(raw)^ = h.free[class]
	h.free[class] = raw
}

@(private)
heap_capacity :: proc "contextless" (ptr: rawptr) -> int {
	hdr := (^Block_Header)(uintptr(ptr) - HEADER)
	return (1 << uint(hdr.class)) - int(hdr.offset)
}

heap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	h := (^Heap)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return heap_alloc(h, size, alignment, mode == .Alloc)

	case .Free:
		heap_free(h, old_memory)
		return nil, nil

	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return heap_alloc(h, size, alignment, mode == .Resize)
		}
		if size == 0 {
			heap_free(h, old_memory)
			return nil, nil
		}
		if size <= heap_capacity(old_memory) && uintptr(old_memory) % uintptr(max(alignment, 16)) == 0 {
			if mode == .Resize && size > old_size {
				runtime.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)
			}
			return ([^]byte)(old_memory)[:size], nil
		}
		new_mem, err := heap_alloc(h, size, alignment, false)
		if err != nil {
			return nil, err
		}
		n := min(old_size, size)
		runtime.mem_copy(raw_data(new_mem), old_memory, n)
		if mode == .Resize && size > n {
			runtime.mem_zero(rawptr(uintptr(raw_data(new_mem)) + uintptr(n)), size - n)
		}
		heap_free(h, old_memory)
		return new_mem, nil

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
