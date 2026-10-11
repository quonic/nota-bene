#!/usr/bin/env bash
# Builds the browser tools, example pages and tests.
#
#   ./build.sh                 build the tools, the example pages and build/site
#   ./build.sh tools           build nbrun, nbd and the nb browser
#   ./build.sh page DIR [OUT]  build the Odin page in DIR into an ELF (default build/<name>.elf)
#   ./build.sh fixtures        assemble the RV64 test programs
#   ./build.sh test            build everything and run all tests
#   ./build.sh clean
#
# Needs odin, clang (with the riscv64 target), ld.lld and llvm-objcopy; the
# browser also needs SDL3 and SDL3_ttf.
# Override any of them with ODIN=, CLANG=, LLD=, OBJCOPY=.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
ODIN="${ODIN:-odin}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"

RV_FLAGS=(--target=riscv64 -mabi=lp64d)
# Odin cannot link freestanding riscv64 executables itself, so pages are built
# as one static, non-PIC object without thread-locals and linked with ld.lld.
PAGE_ODIN_FLAGS=(-target:freestanding_riscv64 -build-mode:obj -use-single-module -no-thread-local -reloc-mode:static)
LINKER_SCRIPT="$ROOT/sdk/nb/page.ld"

log() { printf '==> %s\n' "$*"; }

build_tools() {
	mkdir -p "$BUILD"
	log "nbrun"
	"$ODIN" build "$ROOT/src/cmd/nbrun" -vet -o:speed -out:"$BUILD/nbrun"
	log "nbd"
	"$ODIN" build "$ROOT/src/cmd/nbd" -vet -o:speed -out:"$BUILD/nbd"
	build_browser
}

# Some distributions ship SDL3_ttf without its -devel package, so there is no
# libSDL3_ttf.so for the linker. Link against the runtime .so.0 through a
# private symlink instead (installing SDL3_ttf-devel makes this unnecessary).
sdl3_ttf_link_flags() {
	[[ "$(uname -s)" == Linux ]] || return 0
	local dir
	for dir in /usr/lib64 /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
		[[ -e "$dir/libSDL3_ttf.so" ]] && return 0
	done
	for dir in /usr/lib64 /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
		if [[ -e "$dir/libSDL3_ttf.so.0" ]]; then
			mkdir -p "$BUILD/lib"
			ln -sf "$dir/libSDL3_ttf.so.0" "$BUILD/lib/libSDL3_ttf.so"
			printf -- '-extra-linker-flags:-L%s' "$BUILD/lib"
			return 0
		fi
	done
	echo "build.sh: SDL3_ttf not found; install it (e.g. dnf install SDL3_ttf-devel)" >&2
	return 1
}

build_browser() {
	log "nb"
	local flags
	flags="$(sdl3_ttf_link_flags)"
	"$ODIN" build "$ROOT/src/cmd/nb" -vet -o:speed -out:"$BUILD/nb" ${flags:+"$flags"}
}

build_rt() {
	mkdir -p "$BUILD"
	"$CLANG" "${RV_FLAGS[@]}" -march=rv64gc -c "$ROOT/sdk/nb/rt.S" -o "$BUILD/rt.o"
}

embed_manifest() { # manifest.txt page.elf
	"$OBJCOPY" --add-section .nb_manifest="$1" --set-section-flags .nb_manifest=readonly,contents "$2"
}

build_page() { # dir [out.elf]
	local dir="${1:?usage: build.sh page DIR [OUT]}"
	dir="$(cd "$dir" && pwd)"
	local name
	name="$(basename "$dir")"
	local out="${2:-$BUILD/$name.elf}"
	log "page $name -> ${out#"$ROOT"/}"
	build_rt
	"$ODIN" build "$dir" "${PAGE_ODIN_FLAGS[@]}" -vet -out:"$BUILD/$name.o"
	"$LLD" -static -T "$LINKER_SCRIPT" "$BUILD/$name.o" "$BUILD/rt.o" -o "$out"
	if [[ -f "$dir/manifest.txt" ]]; then
		embed_manifest "$dir/manifest.txt" "$out"
	fi
}

build_examples() {
	for dir in "$ROOT"/examples/*/; do
		build_page "$dir"
	done
	# A site for nbd: build/site/index.elf is the hello page.
	mkdir -p "$BUILD/site"
	local elf
	for elf in "$BUILD"/*.elf; do
		cp "$elf" "$BUILD/site/"
	done
	cp "$BUILD/hello.elf" "$BUILD/site/index.elf"
	# Data files pages fetch at run time: examples/<name>/site/*.
	for dir in "$ROOT"/examples/*/site/; do
		[[ -d "$dir" ]] && cp -r "$dir". "$BUILD/site/"
	done
}

# Every test program is built twice: with compressed instructions (.c.elf)
# and without (.nc.elf), so both decoder paths run the same checks.
build_fixtures() {
	local out="$BUILD/tests"
	mkdir -p "$out"
	log "test fixtures"
	local src name variant march
	for src in "$ROOT"/tests/asm/*.S; do
		name="$(basename "$src" .S)"
		for variant in c nc; do
			march=rv64gc
			[[ $variant == nc ]] && march=rv64imafd
			"$CLANG" "${RV_FLAGS[@]}" -march=$march -I "$ROOT/tests/asm" -c "$src" -o "$out/$name.$variant.o"
			"$LLD" -static -T "$LINKER_SCRIPT" "$out/$name.$variant.o" -o "$out/$name.$variant.elf"
			if [[ -f "$ROOT/tests/asm/$name.manifest" ]]; then
				embed_manifest "$ROOT/tests/asm/$name.manifest" "$out/$name.$variant.elf"
			fi
		done
	done
	local m
	for m in ok future bad; do
		cp "$out/rv64i.c.elf" "$out/manifest_$m.elf"
		embed_manifest "$ROOT/tests/asm/manifest_$m.txt" "$out/manifest_$m.elf"
	done
}

run_tests() {
	build_tools
	build_examples
	build_fixtures
	local pkg
	for pkg in vm loader host layout proto search; do
		log "test $pkg"
		local defines=(-define:FIXTURES="$BUILD/tests")
		[[ $pkg == host || $pkg == proto ]] && defines+=(-define:BUILD_DIR="$BUILD")
		"$ODIN" test "$ROOT/tests/$pkg" -vet "${defines[@]}" -out:"$BUILD/test_$pkg"
	done
}

case "${1:-all}" in
	all)      build_tools; build_examples ;;
	tools)    build_tools ;;
	page)     shift; build_page "$@" ;;
	fixtures) build_fixtures ;;
	test)     run_tests ;;
	clean)    rm -rf "$BUILD" ;;
	*)        sed -n '2,12p' "$0"; exit 2 ;;
esac
