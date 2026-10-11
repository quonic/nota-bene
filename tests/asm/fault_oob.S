// Stores past the end of guest memory must fault, not touch host memory.
#include "test.h"
	.text
	.globl _start
_start:
	li	t0, 0x7FFFFFFFFFFF0000
	sd	zero, 0(t0)
	PASS
