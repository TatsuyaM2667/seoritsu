// Loads a wasm module with our interpreter and prints what tree_sitter_test() returns.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { uint32_t a, b, c, d; } Dylink;
void *tsw_load(const uint8_t *, size_t, const char *, uint32_t *, Dylink *);
int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "rb");
  if (!f) return 2;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  rewind(f);
  uint8_t *b = malloc(n);
  fread(b, 1, n, f);
  fclose(f);
  uint32_t r = 0;
  Dylink dl;
  if (!tsw_load(b, n, "test", &r, &dl)) {
    printf("load/trap failed\n");
    return 1;
  }
  printf("%u\n", r);
  return 0;
}
