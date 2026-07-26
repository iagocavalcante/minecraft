#include "compat.h"
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "biome.h"
#include "chunk.h"
#include "erl_nif.h"
#include "perlin.h"

#define max(X, Y) (((X) > (Y)) ? (X) : (Y))

static ErlNifResourceType *CHUNK_RES_TYPE;

static ERL_NIF_TERM set_random_seed(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifSInt64 seed64;

  // Accept a full 64-bit Minecraft world seed, signed (enif_get_int would
  // silently fail outside the 32-bit range). Fold it to the 32-bit PRNG seed.
  if (!enif_get_int64(env, argv[0], &seed64)) {
    return enif_make_badarg(env);
  }

  uint64_t u = (uint64_t)seed64;
  unsigned seed = (unsigned)(u ^ (u >> 32));
  initialize_random(seed);

  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM serialize_chunk(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk)) {
    return enif_make_atom(env, "error");
  }

  ERL_NIF_TERM chunk_sections[16];
  for (int i = 0; i < chunk->num_sections; i++) {
    chunk_sections[i] = serialize_chunk_section(env, chunk->chunk_sections[i]);
  }

  ERL_NIF_TERM chunk_term =
      enif_make_list_from_array(env, chunk_sections, (int)chunk->num_sections);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), chunk_term);
}

static ERL_NIF_TERM get_chunk_coordinates(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk)) {
    return enif_make_atom(env, "error");
  }

  ERL_NIF_TERM coords = enif_make_tuple2(env, enif_make_int(env, chunk->x),
                                         enif_make_int(env, chunk->z));

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), coords);
}

static ERL_NIF_TERM num_chunk_sections(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk)) {
    return enif_make_atom(env, "error");
  }

  return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                          enif_make_int(env, chunk->num_sections));
}

static ERL_NIF_TERM chunk_biome_data(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk)) {
    return enif_make_atom(env, "error");
  }

  ERL_NIF_TERM term;
  uint8_t *biome_data = enif_make_new_binary(env, 256, &term);
  memcpy(biome_data, chunk->biome, 256);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

static ERL_NIF_TERM chunk_heightmap(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk)) {
    return enif_make_atom(env, "error");
  }

  ERL_NIF_TERM term;
  uint8_t *heightmap = enif_make_new_binary(env, 256, &term);
  memcpy(heightmap, chunk->heightmap, 256);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

