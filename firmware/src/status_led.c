/*
 * Auracaster dongle status LED (P0.15 on nice!nano / Pro Micro nRF52840)
 * and host-session supervisor.
 *
 * LED:
 *  - short blink every second : powered, waiting for the host
 *  - steady on                : host has opened the serial port (DTR set,
 *                               Bumble/auracaster_helper is connected)
 *
 * Supervisor (v0.1.1): when the host closes the serial port (DTR 1 -> 0) the
 * dongle reboots, so every helper start talks to a freshly initialised
 * controller. This also recovers a link layer that stopped answering HCI
 * commands: the helper closes the port, the dongle reboots, the helper
 * re-opens it and resynchronises with HCI_Reset.
 *
 * v0.1.2: "1200 baud touch" - if the host set 1200 baud before dropping DTR,
 * the dongle restarts into the UF2 bootloader instead (Mac app firmware
 * update, like Arduino/CircuitPython boards).
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/reboot.h>

#include "auracaster_fw.h"

static const struct device *const hci_uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_bt_c2h_uart));

#if DT_NODE_EXISTS(DT_ALIAS(led0))
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
#define HAS_LED 1
#else
#define HAS_LED 0
#endif

static void status_led_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	uint32_t tick = 0U;
	uint32_t last_dtr = 0U;
	bool led_ok = false;

#if HAS_LED
	led_ok = gpio_is_ready_dt(&led) && gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE) == 0;
#endif

	while (true) {
		uint32_t dtr = 0U;

		/* enters the UF2 bootloader on a 1200 baud touch (no return) */
		dtr = aura_fw_touch_poll(hci_uart);

		if (last_dtr && !dtr) {
			/* Host closed the port: confirm for 200 ms, then reboot. */
			k_msleep(200);
			dtr = aura_fw_touch_poll(hci_uart);
			if (!dtr) {
				sys_reboot(SYS_REBOOT_WARM);
			}
		}
		last_dtr = dtr;

#if HAS_LED
		if (led_ok) {
			if (dtr) {
				gpio_pin_set_dt(&led, 1);
			} else {
				/* 100 ms on, 900 ms off */
				gpio_pin_set_dt(&led, (tick % 10U) == 0U);
			}
		}
#else
		ARG_UNUSED(led_ok);
#endif

		tick++;
		k_msleep(100);
	}
}

K_THREAD_DEFINE(status_led, 512, status_led_thread, NULL, NULL, NULL,
		K_LOWEST_APPLICATION_THREAD_PRIO, 0, 500);
