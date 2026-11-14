// Differential test for the wasm interpreter: the same code is compiled natively
// and to wasm32; tree_sitter_test() must return the same checksum both ways.
#include <stdint.h>

static uint32_t h = 2166136261u;
static void mix(uint64_t v) {
  for (int i = 0; i < 8; i++) {
    h ^= (uint8_t)(v >> (i * 8));
    h *= 16777619u;
  }
}

static volatile int32_t vi[] = {0, 1, -1, 7, -7, 13, 0x7fffffff, (int32_t)0x80000000, 255, -256, 65535, 12345678};
static volatile int64_t vl[] = {0, 1, -1, 3, -3, 1000000007, 0x7fffffffffffffffLL, (int64_t)0x8000000000000000ULL, -123456789012LL};
static volatile int8_t bytes[16] = {-1, 2, -3, 4, 127, -128, 0, 9};
static volatile int16_t shorts[8] = {-1, 300, -30000, 32767, -32768, 7};

static int classify(int x) {
  switch (x % 23) { // br_table
    case 0: return 11; case 1: return 22; case 2: return 33; case 3: return 44; case 4: return 55;
    case 5: return 66; case 6: return 77; case 7: return 88; case 8: return 99; case 9: return 111;
    case 10: return 222; case 11: return 333; case 12: return 444; case 13: return 555;
    default: return -x;
  }
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int mul(int a, int b) { return a * b; }
static int (*volatile ops[])(int, int) = {add, sub, mul};

static int nested(int a, int b) {
  int r = 0;
  for (int i = 0; i < a; i++) {
    if (i == b) continue;
    for (int j = 0; j < 5; j++) {
      if (j * i > 12) break;
      r += (i ^ j) & 3 ? i : j;
    }
    if (r > 1000) return r;
  }
  return r;
}

uint32_t tree_sitter_test(void) {
  int n32 = sizeof(vi) / sizeof(vi[0]), n64 = sizeof(vl) / sizeof(vl[0]);
  for (int i = 0; i < n32; i++) {
    for (int j = 0; j < n32; j++) {
      int32_t a = vi[i], b = vi[j];
      uint32_t ua = (uint32_t)a, ub = (uint32_t)b;
      mix((uint32_t)(a + b)); mix((uint32_t)(a - b)); mix((uint32_t)(a * b));
      if (b != 0 && !(a == (int32_t)0x80000000 && b == -1)) { mix((uint32_t)(a / b)); mix((uint32_t)(a % b)); }
      if (ub != 0) { mix(ua / ub); mix(ua % ub); }
      mix(ua << (ub & 31)); mix(ua >> (ub & 31)); mix((uint32_t)(a >> (b & 31)));
      mix((ua << (ub & 31)) | (ua >> ((32 - (ub & 31)) & 31)));
      mix(a < b); mix(ua < ub); mix(a >= b); mix(ua >= ub); mix(a == b);
      mix(a > b ? a : b);
    }
    mix(__builtin_clz((uint32_t)vi[i] | 1)); mix(__builtin_ctz((uint32_t)vi[i] | 0x80000000u)); mix(__builtin_popcount((uint32_t)vi[i]));
    mix((int64_t)vi[i]); mix((uint64_t)(uint32_t)vi[i]); mix((int8_t)vi[i]); mix((int16_t)vi[i]);
    mix(classify(vi[i] & 0xffff));
  }
  for (int i = 0; i < n64; i++) {
    for (int j = 0; j < n64; j++) {
      int64_t a = vl[i], b = vl[j];
      uint64_t ua = (uint64_t)a, ub = (uint64_t)b;
      mix((uint64_t)(a + b)); mix((uint64_t)(a * b)); mix(ua - ub);
      if (b != 0 && !(a == (int64_t)0x8000000000000000ULL && b == -1)) { mix((uint64_t)(a / b)); mix((uint64_t)(a % b)); }
      if (ub != 0) { mix(ua / ub); mix(ua % ub); }
      mix(ua << (ub & 63)); mix(ua >> (ub & 63)); mix((uint64_t)(a >> (b & 63)));
      mix(a < b); mix(ua < ub); mix((uint32_t)a);
    }
    mix(__builtin_clzll((uint64_t)vl[i] | 1)); mix(__builtin_popcountll((uint64_t)vl[i]));
  }
  for (int i = 0; i < 16; i++) mix(bytes[i]);
  for (int i = 0; i < 16; i++) mix((uint8_t)bytes[i]);
  for (int i = 0; i < 8; i++) mix(shorts[i]);
  for (int i = 0; i < 8; i++) mix((uint16_t)shorts[i]);
  for (int i = 0; i < 9; i++) mix(ops[i % 3](i * 7, 3 - i));
  mix(fib(18));
  mix(nested(40, 7));
  volatile double d = 3.75;
  volatile float f = -2.5f;
  mix((int)(d * f)); mix((int64_t)(d * 1e9)); mix((uint32_t)(d * 1000));
  return h;
}

#ifdef NATIVE
#include <stdio.h>
int main(void) {
  printf("%u\n", tree_sitter_test());
  return 0;
}
#endif
