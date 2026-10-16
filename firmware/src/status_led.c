/*
 * Auracaster dongle status LED (P0.15 on nice!nano / Pro Micro nRF52840)
 *
 *  - short blink every second : powered, waiting for the host
 *  - steady on                : host has opened the serial port (DTR set,
 *                               Bumble/auracaster_helper is connected)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/uart.h>

#if DT_NODE_EXISTS(DT_ALIAS(led0))

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct device *const hci_uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_bt_c2h_uart));

static void status_led_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	uint32_t tick = 0U;

	if (!gpio_is_ready_dt(&led) || gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE)) {
		return;
	}

	while (true) {
		uint32_t dtr = 0U;

		if (device_is_ready(hci_uart)) {
			(void)uart_line_ctrl_get(hci_uart, UART_LINE_CTRL_DTR, &dtr);
		}

		if (dtr) {
			gpio_pin_set_dt(&led, 1);
		} else {
			/* 100 ms on, 900 ms off */
			gpio_pin_set_dt(&led, (tick % 10U) == 0U);
		}

		tick++;
		k_msleep(100);
	}
}

K_THREAD_DEFINE(status_led, 512, status_led_thread, NULL, NULL, NULL,
		K_LOWEST_APPLICATION_THREAD_PRIO, 0, 500);

#endif /* led0 */
