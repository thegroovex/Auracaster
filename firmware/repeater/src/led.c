/*
 * Auracaster Repeater status LED (P0.15, led0 on promicro_nrf52840)
 *
 *   slow blink (0.5 s on / 0.5 s off) : searching for the source
 *   double blink                      : synchronised to the source
 *   steady on                         : relaying (own broadcast on air)
 *   fast blink                        : error (Bluetooth init failed)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/atomic.h>

#include "led.h"

static atomic_t led_state_val = ATOMIC_INIT(LED_SEARCHING);

void led_set(enum led_state state)
{
	atomic_set(&led_state_val, (atomic_val_t)state);
}

#if DT_NODE_EXISTS(DT_ALIAS(led0))

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

static bool led_on_at(enum led_state state, uint32_t tick)
{
	uint32_t t = tick % 10U; /* 10 x 100 ms frame */

	switch (state) {
	case LED_RELAYING:
		return true;
	case LED_SYNCED:
		return (t == 0U) || (t == 2U);
	case LED_ERROR:
		return (tick & 1U) == 0U;
	case LED_SEARCHING:
	default:
		return t < 5U;
	}
}

static void led_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	uint32_t tick = 0U;

	if (!gpio_is_ready_dt(&led) || gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE)) {
		return;
	}

	while (true) {
		gpio_pin_set_dt(&led, led_on_at((enum led_state)atomic_get(&led_state_val), tick));
		tick++;
		k_msleep(100);
	}
}

K_THREAD_DEFINE(led_tid, 512, led_thread, NULL, NULL, NULL,
		K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);

#endif /* led0 */
