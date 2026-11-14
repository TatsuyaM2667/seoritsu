// tree-sitter's wasm store API (src/wasm_store.h) on top of our own interpreter
// (wasm.zig) instead of wasmtime. Language copying is adapted from tree-sitter's
// wasm_store.c (MIT, Copyright (c) 2018-2024 Max Brunsfeld and contributors).

#include "tree_sitter/api.h"
#include "alloc.h"
#include "array.h"
#include "language.h"
#include "lexer.h"
#include "parser.h"
#include "wasm_store.h"

#include <stdlib.h>
#include <string.h>

typedef struct { uint32_t memory_size, memory_align, table_size, table_align; } TswDylink;
typedef struct TswInst TswInst;
TswInst *tsw_load(const uint8_t *bytes, size_t len, const char *name, uint32_t *lang_addr, TswDylink *dl);
uint8_t *tsw_memory(TswInst *);
uint32_t tsw_lexer_address(TswInst *);
uint32_t tsw_serialization_address(TswInst *);
void tsw_start(TswInst *, TSLexer *);
bool tsw_call(TswInst *, uint32_t slot, const uint32_t *args, uint32_t nargs, uint32_t *result);

#define array_len(a) (sizeof(a) / sizeof(a[0]))
typedef Array(char) StringData;

typedef struct {
  uint32_t abi_version;
  uint32_t symbol_count;
  uint32_t alias_count;
  uint32_t token_count;
  uint32_t external_token_count;
  uint32_t state_count;
  uint32_t large_state_count;
  uint32_t production_id_count;
  uint32_t field_count;
  uint16_t max_alias_sequence_length;
  int32_t parse_table;
  int32_t small_parse_table;
  int32_t small_parse_table_map;
  int32_t parse_actions;
  int32_t symbol_names;
  int32_t field_names;
  int32_t field_map_slices;
  int32_t field_map_entries;
  int32_t symbol_metadata;
  int32_t public_symbol_map;
  int32_t alias_map;
  int32_t alias_sequences;
  int32_t lex_modes;
  int32_t lex_fn;
  int32_t keyword_lex_fn;
  TSSymbol keyword_capture_token;
  struct {
    int32_t states;
    int32_t symbol_map;
    int32_t create;
    int32_t destroy;
    int32_t scan;
    int32_t serialize;
    int32_t deserialize;
  } external_scanner;
  int32_t primary_state_ids;
  int32_t name;
  int32_t reserved_words;
  uint16_t max_reserved_word_set_size;
  uint32_t supertype_count;
  int32_t supertype_symbols;
  int32_t supertype_map_slices;
  int32_t supertype_map_entries;
  TSLanguageMetadata metadata;
} LanguageInWasmMemory;

// One interpreter instance per language, shared by every parser of that language
// (the editor parses on one thread, one document at a time).
typedef struct {
  TswInst *inst;
  uint32_t lex_main, lex_keyword;
  uint32_t scanner_create, scanner_destroy, scanner_scan, scanner_serialize, scanner_deserialize;
  uint32_t external_states;
  char *symbol_name_buffer, *field_name_buffer;
} LanguageWasmModule;

struct TSWasmStore {
  TSLexer *lexer;
  LanguageWasmModule *cur;
  bool has_error;
  uint32_t language_count;
};

static void *copy(const void *data, size_t size) {
  void *result = ts_malloc(size);
  memcpy(result, data, size);
  return result;
}

static void *copy_unsized_static_array(
  const uint8_t *data,
  int32_t start_address,
  const int32_t all_addresses[],
  size_t address_count
) {
  int32_t end_address = 0;
  for (unsigned i = 0; i < address_count; i++) {
    if (all_addresses[i] > start_address) {
      if (!end_address || all_addresses[i] < end_address) {
        end_address = all_addresses[i];
      }
    }
  }

  if (!end_address) return NULL;
  size_t size = end_address - start_address;
  void *result = ts_malloc(size);
  memcpy(result, &data[start_address], size);
  return result;
}

