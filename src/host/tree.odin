package host

import "core:fmt"
import "core:strings"

import "../abi"

// The semantic view tree. Pages build it through syscalls; the browser owns
// layout and drawing. Links between nodes are handles, never pointers, so a
// node can be closed without leaving dangling references behind.
Node :: struct {
	kind:        abi.Node_Kind,
	parent:      abi.Handle,
	first_child: abi.Handle,
	last_child:  abi.Handle,
	prev:        abi.Handle,
	next:        abi.Handle,
	text:        string,
	attrs:       map[abi.Attr]string,
	canvas:      Canvas, // Canvas nodes only

	// Input nodes only: the selection as byte offsets into `text` (see
	// abi.Selection). `selection_set` means the page placed it with
	// Input_Set_Selection and the browser has not applied it yet.
	anchor, caret: int,
	selection_set: bool,
}

// Pixel storage for a Canvas node: RGBA8, row-major. Allocated on first use
// and resized (cleared) when the Width/Height attributes change.
Canvas :: struct {
	width:  int,
	height: int,
	pixels: []u8,
}

node_get :: proc(p: ^Page, h: abi.Handle) -> ^Node {
	e := handle_get(&p.handles, h)
	if e == nil {
		return nil
	}
	if n, ok := &e.obj.(Node); ok {
		return n
	}
	return nil
}

node_create :: proc(p: ^Page, kind: abi.Node_Kind) -> (abi.Handle, bool) {
	return handle_alloc(&p.handles, Node{kind = kind, attrs = make(map[abi.Attr]string, p.allocator)})
}

// Unlinks `h` from its parent. A no-op for detached nodes.
node_detach :: proc(p: ^Page, h: abi.Handle) {
	n := node_get(p, h)
	if n == nil || n.parent == abi.INVALID_HANDLE {
		return
	}
	parent := node_get(p, n.parent)
	if prev := node_get(p, n.prev); prev != nil {
		prev.next = n.next
	} else {
		parent.first_child = n.next
	}
	if next := node_get(p, n.next); next != nil {
		next.prev = n.prev
	} else {
		parent.last_child = n.prev
	}
	n.parent, n.prev, n.next = {}, {}, {}
	p.tree_version += 1
}

// Reports whether `ancestor` is `h` or one of its ancestors.
node_is_ancestor :: proc(p: ^Page, ancestor, h: abi.Handle) -> bool {
	for cur := h; cur != abi.INVALID_HANDLE; {
		if cur == ancestor {
			return true
		}
		n := node_get(p, cur)
		if n == nil {
			return false
		}
		cur = n.parent
	}
	return false
}

// Appends `child` as the last child of `parent`, moving it if it already has a parent.
node_append :: proc(p: ^Page, parent_h, child_h: abi.Handle) -> abi.Errno {
	parent := node_get(p, parent_h)
	child := node_get(p, child_h)
	if parent == nil || child == nil {
		return .BADH
	}
	if child_h == p.root || node_is_ancestor(p, child_h, parent_h) {
		return .INVAL
	}
	node_detach(p, child_h)
	child.parent = parent_h
	child.prev = parent.last_child
	if last := node_get(p, parent.last_child); last != nil {
		last.next = child_h
	} else {
		parent.first_child = child_h
	}
	parent.last_child = child_h
	p.tree_version += 1
	return .OK
}

node_set_text :: proc(p: ^Page, h: abi.Handle, text: string) -> abi.Errno {
	n := node_get(p, h)
	if n == nil {
		return .BADH
	}
	delete(n.text, p.allocator)
	n.text = strings.clone(text, p.allocator)
	if n.kind in abi.EDITABLE {
		// Kept where they still fit, as the browser's own field does.
		n.anchor = snap_offset(n.text, n.anchor)
		n.caret = snap_offset(n.text, n.caret)
	}
	p.tree_version += 1
	return .OK
}

// Clamps `pos` into `s` and back onto a rune boundary.
@(private)
snap_offset :: proc(s: string, pos: int) -> int {
	pos := pos
	pos = clamp(pos, 0, len(s))
	for pos > 0 && pos < len(s) && s[pos] & 0xC0 == 0x80 {
		pos -= 1
	}
	return pos
}

node_set_attr :: proc(p: ^Page, h: abi.Handle, attr: abi.Attr, value: string) -> abi.Errno {
	n := node_get(p, h)
	if n == nil {
		return .BADH
	}
	if old, ok := n.attrs[attr]; ok {
		delete(old, p.allocator)
		delete_key(&n.attrs, attr)
	}
	if len(value) > 0 {
		n.attrs[attr] = strings.clone(value, p.allocator)
	}
	p.tree_version += 1
	return .OK
}

// Closes a node: it is detached, its children become detached roots (their
// handles stay valid), and its storage is freed.
node_close :: proc(p: ^Page, h: abi.Handle) {
	n := node_get(p, h)
	if n == nil {
		return
	}
	node_detach(p, h)
	for c := n.first_child; c != abi.INVALID_HANDLE; {
		child := node_get(p, c)
		next := child.next
		child.parent, child.prev, child.next = {}, {}, {}
		c = next
	}
	node_free_storage(p, n)
	if p.root == h {
		p.root = abi.INVALID_HANDLE
	}
	handle_release(&p.handles, h)
	p.tree_version += 1
}

@(private)
node_free_storage :: proc(p: ^Page, n: ^Node) {
	delete(n.text, p.allocator)
	for _, v in n.attrs {
		delete(v, p.allocator)
	}
	delete(n.attrs)
	delete(n.canvas.pixels, p.allocator)
}

// Writes the tree rooted at the page root as indented text, e.g.
//
//   box direction="column"
//     heading level="1" "Hello"
dump_tree :: proc(p: ^Page, sb: ^strings.Builder) {
	if p.root == abi.INVALID_HANDLE {
		strings.write_string(sb, "(no root)\n")
		return
	}
	dump_node(p, sb, p.root, 0)
}

@(private)
dump_node :: proc(p: ^Page, sb: ^strings.Builder, h: abi.Handle, depth: int) {
	n := node_get(p, h)
	if n == nil {
		return
	}
	for _ in 0 ..< depth {
		strings.write_string(sb, "  ")
	}
	kind_name, _ := fmt.enum_value_to_string(n.kind)
	strings.write_string(sb, strings.to_lower(kind_name, context.temp_allocator))
	for attr in abi.Attr {
		if v, ok := n.attrs[attr]; ok {
			attr_name, _ := fmt.enum_value_to_string(attr)
			fmt.sbprintf(sb, " %s=%q", strings.to_lower(attr_name, context.temp_allocator), v)
		}
	}
	if len(n.text) > 0 {
		fmt.sbprintf(sb, " %q", n.text)
	}
	strings.write_byte(sb, '\n')
	for c := n.first_child; c != abi.INVALID_HANDLE; {
		dump_node(p, sb, c, depth + 1)
		c = node_get(p, c).next
	}
}
