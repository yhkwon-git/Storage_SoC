/* Machine timer: a sleeping delay. mtime counts clk_sys clocks (prescale 0). */
#include "drv.h"

static volatile uint32_t ticked;

static void on_timer(void)
{
  timer_set_cmp(~0ull);
  ticked = 1;
}

void timer_sleep(uint32_t ticks)
{
  irq_timer_register(on_timer);
  ticked = 0;
  timer_set_cmp(timer_now() + ticks);
  irq_wait(&ticked);
}