static void *copy_strings(
  const uint8_t *data,
  int32_t array_address,
  size_t count,
  StringData *string_data
) {
  const char **result = ts_malloc(count * sizeof(char *));
  for (unsigned i = 0; i < count; i++) {
    int32_t address;
    memcpy(&address, &data[array_address + i * sizeof(address)], sizeof(address));
    if (address == 0) {
      result[i] = (const char *)-1;
    } else {
      const uint8_t *string = &data[address];
      uint32_t len = strlen((const char *)string);
      result[i] = (const char *)(uintptr_t)string_data->size;
      array_extend(string_data, len + 1, string);
    }
  }
  for (unsigned i = 0; i < count; i++) {
    if (result[i] == (const char *)-1) {
      result[i] = NULL;
    } else {
      result[i] = string_data->contents + (uintptr_t)result[i];
    }
  }
  return result;
}

static void *copy_string(
  const uint8_t *data,
  int32_t address
) {
  const char *string = (const char *)&data[address];
  size_t len = strlen(string);
  char *result = ts_malloc(len + 1);
  memcpy(result, string, len + 1);
  return result;
}


static bool sentinel_lex_fn(TSLexer *lexer, TSStateId state) {
  (void)lexer; (void)state;
  return false;
}

TSWasmStore *ts_wasm_store_new(TSWasmEngine *engine, TSWasmError *error) {
  (void)engine;
  if (error) error->kind = TSWasmErrorKindNone;
  return ts_calloc(1, sizeof(TSWasmStore));
}

void ts_wasm_store_delete(TSWasmStore *self) {
  ts_free(self);
}

size_t ts_wasm_store_language_count(const TSWasmStore *self) {
  return self->language_count;
}

