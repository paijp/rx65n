/* Freestanding stand-in for newlib's <string.h>. See shim/shim.c. */
#ifndef _SHIM_STRING_H
#define _SHIM_STRING_H

#include <stddef.h>

size_t strlen(const char *s);
void *memset(void *d, int c, size_t n);
void *memcpy(void *d, const void *s, size_t n);

#endif
