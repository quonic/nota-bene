package main

import "core:math"
import "core:os"
import "core:strings"

import ttf "vendor:sdl3/ttf"

import "../../layout"

// Font families tried in order; the first whose regular face exists wins.
// Missing bold/italic faces are synthesised by SDL_ttf. --font or NB_FONT
// override the regular face.
Family :: struct {
	regular, bold, italic, bold_italic: string,
}

FONT_FAMILIES :: []Family {
	{"/usr/share/fonts/google-noto/NotoSans-Regular.ttf", "/usr/share/fonts/google-noto/NotoSans-Bold.ttf", "/usr/share/fonts/google-noto/NotoSans-Italic.ttf", "/usr/share/fonts/google-noto/NotoSans-BoldItalic.ttf"},
	{"/usr/share/fonts/noto/NotoSans-Regular.ttf", "/usr/share/fonts/noto/NotoSans-Bold.ttf", "/usr/share/fonts/noto/NotoSans-Italic.ttf", "/usr/share/fonts/noto/NotoSans-BoldItalic.ttf"},
	{"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Italic.ttf", "/usr/share/fonts/truetype/noto/NotoSans-BoldItalic.ttf"},
	{"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Oblique.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-BoldOblique.ttf"},
	{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf"},
	{"/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf", "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf"},
	{"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf", "/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf", "/usr/share/fonts/liberation-sans/LiberationSans-Italic.ttf", "/usr/share/fonts/liberation-sans/LiberationSans-BoldItalic.ttf"},
	{"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf"},
	{`C:\Windows\Fonts\segoeui.ttf`, `C:\Windows\Fonts\segoeuib.ttf`, `C:\Windows\Fonts\segoeuii.ttf`, `C:\Windows\Fonts\segoeuiz.ttf`},
	{`C:\Windows\Fonts\arial.ttf`, `C:\Windows\Fonts\arialbd.ttf`, `C:\Windows\Fonts\ariali.ttf`, `C:\Windows\Fonts\arialbi.ttf`},
	{"/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Italic.ttf", "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf"},
	{"/Library/Fonts/Arial.ttf", "/Library/Fonts/Arial Bold.ttf", "/Library/Fonts/Arial Italic.ttf", "/Library/Fonts/Arial Bold Italic.ttf"},
}

MONO_FAMILIES :: []Family {
	{regular = "/usr/share/fonts/google-noto/NotoSansMono-Regular.ttf", bold = "/usr/share/fonts/google-noto/NotoSansMono-Bold.ttf"},
	{regular = "/usr/share/fonts/noto/NotoSansMono-Regular.ttf", bold = "/usr/share/fonts/noto/NotoSansMono-Bold.ttf"},
	{regular = "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf", bold = "/usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf"},
	{"/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono-Bold.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono-Oblique.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono-BoldOblique.ttf"},
	{"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-BoldOblique.ttf"},
	{"/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf", "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Bold.ttf", "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Italic.ttf", "/usr/share/fonts/liberation-mono-fonts/LiberationMono-BoldItalic.ttf"},
	{"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf", "/usr/share/fonts/truetype/liberation/LiberationMono-Italic.ttf", "/usr/share/fonts/truetype/liberation/LiberationMono-BoldItalic.ttf"},
	{`C:\Windows\Fonts\consola.ttf`, `C:\Windows\Fonts\consolab.ttf`, `C:\Windows\Fonts\consolai.ttf`, `C:\Windows\Fonts\consolaz.ttf`},
	{regular = "/System/Library/Fonts/Supplemental/Courier New.ttf", bold = "/System/Library/Fonts/Supplemental/Courier New Bold.ttf"},
}

Font_Key :: struct {
	px:        i32,
	bold:      bool,
	italic:    bool,
	mono:      bool,
	underline: bool, // drawn by draw_text, but kept in the key so cached text tracks style
}

// Resolved files for one family: an empty face means "synthesise from regular".
Faces :: struct {
	regular, bold, italic, bold_italic: cstring,
}

Fonts :: struct {
	sans:  Faces,
	mono:  Faces, // regular is nil if no monospace font was found (sans is used)
	scale: f32,   // physical pixels per layout pixel
	cache: map[Font_Key]^ttf.Font,
}

@(private="file")
resolve_family :: proc(f: Family) -> (faces: Faces, ok: bool) {
	if !os.exists(f.regular) {
		return
	}
	pick :: proc(path: string) -> cstring {
		return strings.clone_to_cstring(path) if path != "" && os.exists(path) else nil
	}
	return {pick(f.regular), pick(f.bold), pick(f.italic), pick(f.bold_italic)}, true
}

// Picks font files. Returns false if no text font can be found.
fonts_init :: proc(f: ^Fonts, override: string, scale: f32) -> bool {
	f.scale = scale
	f.cache = make(map[Font_Key]^ttf.Font)
	for fam in MONO_FAMILIES {
		if faces, ok := resolve_family(fam); ok {
			f.mono = faces
			break
		}
	}
	if override != "" {
		f.sans.regular = strings.clone_to_cstring(override)
		return os.exists(override)
	}
	for fam in FONT_FAMILIES {
		if faces, ok := resolve_family(fam); ok {
			f.sans = faces
			return true
		}
	}
	return false
}

fonts_clear :: proc(f: ^Fonts) {
	for _, font in f.cache {
		ttf.CloseFont(font)
	}
	clear(&f.cache)
}

fonts_destroy :: proc(f: ^Fonts) {
	fonts_clear(f)
	delete(f.cache)
	for faces in ([]^Faces{&f.sans, &f.mono}) {
		delete(faces.regular)
		delete(faces.bold)
		delete(faces.italic)
		delete(faces.bold_italic)
	}
}

font_key :: proc(f: ^Fonts, font: layout.Font) -> Font_Key {
	return {px = i32(math.round(font.size * f.scale)), bold = font.bold, italic = font.italic, mono = font.mono, underline = font.underline}
}

font_get :: proc(f: ^Fonts, font: layout.Font) -> ^ttf.Font {
	key := font_key(f, font)
	if cached, ok := f.cache[key]; ok {
		return cached
	}
	faces := f.mono if key.mono && f.mono.regular != nil else f.sans
	// Use the real face when the family has one; otherwise synthesise the style.
	path := faces.regular
	style: ttf.FontStyleFlags
	switch {
	case key.bold && key.italic && faces.bold_italic != nil:
		path = faces.bold_italic
	case key.bold && key.italic && faces.bold != nil:
		path = faces.bold
		style += {.ITALIC}
	case key.bold && faces.bold != nil:
		path = faces.bold
	case key.italic && faces.italic != nil:
		path = faces.italic
	case:
		if key.bold { style += {.BOLD} }
		if key.italic { style += {.ITALIC} }
	}
	if key.bold && key.italic && faces.bold_italic == nil && faces.bold == nil {
		style += {.BOLD, .ITALIC}
	}
	// Underlines are drawn by draw_text: the renderer text engine ignores the UNDERLINE style.
	handle := ttf.OpenFont(path, f32(max(key.px, 1)))
	if handle == nil {
		return nil
	}
	ttf.SetFontStyle(handle, style)
	f.cache[key] = handle
	return handle
}

// Wrap width in physical pixels for SDL_ttf (0 = only at newlines).
wrap_px :: proc(f: ^Fonts, wrap: f32) -> i32 {
	if wrap <= 0 {
		return 0
	}
	return max(i32(wrap * f.scale), 1)
}

// layout.Measure_Proc backed by SDL_ttf (HarfBuzz shaping).
measure_text :: proc(data: rawptr, text: string, font: layout.Font, wrap: f32) -> (w, h: f32) {
	f := (^Fonts)(data)
	handle := font_get(f, font)
	if handle == nil {
		return 0, font.size
	}
	if len(text) == 0 {
		return 0, f32(ttf.GetFontLineSkip(handle)) / f.scale
	}
	pw, ph: i32
	ttf.GetStringSizeWrapped(handle, raw_data(text), uint(len(text)), wrap_px(f, wrap), &pw, &ph)
	return math.ceil(f32(pw) / f.scale), math.ceil(f32(ph) / f.scale)
}