const TSLanguage *ts_wasm_store_load_language(
  TSWasmStore *self,
  const char *language_name,
  const char *wasm,
  uint32_t wasm_len,
  TSWasmError *wasm_error
) {
  wasm_error->kind = TSWasmErrorKindNone;
  uint32_t language_address = 0;
  TswDylink dl;
  TswInst *inst = tsw_load((const uint8_t *)wasm, wasm_len, language_name, &language_address, &dl);
  if (!inst) {
    wasm_error->kind = TSWasmErrorKindInstantiate;
    wasm_error->message = NULL;
    return NULL;
  }

  // Copy all of the static data out of the language object in wasm memory,
  // constructing a native language object.
  LanguageInWasmMemory wasm_language;
  const uint8_t *memory = tsw_memory(inst);
  memcpy(&wasm_language, &memory[language_address], sizeof(LanguageInWasmMemory));

  bool has_supertypes =
    wasm_language.abi_version > LANGUAGE_VERSION_WITH_RESERVED_WORDS &&
    wasm_language.supertype_count > 0;

  int32_t addresses[] = {
    wasm_language.parse_table,
    wasm_language.small_parse_table,
    wasm_language.small_parse_table_map,
    wasm_language.parse_actions,
    wasm_language.symbol_names,
    wasm_language.field_names,
    wasm_language.field_map_slices,
    wasm_language.field_map_entries,
    wasm_language.symbol_metadata,
    wasm_language.public_symbol_map,
    wasm_language.alias_map,
    wasm_language.alias_sequences,
    wasm_language.lex_modes,
    wasm_language.lex_fn,
    wasm_language.keyword_lex_fn,
    wasm_language.primary_state_ids,
    wasm_language.name,
    wasm_language.reserved_words,
    has_supertypes ? wasm_language.supertype_symbols : 0,
    has_supertypes ? wasm_language.supertype_map_entries : 0,
    has_supertypes ? wasm_language.supertype_map_slices : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.states : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.symbol_map : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.create : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.destroy : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.scan : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.serialize : 0,
    wasm_language.external_token_count > 0 ? wasm_language.external_scanner.deserialize : 0,
    language_address,
  };
  uint32_t address_count = array_len(addresses);

  TSLanguage *language = ts_calloc(1, sizeof(TSLanguage));
  StringData symbol_name_buffer = array_new();
  StringData field_name_buffer = array_new();

  *language = (TSLanguage) {
    .abi_version = wasm_language.abi_version,
    .symbol_count = wasm_language.symbol_count,
    .alias_count = wasm_language.alias_count,
    .token_count = wasm_language.token_count,
    .external_token_count = wasm_language.external_token_count,
    .state_count = wasm_language.state_count,
    .large_state_count = wasm_language.large_state_count,
    .production_id_count = wasm_language.production_id_count,
    .field_count = wasm_language.field_count,
    .supertype_count = wasm_language.supertype_count,
    .max_alias_sequence_length = wasm_language.max_alias_sequence_length,
    .keyword_capture_token = wasm_language.keyword_capture_token,
    .metadata = wasm_language.metadata,
    .parse_table = copy(
      &memory[wasm_language.parse_table],
      wasm_language.large_state_count * wasm_language.symbol_count * sizeof(uint16_t)
    ),
    .parse_actions = copy_unsized_static_array(
      memory,
      wasm_language.parse_actions,
      addresses,
      address_count
    ),
    .symbol_names = copy_strings(
      memory,
      wasm_language.symbol_names,
      wasm_language.symbol_count + wasm_language.alias_count,
      &symbol_name_buffer
    ),
    .symbol_metadata = copy(
      &memory[wasm_language.symbol_metadata],
      (wasm_language.symbol_count + wasm_language.alias_count) * sizeof(TSSymbolMetadata)
    ),
    .public_symbol_map = copy(
      &memory[wasm_language.public_symbol_map],
      (wasm_language.symbol_count + wasm_language.alias_count) * sizeof(TSSymbol)
    ),
    .lex_modes = copy(
      &memory[wasm_language.lex_modes],
      wasm_language.state_count * sizeof(TSLexerMode)
    ),
  };

  if (language->field_count > 0 && language->production_id_count > 0) {
    language->field_map_slices = copy(
      &memory[wasm_language.field_map_slices],
      wasm_language.production_id_count * sizeof(TSMapSlice)
    );

    // Determine the number of field map entries by finding the greatest index
    // in any of the slices.
    uint32_t field_map_entry_count = 0;
    for (uint32_t i = 0; i < wasm_language.production_id_count; i++) {
      TSMapSlice slice = language->field_map_slices[i];
      uint32_t slice_end = slice.index + slice.length;
      if (slice_end > field_map_entry_count) {
        field_map_entry_count = slice_end;
      }
    }

    language->field_map_entries = copy(
      &memory[wasm_language.field_map_entries],
      field_map_entry_count * sizeof(TSFieldMapEntry)
    );
    language->field_names = copy_strings(
      memory,
      wasm_language.field_names,
      wasm_language.field_count + 1,
      &field_name_buffer
    );
  }

  if (has_supertypes) {
    language->supertype_symbols = copy(
      &memory[wasm_language.supertype_symbols],
      wasm_language.supertype_count * sizeof(TSSymbol)
    );

    // Determine the number of supertype map slices by finding the greatest
    // supertype ID.
    int largest_supertype = 0;
    for (unsigned i = 0; i < language->supertype_count; i++) {
      TSSymbol supertype = language->supertype_symbols[i];
      if (supertype > largest_supertype) {
        largest_supertype = supertype;
      }
    }

    language->supertype_map_slices = copy(
      &memory[wasm_language.supertype_map_slices],
      (largest_supertype + 1) * sizeof(TSMapSlice)
    );

    TSSymbol last_supertype = language->supertype_symbols[language->supertype_count - 1];
    TSMapSlice last_slice = language->supertype_map_slices[last_supertype];
    uint32_t supertype_map_entry_count = last_slice.index + last_slice.length;

    language->supertype_map_entries = copy(
      &memory[wasm_language.supertype_map_entries],
      supertype_map_entry_count * sizeof(char *)
    );
  }

  if (language->max_alias_sequence_length > 0 && language->production_id_count > 0) {
    // The alias map contains symbols, alias counts, and aliases, terminated by a null symbol.
    int32_t alias_map_size = 0;
    for (;;) {
      TSSymbol symbol;
      memcpy(&symbol, &memory[wasm_language.alias_map + alias_map_size], sizeof(symbol));
      alias_map_size += sizeof(TSSymbol);
      if (symbol == 0) break;
      uint16_t value_count;
      memcpy(&value_count, &memory[wasm_language.alias_map + alias_map_size], sizeof(value_count));
      alias_map_size += sizeof(uint16_t);
      alias_map_size += value_count * sizeof(TSSymbol);
    }
    language->alias_map = copy(
      &memory[wasm_language.alias_map],
      alias_map_size
    );
    language->alias_sequences = copy(
      &memory[wasm_language.alias_sequences],
      wasm_language.production_id_count * wasm_language.max_alias_sequence_length * sizeof(TSSymbol)
    );
  }

  if (language->state_count > language->large_state_count) {
    uint32_t small_state_count = wasm_language.state_count - wasm_language.large_state_count;
    language->small_parse_table_map = copy(
      &memory[wasm_language.small_parse_table_map],
      small_state_count * sizeof(uint32_t)
    );
    language->small_parse_table = copy_unsized_static_array(
      memory,
      wasm_language.small_parse_table,
      addresses,
      address_count
    );
  }

  if (language->abi_version >= LANGUAGE_VERSION_WITH_PRIMARY_STATES) {
    language->primary_state_ids = copy(
      &memory[wasm_language.primary_state_ids],
      wasm_language.state_count * sizeof(TSStateId)
    );
  }

  if (language->abi_version >= LANGUAGE_VERSION_WITH_RESERVED_WORDS) {
    language->name = copy_string(memory, wasm_language.name);
    language->reserved_words = copy(
        &memory[wasm_language.reserved_words],
        wasm_language.max_reserved_word_set_size * sizeof(TSSymbol)
    );
    language->max_reserved_word_set_size = wasm_language.max_reserved_word_set_size;
  }

  if (language->external_token_count > 0) {
    language->external_scanner.symbol_map = copy(
      &memory[wasm_language.external_scanner.symbol_map],
      wasm_language.external_token_count * sizeof(TSSymbol)
    );
    language->external_scanner.states = (void *)(uintptr_t)wasm_language.external_scanner.states;
  }

  LanguageWasmModule *module = ts_calloc(1, sizeof(LanguageWasmModule));
  *module = (LanguageWasmModule) {
    .inst = inst,
    .lex_main = wasm_language.lex_fn,
    .lex_keyword = wasm_language.keyword_lex_fn,
    .scanner_create = wasm_language.external_scanner.create,
    .scanner_destroy = wasm_language.external_scanner.destroy,
    .scanner_scan = wasm_language.external_scanner.scan,
    .scanner_serialize = wasm_language.external_scanner.serialize,
    .scanner_deserialize = wasm_language.external_scanner.deserialize,
    .external_states = wasm_language.external_scanner.states,
    .symbol_name_buffer = symbol_name_buffer.contents,
    .field_name_buffer = field_name_buffer.contents,
  };
  // the lex functions are unused for wasm languages: mark the language and keep our data there
  language->lex_fn = sentinel_lex_fn;
  language->keyword_lex_fn = (bool (*)(TSLexer *, TSStateId))module;
  self->language_count++;
  return language;
}

