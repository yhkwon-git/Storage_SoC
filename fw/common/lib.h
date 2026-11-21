#ifndef LIB_H
#define LIB_H

#include <stdint.h>

void sys_putc(char c);
void sys_puts(const char *s);
void sys_puthex(uint32_t v);
void sys_putdec(uint32_t v);
void sys_exit(int code) __attribute__((noreturn));

/* Called with the saved registers (ra at index 0); returns the new mepc. */
uint32_t trap_handler(uint32_t *frame);

#endif