// Raw block types of one chunk section as a binary of 4096 uint16 (little
// endian), in the generator's YZX order: index = (y * 16 + z) * 16 + x.
static ERL_NIF_TERM section_block_types(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  (void)argc;
  struct Chunk *chunk = NULL;
  int index;
  if (!enif_get_resource(env, argv[0], CHUNK_RES_TYPE, (void **)&chunk) ||
      !enif_get_int(env, argv[1], &index) || index < 0 ||
      index >= chunk->num_sections) {
    return enif_make_atom(env, "error");
  }

  struct ChunkSection *section = chunk->chunk_sections[index];
  ERL_NIF_TERM term;
  uint8_t *out = enif_make_new_binary(env, 4096 * 2, &term);
  for (size_t i = 0; i < 4096; i++) {
    uint16_t type = section->blocks[i].type;
    out[i * 2] = (uint8_t)(type & 0xFF);
    out[i * 2 + 1] = (uint8_t)(type >> 8);
  }

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

static ERL_NIF_TERM generate_chunk(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  int chunk_x, chunk_z;

  if (!enif_get_int(env, argv[0], &chunk_x) ||
      !enif_get_int(env, argv[1], &chunk_z)) {
    return enif_make_badarg(env);
  }

  struct Chunk *chunk =
      enif_alloc_resource(CHUNK_RES_TYPE, sizeof(struct Chunk));
  if (chunk == NULL) {
    return enif_make_badarg(env);
  }
  // Zero before anything can fail: the GC destructor may run on this resource,
  // and it must never see uninitialized pointers or a garbage section count.
  memset(chunk, 0, sizeof(struct Chunk));

  uint8_t *heightmap = (uint8_t *)enif_alloc(sizeof(uint8_t) * 16 * 16);
  uint8_t *biome = (uint8_t *)enif_alloc(sizeof(uint8_t) * 16 * 16);
  if (heightmap == NULL || biome == NULL) {
    enif_free(heightmap);
    enif_free(biome);
    enif_release_resource(chunk);
    return enif_make_badarg(env);
  }

  chunk->x = chunk_x;
  chunk->z = chunk_z;
  chunk->heightmap = heightmap;
  chunk->biome = biome;

  double start_x = chunk_x * 16.0;
  double start_z = chunk_z * 16.0;
  unsigned max_height = 0;
  double x = start_x;
  double z = start_z;
  for (size_t i = 0; i < 16; z++, i++) {
    x = start_x;
    for (size_t j = 0; j < 16; x++, j++) {
      unsigned h = 125 * octave_perlin(x + 0.483, 28.237, z + 0.483, 6, 0.4);
      if (h > 255) h = 255;
      if (h > max_height) max_height = h;
      heightmap[i * 16 + j] = (uint8_t)h;
      biome[i * 16 + j] = get_biome(x, z);
    }
  }

  // Figure out how many chunk sections we need to output. Use max_height + 2 so
  // that the tall-grass block placed at heightmap + 1 always lands in a section
  // we actually generate (avoids dropping grass when max_height % 16 == 15).
  int ns = (int)ceil((max_height + 2) / 16.0);
  if (ns < 4) ns = 4;
  if (ns > 16) ns = 16;
  uint8_t num_chunk_sections = (uint8_t)ns;
  chunk->num_sections = num_chunk_sections;

  for (uint8_t i = 0; i < num_chunk_sections; i++) {
    struct ChunkSection *section = generate_chunk_section(heightmap, i);
    if (section == NULL) {
      // Record how many sections are live so the destructor frees exactly those.
      chunk->num_sections = i;
      enif_release_resource(chunk);
      return enif_make_badarg(env);
    }
    chunk->chunk_sections[i] = section;
  }

  // Publish the resource only once it is fully initialized.
  ERL_NIF_TERM chunk_term = enif_make_resource(env, chunk);
  enif_release_resource(chunk);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), chunk_term);
}

/*
 * Methods for dealing with Chunk resource types.
 */

// Called whenever Erlang destructs a Chunk resource
void chunk_res_destructor(ErlNifEnv *env, void *resource) {
  (void)env;
  struct Chunk *chunk = (struct Chunk *)resource;
  // Tolerant of partially-initialized resources: enif_free(NULL) is a no-op and
  // num_sections is zeroed before any section pointer is set.
  enif_free((void *)chunk->heightmap);
  enif_free((void *)chunk->biome);
  for (uint8_t i = 0; i < chunk->num_sections; i++) {
    enif_free((void *)chunk->chunk_sections[i]);
  }
}

int nif_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  CHUNK_RES_TYPE = enif_open_resource_type(
      env, NULL, "chunk", chunk_res_destructor, ERL_NIF_RT_CREATE, NULL);
  if (CHUNK_RES_TYPE == NULL) {
    return -1;
  }
  // Seed the noise tables so terrain isn't all-zero if set_random_seed is never
  // called (e.g. in tests that call generate_chunk directly).
  initialize_random(0);
  return 0;
}

/*
 * NIF Boilerplate.
 */

static ErlNifFunc nif_funcs[] = {
    // {erl_function_name, erl_function_arity, c_function, flags}
    {"chunk_biome_data", 1, chunk_biome_data, 0},
    {"chunk_heightmap", 1, chunk_heightmap, 0},
    {"section_block_types", 2, section_block_types, 0},
    {"generate_chunk", 2, generate_chunk, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"get_chunk_coordinates", 1, get_chunk_coordinates, 0},
    {"num_chunk_sections", 1, num_chunk_sections, 0},
    {"serialize_chunk", 1, serialize_chunk, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"set_random_seed", 1, set_random_seed, 0}};

ERL_NIF_INIT(Elixir.Minecraft.NIF, nif_funcs, nif_load, NULL, NULL, NULL)
