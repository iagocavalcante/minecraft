#ifndef COMPAT_H
#define COMPAT_H

#include <stdint.h>

#ifdef __APPLE__
  #include <libkern/OSByteOrder.h>
  #define bswap_16(x) OSSwapInt16(x)
  #define bswap_64(x) OSSwapInt64(x)
#elif defined(__linux__)
  #include <byteswap.h>
#else
  #define bswap_16(x) ((uint16_t)((((x) >> 8) & 0xFF) | (((x) & 0xFF) << 8)))
  #define bswap_64(x) \
    ((uint64_t)((((x) & 0x00000000000000FFULL) << 56) | \
                (((x) & 0x000000000000FF00ULL) << 40) | \
                (((x) & 0x0000000000FF0000ULL) << 24) | \
                (((x) & 0x00000000FF000000ULL) <<  8) | \
                (((x) & 0x000000FF00000000ULL) >>  8) | \
                (((x) & 0x0000FF0000000000ULL) >> 24) | \
                (((x) & 0x00FF000000000000ULL) >> 40) | \
                (((x) & 0xFF00000000000000ULL) >> 56)))
#endif

#endif /* COMPAT_H */
