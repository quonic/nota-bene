// Never terminates; the host's instruction budget must stop it.
	.text
	.globl _start
_start:
	j	_start
