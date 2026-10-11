# Instruction set

Pages execute **RV64GC** in user mode: RV64I plus the M, A, F, D and C
extensions, and Zicsr for the floating-point CSRs. This is the standard
RISC-V application profile, so any off-the-shelf RV64 compiler can produce
pages.

## Why RISC-V

- **Real toolchains for free.** Odin, Clang/C, Zig and Rust all target RV64.
  Disassemblers, debuggers and compliance suites already exist.
- **Simple to interpret.** Fixed field positions, and only six immediate
  formats. Compressed instructions expand 1:1 into 32-bit ones, so the
  executor has a single decoder (`src/vm/compressed.odin`).
- **Syscalls are a convention, not a design problem.** `ecall` with the
  number in `a7` and arguments in `a0..a5` is how Linux does it on RISC-V,
  and it is what compilers already emit.

## Why GC and not a smaller subset

The toolchain spike (Odin `dev-2026-10`, LLVM 22) settled this:

- Odin's `riscv64` target **requires** the F extension. Building with
  `-target-features:-f` fails with `missing required target feature "f"`.
  Freestanding has no soft-float runtime, so D is needed too.
- The default target emits compressed instructions, and `-target-features:-c`
  does not remove them. 73% of the instructions in `examples/hello` are
  compressed.
- A is cheap to support on a single hart and keeps `core:sync` working.

The ISA tests build every fixture twice, with C (`.c.elf`) and without
(`.nc.elf`), so both decode paths run the same checks.

## Implementation notes

| Area | Behaviour |
|---|---|
| Registers | `x0..x31` as `u64`; `f0..f31` as raw bits, with singles NaN-boxed. |
| Memory | Little-endian. Misaligned loads and stores are allowed. Every access is bounds- and permission-checked per 4 KiB page. |
| `fence`, `fence.i` | No-ops (single hart, no caches). |
| `ecall` | The VM stops with `Ecall` and the pc already past the instruction. The host writes the result to `a0` and resumes. |
| `ebreak` | The VM stops with `Ebreak` and the pc at the instruction. The host currently kills the page; reserved for a debugger. |
| LR/SC | A single reservation. Any SC clears it. AMOs must be naturally aligned (`Misaligned_Atomic` otherwise). |
| CSRs | `fflags`, `frm` and `fcsr` are read/write. `cycle` and `instret` are read-only and both return the retired-instruction count. `time` is **not implemented** (illegal instruction): pages get no high-resolution clock. |
| Float arithmetic | Uses host IEEE-754 round-to-nearest-even regardless of `rm`. |
| Float → int | Honours `rm` (RNE, RTZ, RDN, RUP, RMM, DYN) with RISC-V saturation semantics. This is where compilers depend on rounding: casts use RTZ. |
| NaNs | Arithmetic results are always the canonical NaN, so results are bit-identical on every host. |
| `fflags` | NV and DZ are raised. NX is raised by float→int conversions. OF and UF are not tracked. |
| Privileged ISA | None. `mret`, `wfi`, `sfence.vma` and the M/S-mode CSRs are illegal instructions. |

## Faults

A fault stops the page permanently. `vm.describe_fault` produces messages
such as:

```
store to 0x10000 not permitted (pc 0x10008, 0x0002a023)
illegal instruction 0x0000 at pc 0x12340 (unimp: an Odin runtime trap, e.g. a failed bounds check)
```

Odin's runtime traps with `unimp` (a failed bounds check, for example),
because freestanding has nowhere to print. `nb.start` installs an assertion
handler, so `assert` and `panic` instead log a message and exit with
`nb.PANIC_EXIT_CODE` (101).

To see the instruction at a faulting pc:

```
llvm-objdump -d --start-address=0x12340 --stop-address=0x12350 page.elf
```