static inline LanguageWasmModule *module_of(const TSLanguage *language) {
  return (LanguageWasmModule *)language->keyword_lex_fn;
}

bool ts_wasm_store_start(TSWasmStore *self, TSLexer *lexer, const TSLanguage *language) {
  self->lexer = lexer;
  self->cur = module_of(language);
  self->has_error = false;
  tsw_start(self->cur->inst, lexer); // also resets the heap
  return true;
}

void ts_wasm_store_reset(TSWasmStore *self) {
  if (self->cur) tsw_start(self->cur->inst, NULL);
  self->lexer = NULL;
  self->cur = NULL;
  self->has_error = false;
}

bool ts_wasm_store_has_error(const TSWasmStore *self) {
  return self->has_error;
}

static uint32_t call(TSWasmStore *self, uint32_t slot, const uint32_t *args, uint32_t n) {
  uint32_t result = 0;
  if (!self->cur || !tsw_call(self->cur->inst, slot, args, n, &result)) self->has_error = true;
  return result;
}

// lookahead + result_symbol: copied into wasm memory before a scan and back after
typedef struct {
  int32_t lookahead;
  TSSymbol result_symbol;
} LexerPrefix;

static bool call_lex(TSWasmStore *self, uint32_t slot, TSStateId state) {
  TswInst *inst = self->cur->inst;
  uint32_t lexer_address = tsw_lexer_address(inst);
  memcpy(&tsw_memory(inst)[lexer_address], self->lexer, sizeof(LexerPrefix));
  uint32_t args[2] = {lexer_address, state};
  bool result = call(self, slot, args, 2);
  if (self->has_error) return false;
  memcpy(self->lexer, &tsw_memory(inst)[lexer_address], sizeof(LexerPrefix)); // memory may have moved
  return result;
}

