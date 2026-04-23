#include <stdio.h>
#include <riscv-pk/encoding.h>
#include "marchid.h"
#include <stdint.h>

// TODO: change mode from M to S
int main(void) {
  uint64_t marchid = read_csr(marchid);
  const char* march = get_march(marchid);
  printf("kernel started successfully %s\n", march);
  return 0;
}
