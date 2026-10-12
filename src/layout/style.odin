package layout

import "core:strconv"

import "../abi"
import "../host"

Color :: [4]u8

Direction :: enum u8 {
	Column,
	Row,
}

Font :: struct {
	size:      f32, // px
	bold:      bool,
	italic:    bool,
	mono:      bool,
	underline: bool,
}

// Resolved presentation of one node: browser defaults for its kind, then the
// page's attribute hints on top.
Style :: struct {
	direction:  Direction,
	gap:        f32,
	padding:    f32,
	indent:     f32, // extra left padding (lists)
	font:       Font,
	color:      Color,
	background: Color, // alpha 0 = none
	border:     Color, // alpha 0 = none
	width:      Maybe(f32),
	height:     Maybe(f32),
	bullet:     bool,
}

Theme :: struct {
	text:        Color,
	link:        Color,
	page:        Color,
	button:      Color,
	button_edge: Color,
	input:       Color,
	input_edge:  Color,
	focus:       Color,
	placeholder: Color,
	code_bg:     Color,
	base_font:   f32,
}

DEFAULT_THEME :: Theme {
	text        = {0x1F, 0x23, 0x28, 0xFF},
	link        = {0x1A, 0x56, 0xDB, 0xFF},
	page        = {0xFF, 0xFF, 0xFF, 0xFF},
	button      = {0xEC, 0xEE, 0xF2, 0xFF},
	button_edge = {0xB4, 0xB9, 0xC2, 0xFF},
	input       = {0xFF, 0xFF, 0xFF, 0xFF},
	input_edge  = {0x8C, 0x93, 0x9D, 0xFF},
	focus       = {0x1A, 0x56, 0xDB, 0xFF},
	placeholder = {0xE4, 0xE7, 0xEB, 0xFF},
	code_bg     = {0xEF, 0xF1, 0xF4, 0xFF},
	base_font   = 16,
}

HEADING_SIZES := [6]f32{32, 26, 22, 19, 17, 16}

MAX_PX :: 10_000

@(private)
parse_px :: proc(s: string) -> (f32, bool) {
	v, ok := strconv.parse_f32(s)
	if !ok || v != v {
		return 0, false
	}
	return clamp(v, 0, MAX_PX), true
}

// Parses "#rgb", "#rrggbb" or "#rrggbbaa".
parse_color :: proc(s: string) -> (color: Color, ok: bool) {
	if len(s) < 2 || s[0] != '#' {
		return {}, false
	}
	hex := s[1:]
	nib :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9': return c - '0', true
		case 'a' ..= 'f': return c - 'a' + 10, true
		case 'A' ..= 'F': return c - 'A' + 10, true
		}
		return 0, false
	}
	out := Color{0, 0, 0, 0xFF}
	switch len(hex) {
	case 3:
		for i in 0 ..< 3 {
			v := nib(hex[i]) or_return
			out[i] = v * 17
		}
	case 6, 8:
		for i in 0 ..< len(hex) / 2 {
			hi := nib(hex[2 * i]) or_return
			lo := nib(hex[2 * i + 1]) or_return
			out[i] = hi << 4 | lo
		}
	case:
		return {}, false
	}
	return out, true
}

style_for :: proc(n: ^host.Node, theme: Theme) -> Style {
	st := Style {
		font  = {size = theme.base_font},
		color = theme.text,
	}
	switch n.kind {
	case .Box, .Text, .Paragraph, .Image, .Canvas:
	case .Heading:
		level := 1
		if s, ok := n.attrs[.Level]; ok {
			if v, vok := strconv.parse_int(s, 10); vok {
				level = clamp(v, 1, 6)
			}
		}
		st.font.size = HEADING_SIZES[level - 1]
		st.font.bold = true
	case .Link:
		st.color = theme.link
		st.font.underline = true
	case .Button:
		st.padding = 8
		st.background = theme.button
		st.border = theme.button_edge
	case .Input, .Text_Area:
		st.padding = 8
		st.background = theme.input
		st.border = theme.input_edge
		st.width = 260
	case .List:
		st.indent = 22
		st.gap = 4
	case .List_Item:
		st.bullet = true
	case .Emphasis:
		st.font.italic = true
	case .Strong:
		st.font.bold = true
	case .Code:
		st.font.mono = true
		st.background = theme.code_bg
	}

	if s, ok := n.attrs[.Direction]; ok {
		st.direction = .Row if s == "row" else .Column
	}
	if s, ok := n.attrs[.Gap]; ok {
		st.gap = parse_px(s) or_else st.gap
	}
	if s, ok := n.attrs[.Padding]; ok {
		st.padding = parse_px(s) or_else st.padding
	}
	if s, ok := n.attrs[.Font_Size]; ok {
		if v, vok := parse_px(s); vok {
			st.font.size = clamp(v, 6, 200)
		}
	}
	if s, ok := n.attrs[.Color]; ok {
		st.color = parse_color(s) or_else st.color
	}
	if s, ok := n.attrs[.Background]; ok {
		st.background = parse_color(s) or_else st.background
	}
	if s, ok := n.attrs[.Width]; ok {
		if v, vok := parse_px(s); vok {
			st.width = v
		}
	}
	if s, ok := n.attrs[.Height]; ok {
		if v, vok := parse_px(s); vok {
			st.height = v
		}
	}
	return st
}

is_inline_kind :: proc "contextless" (k: abi.Node_Kind) -> bool {
	#partial switch k {
	case .Text, .Link, .Emphasis, .Strong, .Code:
		return true
	}
	return false
}

// The style of an inline node inside a run of text: it inherits the
// surrounding font and colour, then applies its own kind and attributes.
inline_style :: proc(n: ^host.Node, parent: Style, theme: Theme) -> Style {
	st := parent
	st.background = {}
	st.border = {}
	st.padding, st.gap, st.indent = 0, 0, 0
	st.width, st.height = nil, nil
	st.bullet = false
	#partial switch n.kind {
	case .Link:
		st.color = theme.link
		st.font.underline = true
	case .Emphasis:
		st.font.italic = true
	case .Strong:
		st.font.bold = true
	case .Code:
		st.font.mono = true
		st.background = theme.code_bg
	}
	if s, ok := n.attrs[.Color]; ok {
		st.color = parse_color(s) or_else st.color
	}
	if s, ok := n.attrs[.Background]; ok {
		st.background = parse_color(s) or_else st.background
	}
	if s, ok := n.attrs[.Font_Size]; ok {
		if v, vok := parse_px(s); vok {
			st.font.size = clamp(v, 6, 200)
		}
	}
	return st
}
