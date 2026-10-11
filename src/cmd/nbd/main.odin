// nbd serves pages over NB/1: every connection is a Noise session, and every
// page is sent as a hashed (optionally signed) bundle.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../proto"
import "../../server"

USAGE :: `usage: nbd [options] [DIR]

Serves the page executables in DIR (default: current directory) over nb://.
"/" serves index.elf, and "/name" serves name.elf. Pages may also read
any other file in DIR as data, except the key files below.

options:
  --port N        port to listen on (default 4040; ports below 1024 need
                  privileges, e.g. sudo setcap cap_net_bind_service=+ep nbd)
  --bind ADDR     address to listen on (default 0.0.0.0)
  --key FILE      server identity key, created if missing (default nbd.key)
  --sign FILE     sign bundles with this publisher key, created if missing
  --quiet         do not log requests
  -h, --help      show this help
`

main :: proc() {
	root := "."
	port := proto.DEFAULT_PORT
	bind := "0.0.0.0"
	key_path := "nbd.key"
	sign_path := ""
	quiet := false

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		value :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 >= len(args) {
				fmt.eprintfln("nbd: %s needs a value", args[i^])
				os.exit(2)
			}
			i^ += 1
			return args[i^]
		}
		switch arg {
		case "-h", "--help":
			fmt.print(USAGE)
			return
		case "--port":
			v, ok := strconv.parse_int(value(args, &i), 10)
			if !ok || v < 1 || v > 65535 {
				fmt.eprintln("nbd: --port needs a number from 1 to 65535")
				os.exit(2)
			}
			port = v
		case "--bind":
			bind = value(args, &i)
		case "--key":
			key_path = value(args, &i)
		case "--sign":
			sign_path = value(args, &i)
		case "--quiet":
			quiet = true
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintf("nbd: unknown option %q\n\n%s", arg, USAGE)
				os.exit(2)
			}
			root = arg
		}
	}
	if !os.is_dir(root) {
		fmt.eprintfln("nbd: %s is not a directory", root)
		os.exit(2)
	}

	srv: server.Server
	srv.cfg.root = root
	srv.cfg.log = !quiet
	created, ok := proto.static_key_load_or_create(key_path, &srv.cfg.static_key)
	if !ok {
		fmt.eprintfln("nbd: cannot read or create the key file %s", key_path)
		os.exit(1)
	}
	if created {
		fmt.printfln("nbd: created a new server key in %s (keep it private)", key_path)
	}
	if sign_path != "" {
		screated, sok := proto.signing_key_load_or_create(sign_path, &srv.cfg.signer)
		if !sok {
			fmt.eprintfln("nbd: cannot read or create the signing key %s", sign_path)
			os.exit(1)
		}
		if screated {
			fmt.printfln("nbd: created a new publisher signing key in %s (keep it private)", sign_path)
		}
		srv.cfg.sign = true
	}
	// The key files may well sit in the served directory (both default to
	// it): never hand them out.
	exclude := make([dynamic]string)
	for path in ([]string{key_path, sign_path}) {
		if path == "" {
			continue
		}
		abs, err := os.get_absolute_path(path, context.allocator)
		if err != nil {
			fmt.eprintfln("nbd: cannot resolve %s: %v", path, err)
			os.exit(1)
		}
		append(&exclude, abs)
	}
	srv.cfg.exclude = exclude[:]

	addr := net.parse_address(bind)
	if addr == nil {
		fmt.eprintfln("nbd: %q is not an IP address", bind)
		os.exit(2)
	}
	if err := server.listen(&srv, {address = addr, port = port}); err != nil {
		fmt.eprintfln("nbd: cannot listen on %s port %d: %v", bind, port, err)
		if port < 1024 {
			fmt.eprintln("nbd: ports below 1024 need privileges: sudo setcap cap_net_bind_service=+ep nbd")
		}
		os.exit(1)
	}

	pub := proto.public_key_of(&srv.cfg.static_key)
	key := proto.key_string(pub, context.temp_allocator)
	fmt.printfln("nbd: serving %s on %s", root, net.endpoint_to_string(srv.endpoint, context.temp_allocator))
	fmt.printfln("nbd: server key %s", key)
	host := "localhost" if port == proto.DEFAULT_PORT else fmt.tprintf("localhost:%d", port)
	fmt.printfln("nbd: open nb://%s/ (or nb://%s@%s/ to skip trust-on-first-use)", host, key, host)
	server.serve(&srv)
}
