// Stores into the text segment must fault (W^X).
#include "test.h"
	.text
	.globl _start
_start:
	la	t0, _start
	sw	zero, 0(t0)
	PASS
