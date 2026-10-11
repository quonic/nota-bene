package proto

import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "core:encoding/cbor"
import "core:encoding/hex"
import "core:os"
import "core:strings"

HASH_SIZE :: 32

// What a server sends for a page: the page executable (its manifest is the
// ELF's .nb_manifest section) plus named assets, a content hash, and an
// optional publisher signature over that hash.
//
// The hash makes bundles content-addressed (a cached copy can be revalidated
// with Request.have); the signature, by a key separate from the server's
// transport key, lets mirrors serve a page while the browser still checks
// who published it.
Bundle :: struct {
	code:      []u8,
	assets:    map[string][]u8,
	hash:      []u8, // BLAKE2b-256 of the canonical encoding of code + assets
	publisher: []u8, // ed25519 public key, or empty
	sig:       []u8, // ed25519 signature of SIGN_CONTEXT || hash, or empty
}

// Domain separation, so a bundle signature can never be confused with
// anything else the publisher key signs.
SIGN_CONTEXT :: "NB/1 bundle\x00"

@(private)
Bundle_Content :: struct {
	code:   []u8,
	assets: map[string][]u8,
}

bundle_hash :: proc(code: []u8, assets: map[string][]u8) -> (h: [HASH_SIZE]u8, ok: bool) {
	content := Bundle_Content{code = code, assets = assets}
	data, err := cbor.marshal(content, cbor.ENCODE_FULLY_DETERMINISTIC, context.temp_allocator, context.temp_allocator)
	if err != nil {
		return
	}
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	blake2b.update(&ctx, data)
	blake2b.final(&ctx, h[:])
	return h, true
}

@(private)
signed_message :: proc(hash: []u8) -> []u8 {
	return transmute([]u8)strings.concatenate({SIGN_CONTEXT, string(hash)}, context.temp_allocator)
}

// Builds and encodes a bundle. `signer` may be nil.
bundle_encode :: proc(code: []u8, assets: map[string][]u8, signer: ^ed25519.Private_Key, allocator := context.allocator) -> (data: []u8, hash: [HASH_SIZE]u8, ok: bool) {
	hash = bundle_hash(code, assets) or_return
	b := Bundle{code = code, assets = assets, hash = hash[:]}
	pub: [ed25519.PUBLIC_KEY_SIZE]u8
	sig: [ed25519.SIGNATURE_SIZE]u8
	if signer != nil {
		ed25519.private_key_public_bytes(signer, pub[:])
		ed25519.sign(signer, signed_message(hash[:]), sig[:])
		b.publisher = pub[:]
		b.sig = sig[:]
	}
	enc, err := cbor.marshal(b, cbor.ENCODE_SMALL, allocator, context.temp_allocator)
	return enc, hash, err == nil
}

// Decodes and verifies a bundle: the hash must match the content, and a
// signature, if present, must verify against the included publisher key.
bundle_decode :: proc(data: []u8, allocator := context.allocator) -> (b: Bundle, err: Error) {
	if cbor.unmarshal(data, &b, {.Disallow_Streaming}, allocator, context.temp_allocator) != nil {
		bundle_destroy(&b, allocator)
		return {}, .Bad_Bundle
	}
	defer if err != nil {
		bundle_destroy(&b, allocator)
	}
	want, ok := bundle_hash(b.code, b.assets)
	if !ok || len(b.hash) != HASH_SIZE || string(b.hash) != string(want[:]) {
		return b, .Bad_Bundle
	}
	switch {
	case len(b.publisher) == 0 && len(b.sig) == 0:
	case len(b.publisher) == ed25519.PUBLIC_KEY_SIZE && len(b.sig) == ed25519.SIGNATURE_SIZE:
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, b.publisher) || !ed25519.verify(&pub, signed_message(b.hash), b.sig) {
			return b, .Bad_Bundle
		}
	case:
		return b, .Bad_Bundle
	}
	return b, nil
}

bundle_destroy :: proc(b: ^Bundle, allocator := context.allocator) {
	delete(b.code, allocator)
	for name, data in b.assets {
		delete(name, allocator)
		delete(data, allocator)
	}
	delete(b.assets)
	delete(b.hash, allocator)
	delete(b.publisher, allocator)
	delete(b.sig, allocator)
	b^ = {}
}

// Loads a publisher signing key (hex text), creating it if missing.
signing_key_load_or_create :: proc(path: string, key: ^ed25519.Private_Key) -> (created: bool, ok: bool) {
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		decoded, dok := hex.decode(transmute([]u8)strings.trim_space(string(data)), context.temp_allocator)
		if !dok || len(decoded) != ed25519.PRIVATE_KEY_SIZE {
			return false, false
		}
		return false, ed25519.private_key_set_bytes(key, decoded)
	}
	if !ed25519.private_key_generate(key) {
		return false, false
	}
	raw: [ed25519.PRIVATE_KEY_SIZE]u8
	ed25519.private_key_bytes(key, raw[:])
	return true, write_private_file(path, strings.concatenate({string(hex.encode(raw[:], context.temp_allocator)), "\n"}, context.temp_allocator))
}