bool ts_wasm_store_call_lex_main(TSWasmStore *self, TSStateId state) {
  return call_lex(self, self->cur->lex_main, state);
}

bool ts_wasm_store_call_lex_keyword(TSWasmStore *self, TSStateId state) {
  return call_lex(self, self->cur->lex_keyword, state);
}

uint32_t ts_wasm_store_call_scanner_create(TSWasmStore *self) {
  return call(self, self->cur->scanner_create, NULL, 0);
}

void ts_wasm_store_call_scanner_destroy(TSWasmStore *self, uint32_t scanner_address) {
  // nothing to do: the heap is reset before every parse
  (void)self; (void)scanner_address;
}

bool ts_wasm_store_call_scanner_scan(TSWasmStore *self, uint32_t scanner_address, uint32_t valid_tokens_ix) {
  TswInst *inst = self->cur->inst;
  uint32_t lexer_address = tsw_lexer_address(inst);
  memcpy(&tsw_memory(inst)[lexer_address], self->lexer, sizeof(LexerPrefix));
  uint32_t args[3] = {scanner_address, lexer_address, self->cur->external_states + valid_tokens_ix * (uint32_t)sizeof(bool)};
  bool result = call(self, self->cur->scanner_scan, args, 3);
  if (self->has_error) return false;
  memcpy(self->lexer, &tsw_memory(inst)[lexer_address], sizeof(LexerPrefix));
  return result;
}

uint32_t ts_wasm_store_call_scanner_serialize(TSWasmStore *self, uint32_t scanner_address, char *buffer) {
  TswInst *inst = self->cur->inst;
  uint32_t buf = tsw_serialization_address(inst);
  uint32_t args[2] = {scanner_address, buf};
  uint32_t length = call(self, self->cur->scanner_serialize, args, 2);
  if (self->has_error) return 0;
  if (length > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) {
    self->has_error = true;
    return 0;
  }
  if (length > 0) memcpy(buffer, &tsw_memory(inst)[buf], length);
  return length;
}

void ts_wasm_store_call_scanner_deserialize(TSWasmStore *self, uint32_t scanner, const char *buffer, unsigned length) {
  TswInst *inst = self->cur->inst;
  uint32_t buf = tsw_serialization_address(inst);
  if (length > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) length = TREE_SITTER_SERIALIZATION_BUFFER_SIZE;
  if (length > 0) memcpy(&tsw_memory(inst)[buf], buffer, length);
  uint32_t args[3] = {scanner, buf, length};
  call(self, self->cur->scanner_deserialize, args, 3);
}

bool ts_language_is_wasm(const TSLanguage *self) {
  return self->lex_fn == sentinel_lex_fn;
}

// languages live as long as the editor
void ts_wasm_language_retain(const TSLanguage *self) { (void)self; }
void ts_wasm_language_release(const TSLanguage *self) { (void)self; }
