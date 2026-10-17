/* SPDX-License-Identifier: Apache-2.0 */
#ifndef REPEATER_LED_H_
#define REPEATER_LED_H_

enum led_state {
	LED_SEARCHING, /* slow blink: looking for the source broadcast      */
	LED_SYNCED,    /* double blink: receiving the source, relay not up  */
	LED_RELAYING,  /* steady on: relay broadcast is on air              */
	LED_ERROR,     /* fast blink: Bluetooth could not be started        */
};

void led_set(enum led_state state);
enum led_state led_get(void);

#endif /* REPEATER_LED_H_ */
