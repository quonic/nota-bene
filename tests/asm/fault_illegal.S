// An undefined opcode is an illegal instruction.
#include "test.h"
	.text
	.globl _start
_start:
	.word	0xFFFFFFFF
	PASS
