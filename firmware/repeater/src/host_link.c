/*
 * Auracaster Repeater <-> Mac app link over the USB CDC ACM console (v0.1.2).
 *
 *  - "1200 baud touch" -> restart into the UF2 bootloader (firmware update
 *    from the app, no reset button needed)
 *  - when the host opens the port (DTR 0 -> 1):
 *        @AURA id role=repeater version=0.1.2 variant=s140v6 load=0x26000 flags=2 board=promicro_nrf52840
 *  - every 2 s while the port is open:
 *        @AURA status state=relaying source="Wohnzimmer" rssi=-61 relay="Wohnzimmer +" rx_ok=.. ...
 *
 * The app shows these lines as "Repeater-Status". Normal log output stays
 * as it is; the "@AURA " prefix makes the machine-readable lines easy to find.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stddef.h>

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/printk.h>

#include "auracaster_fw.h"

/* main.c */
void repeater_status_format(char *out, size_t len);

#define STATUS_INTERVAL_MS 2000

static const struct device *const console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

static void print_ident(void)
{
	uint8_t info[AURA_FW_INFO_LEN];

	aura_fw_info(info);
	printk("@AURA id role=%s version=%s variant=%s load=0x%05x flags=%u "
	       "board=promicro_nrf52840\n",
	       aura_fw_role_name(), aura_fw_version_string(), aura_fw_variant_name(),
	       (unsigned int)aura_fw_load_address(), (unsigned int)info[10]);
}

static void host_link_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	static char line[192];
	uint32_t last_dtr = 0U;
	int64_t next_status = 0;

	while (true) {
		/* enters the UF2 bootloader on a 1200 baud touch (no return) */
		uint32_t dtr = aura_fw_touch_poll(console);

		if (dtr && !last_dtr) {
			k_msleep(300); /* host terminal settles */
			print_ident();
			next_status = 0;
		}
		if (dtr && k_uptime_get() >= next_status) {
			repeater_status_format(line, sizeof(line));
			printk("@AURA status %s\n", line);
			next_status = k_uptime_get() + STATUS_INTERVAL_MS;
		}
		last_dtr = dtr;
		k_msleep(100);
	}
}

K_THREAD_DEFINE(host_link, 1536, host_link_thread, NULL, NULL, NULL,
		K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
