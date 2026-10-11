// Unbounded recursion runs into the guard page below the stack.
#include "test.h"
	.text
	.globl _start
_start:
	call	recurse
	PASS
recurse:
	addi	sp, sp, -64
	sd	ra, 56(sp)
	call	recurse
