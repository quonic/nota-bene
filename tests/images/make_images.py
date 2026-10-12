# Generates the image fixtures and example images with GIMP's batch mode.
#
#   ./build.sh images
#
# runs this file through GIMP 3's Python console:
#
#   NB_ROOT=<repo> gimp-console -i -n --quit --batch-interpreter=python-fu-eval -b - < make_images.py
#
# The outputs are committed, so building and testing do not need GIMP. Every
# fixture is drawn pixel by pixel; tests/host/host_test.odin expects exactly
# these values.
import os

from gi.repository import Gegl, Gimp, Gio

ROOT = os.environ["NB_ROOT"]
PDB = Gimp.get_pdb()

# The 4x3 colour pattern. The last pixel is half transparent in the formats
# that have alpha, and opaque red in the others.
COLOR = [
	[(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)],
	[(0, 0, 0), (255, 255, 0), (0, 255, 255), (255, 0, 255)],
	[(128, 128, 128), (64, 32, 16), (200, 100, 50), (255, 0, 0, 128)],
]

# The 4x3 grey pattern, last pixel likewise.
GRAY = [
	[0, 255, 128, 64],
	[32, 16, 8, 1],
	[200, 100, 50, (255, 128)],
]


# Hex, because Gegl reads rgba() components as 0..1 and clamps anything larger.
def color(r, g, b, a=255):
	return Gegl.Color.new(f"#{r:02x}{g:02x}{b:02x}{a:02x}")


def new_image(w, h, base, precision=Gimp.Precision.U8_NON_LINEAR, alpha=True):
	img = Gimp.Image.new_with_precision(w, h, base, precision)
	if base == Gimp.ImageBaseType.GRAY:
		kind = Gimp.ImageType.GRAYA_IMAGE if alpha else Gimp.ImageType.GRAY_IMAGE
	else:
		kind = Gimp.ImageType.RGBA_IMAGE if alpha else Gimp.ImageType.RGB_IMAGE
	layer = Gimp.Layer.new(img, "pixels", w, h, kind, 100, Gimp.LayerMode.NORMAL)
	img.insert_layer(layer, None, 0)
	if alpha:
		layer.edit_clear()
	return img, layer


def pattern_image(base, alpha, precision=Gimp.Precision.U8_NON_LINEAR):
	img, layer = new_image(4, 3, base, precision, alpha)
	for y in range(3):
		for x in range(4):
			if base == Gimp.ImageBaseType.GRAY:
				v = GRAY[y][x]
				g, a = v if isinstance(v, tuple) else (v, 255)
				c = color(g, g, g, a if alpha else 255)
			else:
				r, g, b, *rest = COLOR[y][x]
				c = color(r, g, b, rest[0] if rest and alpha else 255)
			layer.set_pixel(x, y, c)
	return img


def path(rel):
	p = os.path.join(ROOT, rel)
	os.makedirs(os.path.dirname(p), exist_ok=True)
	return Gio.File.new_for_path(p)


def export_png(img, rel, fmt="auto"):
	proc = PDB.lookup_procedure("file-png-export")
	cfg = proc.create_config()
	cfg.set_property("image", img)
	cfg.set_property("file", path(rel))
	cfg.set_property("format", fmt)
	# Only the pixels: no metadata chunks that would make the outputs differ
	# between runs.
	for name in ["bkgd", "offs", "phys", "time", "include-exif", "include-iptc", "include-xmp",
			"include-color-profile", "include-thumbnail", "include-comment"]:
		cfg.set_property(name, False)
	cfg.set_property("save-transparent", True)
	result = proc.run(cfg)
	assert result.index(0) == Gimp.PDBStatusType.SUCCESS, rel
	img.delete()


def export_jpeg(img, rel, progressive):
	proc = PDB.lookup_procedure("file-jpeg-export")
	cfg = proc.create_config()
	cfg.set_property("image", img)
	cfg.set_property("file", path(rel))
	cfg.set_property("quality", 0.95)
	cfg.set_property("optimize", False)
	cfg.set_property("progressive", progressive)
	cfg.set_property("baseline", not progressive)
	for name in ["include-exif", "include-iptc", "include-xmp", "include-color-profile",
			"include-thumbnail", "include-comment"]:
		cfg.set_property(name, False)
	result = proc.run(cfg)
	assert result.index(0) == Gimp.PDBStatusType.SUCCESS, rel
	img.delete()


