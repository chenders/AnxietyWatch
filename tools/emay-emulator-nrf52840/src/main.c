/*
 * SPDX-License-Identifier: MIT
 *
 * EMAY SleepO2 pulse-oximeter BLE *emulator* for the Raytac MDBT50Q-CX
 * (nRF52840) dongle.
 *
 * Purpose: a self-contained fake EMAY that the AnxietyWatch app connects to
 * exactly as it would to real hardware, so the CNS-depression detection
 * pipeline (quality gate -> severity -> fusion -> alert-tier machine) can be
 * driven end-to-end with a *scripted* desaturation that no real device could
 * (or should) reproduce on a person. No host required at run time — the dongle
 * only needs USB power.
 *
 * Wire protocol mirrored from AnxietyWatch/Services/EMAYRealtimeService.swift:
 *   - GATT service FF12, write char FF01, notify char FF02.
 *   - App writes a start sequence to FF01 (hello / deviceState / startRealtime /
 *     getBattery) and a ~1.5 s heartbeat; we accept everything and stream once
 *     the app subscribes to FF02 notifications.
 *   - Data frame on FF02 (8 bytes): EB 01 05 [PR] [SpO2] 7F 00 [cks],
 *     cks = sum(first 7 bytes) & 0x7F.
 *   - Advertised GAP name must start with "SleepO2" (namePrefix filter).
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <zephyr/drivers/gpio.h>

LOG_MODULE_REGISTER(emay_emu, LOG_LEVEL_DBG);

/* ---- 16-bit UUIDs (little-endian on the wire) --------------------------- */
#define EMAY_SVC_UUID   BT_UUID_DECLARE_16(0xFF12)
#define EMAY_FF01_UUID  BT_UUID_DECLARE_16(0xFF01) /* write  (app -> device) */
#define EMAY_FF02_UUID  BT_UUID_DECLARE_16(0xFF02) /* notify (device -> app) */

/* ---- Scenario ----------------------------------------------------------- *
 * Keyframes of {elapsed second, SpO2 %, pulse bpm}; linearly interpolated
 * between frames and looped. Designed to drive the AnxietyWatch alert tier
 * through clear -> watch -> confirm -> klaxon and back to clear (sustain
 * windows: rise 60 s, confirm->klaxon +30 s, clear 120 s; default SpO2 onset
 * 88 / floor 85 when no personal baseline is present). Edit freely — the only
 * constraints are 1 Hz cadence and SpO2 in 1..100 (0x00/0xFF are "no finger"
 * sentinels the app treats as no-data).
 */
struct keyframe {
	uint16_t t;   /* seconds into the loop */
	uint8_t spo2; /* percent */
	uint8_t pr;   /* bpm */
};

static const struct keyframe SCENARIO[] = {
	{    0, 98, 66 }, /* brief warmup: healthy, lets the quality gate reach canAssess */
	{   20, 98, 66 },
	{   22, 78, 44 }, /* near-instant desaturation into dangerous hypoxia */
	{  120, 78, 44 }, /* hold dangerous ~100 s: watch -> confirm -> KLAXON (~t112) */
	{  122, 98, 66 }, /* near-instant RECOVERY: de-escalation begins the moment SpO2 is back */
	{  260, 98, 66 }, /* hold healthy past the app's ~120 s clear window: Clear (~t242), loops */
};
/* Fast test loop (260 s): the ramps are near-instant (2 s), so the only waits
 * left are the APP's own sustain windows — ~90 s of sustained low before KLAXON,
 * and ~120 s of sustained-normal before Clear. The dongle cannot shorten those;
 * to make the whole cycle shorter, shorten the sustain windows in the app's
 * CNSThresholds (DEBUG only). */
#define LOOP_SECONDS 260U

static void scenario_value(uint32_t t, uint8_t *spo2, uint8_t *pr)
{
	uint32_t s = t % LOOP_SECONDS;

	for (size_t i = 0; i + 1 < ARRAY_SIZE(SCENARIO); i++) {
		uint32_t t0 = SCENARIO[i].t;
		uint32_t t1 = SCENARIO[i + 1].t;
		if (s >= t0 && s < t1) {
			int32_t span = (int32_t)(t1 - t0);
			int32_t d = (int32_t)(s - t0);
			int32_t sp = (int32_t)SCENARIO[i].spo2 +
				     ((int32_t)SCENARIO[i + 1].spo2 - (int32_t)SCENARIO[i].spo2) * d / span;
			int32_t pu = (int32_t)SCENARIO[i].pr +
				     ((int32_t)SCENARIO[i + 1].pr - (int32_t)SCENARIO[i].pr) * d / span;
			*spo2 = (uint8_t)sp;
			*pr = (uint8_t)pu;
			return;
		}
	}
	/* s is always < LOOP_SECONDS, so the loop above always matches; this is
	 * only a defensive fallback. */
	*spo2 = SCENARIO[ARRAY_SIZE(SCENARIO) - 1].spo2;
	*pr = SCENARIO[ARRAY_SIZE(SCENARIO) - 1].pr;
}

