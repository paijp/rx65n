/* Minimal freestanding libc subset for the EnvisionDemo builds.
 *
 * The prebuilt GNU RX toolchains that can be had without a Renesas login
 * carry GCC and its multilibs but no newlib, so nothing here can be linked
 * against a real libc. Across the demos the only libc entry points actually
 * reached are strlen and itoa; the rest are here because they are the sort of
 * thing the next demo will want.
 *
 * itoa is not ISO C — it comes from newlib's stdlib.h, which is why the demo
 * sources declare it and expect it to exist.
 */
#include <stddef.h>

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) {
        p++;
    }
    return (size_t)(p - s);
}

void *memset(void *d, int c, size_t n)
{
    unsigned char *p = d;
    while (n--) {
        *p++ = (unsigned char)c;
    }
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) {
        *a++ = *b++;
    }
    return d;
}

int abs(int v)
{
    return v < 0 ? -v : v;
}

char *itoa(int value, char *str, int base)
{
    char tmp[34];
    int i = 0;
    int negative = 0;
    unsigned int v;

    if (base < 2 || base > 36) {
        str[0] = '\0';
        return str;
    }

    /* Only base 10 is signed, matching newlib. Negating through unsigned
     * keeps INT_MIN well defined. */
    if (value < 0 && base == 10) {
        negative = 1;
        v = (unsigned int)0 - (unsigned int)value;
    } else {
        v = (unsigned int)value;
    }

    do {
        unsigned int digit = v % (unsigned int)base;
        tmp[i++] = (char)(digit < 10 ? digit + '0' : digit - 10 + 'a');
        v /= (unsigned int)base;
    } while (v);

    if (negative) {
        tmp[i++] = '-';
    }

    {
        int j = 0;
        while (i) {
            str[j++] = tmp[--i];
        }
        str[j] = '\0';
    }
    return str;
}