# 32x32 in four 16x16 quadrants: red, green / blue, white. Big enough
# blocks that the colours survive JPEG's chroma subsampling at their centres.
def quadrants():
	img, layer = new_image(32, 32, Gimp.ImageBaseType.RGB, alpha=False)
	for (x, y), c in [((0, 0), color(255, 0, 0)), ((16, 0), color(0, 255, 0)),
			((0, 16), color(0, 0, 255)), ((16, 16), color(255, 255, 255))]:
		img.select_rectangle(Gimp.ChannelOps.REPLACE, x, y, 16, 16)
		Gimp.context_set_foreground(c)
		layer.edit_fill(Gimp.FillType.FOREGROUND)
	Gimp.Selection.none(img)
	return img


RGB, GRAYB = Gimp.ImageBaseType.RGB, Gimp.ImageBaseType.GRAY

export_png(pattern_image(RGB, True), "tests/images/rgba.png")
export_png(pattern_image(RGB, False), "tests/images/rgb.png")
export_png(pattern_image(GRAYB, False), "tests/images/gray.png")
export_png(pattern_image(GRAYB, True), "tests/images/graya.png")
export_png(pattern_image(RGB, True, Gimp.Precision.U16_NON_LINEAR), "tests/images/rgba16.png")

indexed = pattern_image(RGB, False)
indexed.convert_indexed(Gimp.ConvertDitherType.NONE, Gimp.ConvertPaletteType.GENERATE, 16, False, True, "")
export_png(indexed, "tests/images/indexed.png")

export_jpeg(quadrants(), "tests/images/baseline.jpg", progressive=False)
export_jpeg(quadrants(), "tests/images/progressive.jpg", progressive=True)

wide, _ = new_image(5000, 1, RGB, alpha=False)
export_png(wide, "tests/images/wide.png")


# Example images.

def photo():
	w, h = 320, 200
	img, layer = new_image(w, h, RGB, alpha=False)
	Gimp.context_set_foreground(color(0x1E, 0x3A, 0x8A))
	Gimp.context_set_background(color(0xF5, 0x9E, 0x0B))
	layer.edit_gradient_fill(Gimp.GradientType.LINEAR, 0, False, 1, 0, True, 0, 0, w, h)
	for x, y, d, c in [(40, 40, 90, color(0xFD, 0xE6, 0x8A)), (200, 90, 70, color(0x10, 0xB9, 0x81)),
			(130, 120, 50, color(0xF8, 0xFA, 0xFC))]:
		img.select_ellipse(Gimp.ChannelOps.REPLACE, x, y, d, d)
		Gimp.context_set_foreground(c)
		layer.edit_fill(Gimp.FillType.FOREGROUND)
	img.select_rectangle(Gimp.ChannelOps.REPLACE, 0, 170, w, 30)
	Gimp.context_set_foreground(color(0x0F, 0x17, 0x2A))
	layer.edit_fill(Gimp.FillType.FOREGROUND)
	Gimp.Selection.none(img)
	return img


def icon():
	img, layer = new_image(16, 16, RGB)
	img.select_ellipse(Gimp.ChannelOps.REPLACE, 1, 1, 14, 14)
	Gimp.context_set_foreground(color(0xDC, 0x26, 0x26))
	layer.edit_fill(Gimp.FillType.FOREGROUND)
	img.select_ellipse(Gimp.ChannelOps.REPLACE, 5, 5, 6, 6)
	Gimp.context_set_foreground(color(0xFF, 0xFF, 0xFF))
	layer.edit_fill(Gimp.FillType.FOREGROUND)
	Gimp.Selection.none(img)
	return img


export_jpeg(photo(), "examples/images/photo.jpg", progressive=False)
export_png(icon(), "examples/images/icon.png")
