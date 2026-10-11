// Loads from address 0 must fault: the first 64 KiB are unmapped.
#include "test.h"
	.text
	.globl _start
_start:
	ld	a0, 0(zero)
	PASS
