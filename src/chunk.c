#include "chunk.h"
#include "compat.h"
#include <string.h>

static uint8_t rand1[64] = {3, 2, 1, 2, 2, 2, 1, 1, 2, 3, 2, 2, 3, 2, 2, 1,
                            2, 1, 2, 2, 1, 2, 3, 2, 3, 2, 1, 2, 3, 2, 1, 2,
                            1, 2, 2, 3, 3, 3, 2, 1, 2, 1, 1, 1, 2, 3, 2, 1,
                            2, 1, 1, 1, 2, 1, 2, 3, 2, 2, 2, 3, 3, 3, 2, 2};

static uint8_t rand2[64] = {2,  7,  7, 1,  7, 6,  9,  12, 4,  6,  12, 3,  4,
                            5,  6,  4, 2,  5, 7,  7,  15, 12, 1,  9,  12, 2,
                            4,  1,  7, 11, 4, 15, 5,  9,  9,  10, 12, 4,  11,
                            11, 12, 5, 1,  1, 4,  10, 12, 15, 13, 16, 15, 13,
                            7,  10, 5, 10, 3, 13, 5,  7,  13, 10, 1,  14};

struct ChunkSection *generate_chunk_section(uint8_t *heightmap,
                                            int32_t chunk_y) {
  struct ChunkSection *chunk_section = enif_alloc(sizeof(struct ChunkSection));
  if (chunk_section == NULL) {
    return NULL;
  }
  chunk_section->y = chunk_y;
  for (uint32_t y = 0; y < 16; y++) {
    unsigned block_y = chunk_y * 16 + y;
    for (uint32_t z = 0; z < 16; z++) {
      for (uint32_t x = 0; x < 16; x++) {
        size_t block_number = (((y * 16) + z) * 16) + x;
        uint8_t m = rand1[(x * 16 + z + heightmap[z * 16 + x]) % 64];
        uint8_t n = rand2[(x * 16 + block_y + z + heightmap[x * 16 + z]) % 64];
        uint16_t type;
        if (block_y == m) {
          type = MC_BEDROCK;
        } else if ((int)block_y < (int)heightmap[z * 16 + x] - (int)m) {
          type = MC_STONE;
        } else if (block_y < heightmap[z * 16 + x]) {
          if (block_y < 64) {
            type = MC_SAND;
          } else {
            type = MC_DIRT;
          }
        } else if (block_y == heightmap[z * 16 + x]) {
          if (block_y < 64) {
            type = MC_SAND;
          } else {
            type = MC_GRASS;
          }
        } else if (block_y < 64) {
          type = MC_STILL_WATER;
        } else if (block_y == (unsigned)heightmap[z * 16 + x] + 1 && n > 13) {
          if (block_y == 64) {
            type = MC_AIR;
          } else {
            type = MC_TALL_GRASS;
          }
        } else {
          type = MC_AIR;
        }
        chunk_section->blocks[block_number].type = type;
        chunk_section->blocks[block_number].block_light = 0;
        chunk_section->blocks[block_number].sky_light = 0xF;
      }
    }
  }

  return chunk_section;
}

ERL_NIF_TERM serialize_chunk_section(ErlNifEnv *env,
                                     struct ChunkSection *chunk_section) {
  ERL_NIF_TERM chunk_section_term;
  const uint8_t bits_per_block = 13;
  const uint64_t value_mask = (1UL << bits_per_block) - 1;
  const uint8_t palette = 0;
  const uint16_t data_array_length = 16 * 16 * 16 * bits_per_block / 64;
  const size_t total_size_bytes =
      sizeof(uint8_t)                         // bits_per_block
      + sizeof(uint8_t)                       // palette
      + sizeof(uint16_t)                      // data_array_length (VarInt, 2B)
      + sizeof(uint64_t) * data_array_length  // data
      + sizeof(uint8_t) * (16 * 16 * 16);     // block light and sky light
  uint8_t *raw = (uint8_t *)enif_make_new_binary(env, total_size_bytes,
                                                 &chunk_section_term);

  // Fill the chunk with air
  memset((void *)raw, 0, total_size_bytes);

  *raw++ = bits_per_block;
  *raw++ = palette;

  // data_array_length = 832 as a VarInt is the two bytes 0xC0 0x06. Written
  // explicitly rather than via a byte-swapped uint16_t store, which was both a
  // strict-aliasing violation and correct only on little-endian hosts.
  *raw++ = 0xC0;
  *raw++ = 0x06;

  // Pack into a properly aligned local buffer. `raw` points 4 bytes into the
  // binary, so a uint64_t* onto it would be misaligned (UB / SIGBUS on some
  // targets).
  uint64_t data[16 * 16 * 16 * 13 / 64];
  memset(data, 0, sizeof(data));

  for (uint32_t y = 0; y < 16; y++) {
    for (uint32_t z = 0; z < 16; z++) {
      for (uint32_t x = 0; x < 16; x++) {
        size_t block_number = (((y * 16) + z) * 16) + x;
        size_t start_long = (block_number * bits_per_block) / 64;
        size_t start_offset = (block_number * bits_per_block) % 64;
        size_t end_long = ((block_number + 1) * bits_per_block - 1) / 64;

        uint64_t value = chunk_section->blocks[block_number].type;
        value &= value_mask;

        data[start_long] |= (value << start_offset);

        if (start_long != end_long) {
          data[end_long] = (value >> (64 - start_offset));
        }
      }
    }
  }

  // Emit each long big-endian, byte by byte, so output is identical regardless
  // of host endianness.
  for (uint16_t i = 0; i < data_array_length; i++) {
    uint64_t v = data[i];
    for (int b = 7; b >= 0; b--) {
      *raw++ = (uint8_t)(v >> (b * 8));
    }
  }

  // Block Light
  for (uint32_t y = 0; y < 16; y++) {
    for (uint32_t z = 0; z < 16; z++) {
      for (uint32_t x = 0; x < 16; x += 2) {
        size_t block_number = (((y * 16) + z) * 16) + x;
        uint8_t light1 = chunk_section->blocks[block_number].block_light;
        uint8_t light2 = chunk_section->blocks[block_number + 1].block_light;
        *raw++ = light1 | (light2 << 4);
      }
    }
  }

  // Sky Light
  for (uint32_t y = 0; y < 16; y++) {
    for (uint32_t z = 0; z < 16; z++) {
      for (uint32_t x = 0; x < 16; x += 2) {
        size_t block_number = (((y * 16) + z) * 16) + x;
        uint8_t light1 = chunk_section->blocks[block_number].sky_light;
        uint8_t light2 = chunk_section->blocks[block_number + 1].sky_light;
        *raw++ = light1 | (light2 << 4);
      }
    }
  }

  return chunk_section_term;
}