/* ---- GATT --------------------------------------------------------------- */
static volatile bool notify_enabled;
static uint32_t elapsed_s; /* seconds since the app subscribed */

/* Accept (and ignore the contents of) every FF01 write: hello / deviceState /
 * startRealtime / getBattery / heartbeat. Streaming is gated on the FF02
 * subscription instead, which is the robust signal that the app is ready for
 * data regardless of command-write ordering. */
static ssize_t ff01_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			  const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);
	LOG_HEXDUMP_DBG(buf, len, "FF01 RX (app->ring)");
	return len;
}

static void ff02_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);
	notify_enabled = (value == BT_GATT_CCC_NOTIFY);
	if (notify_enabled) {
		elapsed_s = 0; /* restart the scenario on each fresh subscription */
		LOG_INF("FF02 notifications ENABLED — streaming scenario from t=0");
	} else {
		LOG_INF("FF02 notifications disabled");
	}
}

/* Attribute layout (indices used by bt_gatt_notify below):
 *   [0] primary service   [1] FF01 decl   [2] FF01 value
 *   [3] FF02 decl         [4] FF02 value  [5] FF02 CCC
 */
BT_GATT_SERVICE_DEFINE(emay_svc,
	BT_GATT_PRIMARY_SERVICE(EMAY_SVC_UUID),
	BT_GATT_CHARACTERISTIC(EMAY_FF01_UUID,
			       BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE, NULL, ff01_write, NULL),
	BT_GATT_CHARACTERISTIC(EMAY_FF02_UUID,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(ff02_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

#define FF02_VALUE_ATTR (&emay_svc.attrs[4])

/* ---- Advertising -------------------------------------------------------- *
 * The service UUID FF12 goes in the primary advertising data so iOS's
 * service-filtered scan (scanForPeripherals(withServices:[FF12])) discovers
 * us; the name goes in the scan response. */
static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID16_ALL, 0x12, 0xFF), /* 0xFF12, little-endian */
};
static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

/* Connectable advertising stops when a central connects and is NOT
 * auto-restarted by Zephyr on disconnect, so we (re)start it explicitly from
 * main() and from the disconnected callback. The restart is deferred to the
 * system workqueue rather than called inside the connection callback. */
static void adv_start(void)
{
	int err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
	if (err && err != -EALREADY) {
		LOG_ERR("advertising start failed (%d)", err);
	} else {
		LOG_INF("advertising as \"%s\" (service FF12)", CONFIG_BT_DEVICE_NAME);
	}
}

static void adv_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	adv_start();
}
static K_WORK_DEFINE(adv_work, adv_work_handler);

/* ---- Optional streaming-heartbeat LED ----------------------------------- */
#if DT_NODE_HAS_STATUS(DT_ALIAS(led0), okay)
static const struct gpio_dt_spec led0 = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
#define HAVE_LED 1
#else
#define HAVE_LED 0
#endif

static void led_init(void)
{
#if HAVE_LED
	if (gpio_is_ready_dt(&led0)) {
		gpio_pin_configure_dt(&led0, GPIO_OUTPUT_INACTIVE);
	}
#endif
}

static void led_toggle(void)
{
#if HAVE_LED
	if (gpio_is_ready_dt(&led0)) {
		gpio_pin_toggle_dt(&led0);
	}
#endif
}

/* ---- 1 Hz streaming loop ------------------------------------------------ */
static void stream_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(stream_work, stream_work_handler);

static void stream_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	if (notify_enabled) {
		uint8_t spo2, pr;
		scenario_value(elapsed_s, &spo2, &pr);

		uint8_t frame[8] = { 0xEB, 0x01, 0x05, pr, spo2, 0x7F, 0x00, 0x00 };
		uint32_t sum = 0;
		for (int i = 0; i < 7; i++) {
			sum += frame[i];
		}
		frame[7] = (uint8_t)(sum & 0x7F);

		int err = bt_gatt_notify(NULL, FF02_VALUE_ATTR, frame, sizeof(frame));
		if (err) {
			LOG_WRN("notify failed (%d)", err);
		} else {
			led_toggle();
			LOG_HEXDUMP_DBG(frame, sizeof(frame), "FF02 TX (ring->app)");
			LOG_DBG("t=%us SpO2=%u PR=%u", elapsed_s, spo2, pr);
		}
		elapsed_s++;
	}

	k_work_reschedule(&stream_work, K_SECONDS(1));
}

/* ---- Connection callbacks ----------------------------------------------- */
static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_WRN("connection failed (0x%02x)", err);
		return;
	}
	LOG_INF("connected — waiting for FF02 subscription");
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	ARG_UNUSED(conn);
	LOG_INF("disconnected (0x%02x) — re-advertising", reason);
	notify_enabled = false;
#if HAVE_LED
	if (gpio_is_ready_dt(&led0)) {
		gpio_pin_set_dt(&led0, 0);
	}
#endif
	k_work_submit(&adv_work);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
};

int main(void)
{
	int err;

	led_init();

	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable failed (%d)", err);
		return 0;
	}
	LOG_INF("Bluetooth ready");

	adv_start();

	k_work_schedule(&stream_work, K_SECONDS(1));
	return 0;
}
