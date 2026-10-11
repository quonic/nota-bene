// Helpers for self-checking RV64 test programs.
//
// A test passes by calling Exit(0). A failed CHECK exits with the check's
// number, so a failing test reports exactly which assertion broke.

#define SYS_EXIT         0x000
#define SYS_DEBUG_LOG    0x001
#define SYS_ABI_VERSION  0x002
#define SYS_MEM_GROW     0x003
#define SYS_TIME_NOW     0x004
#define SYS_RANDOM       0x005
#define SYS_WAIT_EVENT   0x006
#define SYS_HANDLE_CLOSE 0x007
#define SYS_NODE_CREATE   0x100
#define SYS_NODE_SET_TEXT 0x101
#define SYS_NODE_SET_ATTR 0x102
#define SYS_NODE_APPEND   0x103
#define SYS_NODE_REMOVE   0x104
#define SYS_ROOT_SET      0x105

#define E_PERM  -1
#define E_INVAL -2
#define E_FAULT -3
#define E_BADH  -4
#define E_NOSYS -5
#define E_NOMEM -6
#define E_RANGE -8

// Fails with exit code \n unless register \reg equals the constant \val. Clobbers t6.
.macro CHECK n, reg, val
	li	t6, \val
	beq	\reg, t6, 9999f
	li	a0, \n
	li	a7, SYS_EXIT
	ecall
9999:
.endm

// Fails with exit code \n unless registers \a and \b are equal.
.macro CHECKR n, a, b
	beq	\a, \b, 9999f
	li	a0, \n
	li	a7, SYS_EXIT
	ecall
9999:
.endm

.macro FAIL n
	li	a0, \n
	li	a7, SYS_EXIT
	ecall
.endm

.macro PASS
	li	a0, 0
	li	a7, SYS_EXIT
	ecall
.endm

// a0 = syscall(nr, a0..a3 already set)
.macro SYSCALL nr
	li	a7, \nr
	ecall
.endm
