/* Freestanding stand-in for newlib's <stdlib.h>. See shim/shim.c.
 * stddef.h comes along because the demo sources expect NULL from here. */
#ifndef _SHIM_STDLIB_H
#define _SHIM_STDLIB_H

#include <stddef.h>

char *itoa(int value, char *str, int base);
int abs(int v);

#endif
