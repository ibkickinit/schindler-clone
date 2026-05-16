/*
 * Schindler 2.0 - Mezzanine UI Prototype Firmware
 *
 * Target: RP2040-Zero (Waveshare) - same silicon as production Pro mezzanine.
 * Firmware ports 1:1 to the production board with pin remapping only.
 *
 * Hardware layout (perfboard test rig):
 *   GP0  - 5-way nav: UP
 *   GP1  - 5-way nav: DOWN
 *   GP2  - 5-way nav: LEFT
 *   GP3  - 5-way nav: RIGHT
 *   GP4  - 5-way nav: CENTER (press)
 *   GP5  - Set button
 *   GP6  - BTN_B (perfboard "Reset" button - NOT hardware reset)
 *   GP8  - ENC A quadrature A
 *   GP9  - ENC A quadrature B
 *   GP10 - ENC A push-switch (shaft press)
 *   GP11 - ENC B quadrature A
 *   GP12 - ENC B quadrature B
 *   GP13 - ENC B push-switch (shaft press)
 *   GP16 - WS2812 status LED (on-board RP2040-Zero)
 *   GP26 - I2C1 SDA  -> OLED B
 *   GP27 - I2C1 SCL  -> OLED B
 *   GP28 - I2C0 SDA  -> OLED A
 *   GP29 - I2C0 SCL  -> OLED A
 *
 * All switches active-low with internal pull-ups enabled.
 * Both OLEDs: SSD1306, I2C addr 0x3C, 128x32 (0.91" form factor).
 *
 * Encoder note: EC11E18244AU is 18 PPR / 36 detents = half-step pattern.
 * Each detent click = 2 quadrature edges in 4x counting. The firmware
 * tracks raw 4x edges (count_raw) and displays detents = raw/2 so
 * "1 click" = "+/-1 detent" in the user's view.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "pico/stdlib.h"
#include "hardware/i2c.h"
#include "hardware/gpio.h"
#include "hardware/timer.h"
#include "hardware/pio.h"
#include "hardware/clocks.h"

#include "ws2812.pio.h"
#include "ssd1306.h"

/* ----- Pin definitions ----- */
#define NAV_UP          0
#define NAV_DOWN        1
#define NAV_LEFT        2
#define NAV_RIGHT       3
#define NAV_CENTER      4
#define BTN_SET         5
#define BTN_B           6

#define ENC_A_PINA      8
#define ENC_A_PINB      9
#define ENC_A_SW       10
#define ENC_B_PINA     11
#define ENC_B_PINB     12
#define ENC_B_SW       13

#define WS2812_PIN     16

#define I2C0_SDA       28
#define I2C0_SCL       29
#define I2C1_SDA       26
#define I2C1_SCL       27

/* ----- Constants ----- */
#define OLED_ADDR        0x3C
#define I2C_BAUD         400000
#define DEBOUNCE_US      5000      /* 5 ms */
#define POLL_PERIOD_US   500       /* 2 kHz - plenty of headroom for EC11 mechanical rates */
#define RENDER_PERIOD_MS 33        /* ~30 fps */
#define RPM_DECAY_AFTER_US 200000  /* RPM fades to 0 if no edge in 200 ms */
#define TELEM_MIN_US     50000     /* USB-CDC encoder log rate-limited to 20 Hz */

/* Button table */
#define N_BTN 9
enum {
    B_NAV_UP, B_NAV_DOWN, B_NAV_LEFT, B_NAV_RIGHT, B_NAV_CENTER,
    B_SET, B_BTN_B,
    B_ENC_A_SW, B_ENC_B_SW
};
static const uint8_t BTN_PIN[N_BTN] = {
    NAV_UP, NAV_DOWN, NAV_LEFT, NAV_RIGHT, NAV_CENTER,
    BTN_SET, BTN_B,
    ENC_A_SW, ENC_B_SW
};
static const char *BTN_NAME[N_BTN] = {
    "UP", "DN", "LF", "RT", "CTR", "SET", "BTN_B", "ENC_A", "ENC_B"
};

/*
 * Quadrature transition lookup table.
 *
 * Encoding: state = (A << 1) | B  (range 0..3)
 * Index    = (prev_state << 2) | curr_state  (range 0..15)
 * Value    = -1, 0, or +1 (detent direction)
 *
 * Forward rotation sequence (A leads B): 0 -> 2 -> 3 -> 1 -> 0
 * Reverse rotation sequence:             0 -> 1 -> 3 -> 2 -> 0
 *
 * If physical rotation feels backwards, swap ENC_x_PINA <-> ENC_x_PINB
 * in the #defines above.
 */
static const int8_t QUAD_LUT[16] = {
     0, -1, +1,  0,   /* prev=00 */
    +1,  0,  0, -1,   /* prev=01 */
    -1,  0,  0, +1,   /* prev=10 */
     0, +1, -1,  0    /* prev=11 */
};

/* ----- Global state (volatile = updated in timer ISR) ----- */
typedef struct {
    volatile int32_t  count_raw;     /* 4x quadrature count (2 per detent) */
    volatile uint8_t  prev_ab;       /* last seen 2-bit quadrature state */
    volatile uint32_t last_event_us; /* timestamp of last valid edge */
    volatile float    rpm;           /* EMA-filtered rotation rate */
    volatile uint32_t missed;        /* invalid transitions (skipped state) */
} encoder_t;

static encoder_t enc_a = { .prev_ab = 0 };
static encoder_t enc_b = { .prev_ab = 0 };

typedef struct {
    volatile bool     state;         /* debounced state (true = pressed) */
    volatile bool     last_raw;      /* last raw GPIO reading */
    volatile uint32_t last_change_us;
    volatile uint32_t press_count;
} button_t;

static button_t btn[N_BTN];

static volatile int      last_btn_event    = -1;
static volatile uint32_t last_btn_event_ms = 0;
static volatile bool     any_held          = false;

/* WS2812 PIO handles */
static PIO  ws_pio = pio0;
static uint ws_sm  = 0;

/* ----- Encoder update (called from timer ISR) ----- */
static inline void encoder_update(encoder_t *e, uint pin_a, uint pin_b, uint32_t now_us)
{
    uint8_t curr = (uint8_t)((gpio_get(pin_a) << 1) | gpio_get(pin_b));
    if (curr == e->prev_ab) return;

    uint8_t idx   = (uint8_t)((e->prev_ab << 2) | curr);
    int8_t  delta = QUAD_LUT[idx];

    if (delta == 0) {
        /* Skipped state (00<->11 or 01<->10) - missed an edge */
        e->missed++;
    } else {
        e->count_raw += delta;
        uint32_t dt = now_us - e->last_event_us;
        if (dt > 100 && dt < 1000000) {
            /* 72 edges per revolution at 4x quadrature counting (18 PPR * 4) */
            float inst_rpm = 60.0f * 1.0e6f / (72.0f * (float)dt);
            e->rpm = 0.7f * e->rpm + 0.3f * inst_rpm;
        }
        e->last_event_us = now_us;
    }
    e->prev_ab = curr;
}

/* ----- Timer callback @ 2 kHz: poll encoders + debounce buttons ----- */
static bool poll_callback(struct repeating_timer *t)
{
    (void)t;
    uint32_t now_us = time_us_32();

    /* Encoders */
    encoder_update(&enc_a, ENC_A_PINA, ENC_A_PINB, now_us);
    encoder_update(&enc_b, ENC_B_PINA, ENC_B_PINB, now_us);

    /* Button debounce */
    bool held_now = false;
    for (int i = 0; i < N_BTN; i++) {
        bool raw = !gpio_get(BTN_PIN[i]);   /* active-low -> "pressed" = true */
        if (raw != btn[i].last_raw) {
            btn[i].last_change_us = now_us;
            btn[i].last_raw       = raw;
        }
        if ((now_us - btn[i].last_change_us) > DEBOUNCE_US) {
            if (btn[i].state != raw) {
                btn[i].state = raw;
                if (raw) {
                    btn[i].press_count++;
                    last_btn_event    = i;
                    last_btn_event_ms = to_ms_since_boot(get_absolute_time());
                }
            }
        }
        if (btn[i].state) held_now = true;
    }
    any_held = held_now;

    /* Decay RPM if no recent activity */
    if ((now_us - enc_a.last_event_us) > RPM_DECAY_AFTER_US) enc_a.rpm *= 0.95f;
    if ((now_us - enc_b.last_event_us) > RPM_DECAY_AFTER_US) enc_b.rpm *= 0.95f;

    return true;
}

/* ----- WS2812 helpers ----- */
static inline uint32_t pack_grb(uint8_t r, uint8_t g, uint8_t b)
{
    return ((uint32_t)g << 16) | ((uint32_t)r << 8) | (uint32_t)b;
}

static inline void ws2812_set(uint32_t grb)
{
    pio_sm_put_blocking(ws_pio, ws_sm, grb << 8u);
}

/* ----- OLED rendering ----- */
static uint8_t fb[SSD1306_FB_SIZE];
static char    fmt[24];

static void render_oled(i2c_inst_t *i2c, int which)
{
    encoder_t *e = (which == 0) ? &enc_a : &enc_b;
    int sw_idx   = (which == 0) ? B_ENC_A_SW : B_ENC_B_SW;
    int32_t det  = e->count_raw / 2;

    memset(fb, 0, sizeof(fb));

    /* Line 0 (page 0): encoder detent count */
    snprintf(fmt, sizeof(fmt), "ENC %c %+ld", (which == 0) ? 'A' : 'B', (long)det);
    ssd1306_text(fb, 0, 0, fmt);

    /* Line 1 (page 1): RPM (integer) */
    snprintf(fmt, sizeof(fmt), "RPM %d", (int)e->rpm);
    ssd1306_text(fb, 0, 1, fmt);

    /* Line 2 (page 2): encoder shaft-press count */
    snprintf(fmt, sizeof(fmt), "CLK %lu", (unsigned long)btn[sw_idx].press_count);
    ssd1306_text(fb, 0, 2, fmt);

    /* Line 3 (page 3): differs per OLED */
    if (which == 0) {
        if (last_btn_event >= 0) {
            snprintf(fmt, sizeof(fmt), "BTN %s", BTN_NAME[last_btn_event]);
        } else {
            snprintf(fmt, sizeof(fmt), "BTN -");
        }
    } else {
        unsigned long total_missed = (unsigned long)(enc_a.missed + enc_b.missed);
        snprintf(fmt, sizeof(fmt), "MIS %lu", total_missed);
    }
    ssd1306_text(fb, 0, 3, fmt);

    ssd1306_show(i2c, fb);
}

/* ----- Telemetry over USB-CDC ----- */
static void telemetry_tick(uint32_t now_us)
{
    static int32_t  prev_a            = 0;
    static int32_t  prev_b            = 0;
    static int      prev_last_btn     = -1;
    static uint32_t prev_last_btn_ms  = 0;
    static uint32_t prev_missed       = 0;
    static uint32_t last_emit_us      = 0;

    int32_t  cur_a       = enc_a.count_raw;
    int32_t  cur_b       = enc_b.count_raw;
    uint32_t cur_missed  = enc_a.missed + enc_b.missed;

    bool emit_now = false;
    if (last_btn_event != prev_last_btn || last_btn_event_ms != prev_last_btn_ms) emit_now = true;
    if (cur_missed != prev_missed) emit_now = true;
    if ((cur_a != prev_a || cur_b != prev_b) && (now_us - last_emit_us > TELEM_MIN_US)) emit_now = true;

    if (!emit_now) return;

    printf("t=%lu  a=%+ld (det %+ld)  rpm_a=%d  b=%+ld (det %+ld)  rpm_b=%d  btn=%s  miss=%lu\n",
           (unsigned long)(now_us / 1000),
           (long)cur_a, (long)(cur_a / 2), (int)enc_a.rpm,
           (long)cur_b, (long)(cur_b / 2), (int)enc_b.rpm,
           (last_btn_event >= 0) ? BTN_NAME[last_btn_event] : "-",
           (unsigned long)cur_missed);

    prev_a           = cur_a;
    prev_b           = cur_b;
    prev_last_btn    = last_btn_event;
    prev_last_btn_ms = last_btn_event_ms;
    prev_missed      = cur_missed;
    last_emit_us     = now_us;
}

/* ----- Main ----- */
int main(void)
{
    stdio_init_all();
    sleep_ms(2000);    /* give USB host time to enumerate */

    printf("\n\nSchindler 2.0 mezzanine prototype firmware\n");
    printf("Build: %s %s\n", __DATE__, __TIME__);
    printf("Pin map: nav 0-4, btn 5-6, enc 8-13, ws2812 16, i2c 26-29\n");

    /* GPIO inputs: nav switch + buttons + encoder switches + encoder quadrature */
    const uint inputs[] = {
        NAV_UP, NAV_DOWN, NAV_LEFT, NAV_RIGHT, NAV_CENTER,
        BTN_SET, BTN_B,
        ENC_A_SW, ENC_B_SW,
        ENC_A_PINA, ENC_A_PINB, ENC_B_PINA, ENC_B_PINB
    };
    for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
        gpio_init(inputs[i]);
        gpio_set_dir(inputs[i], GPIO_IN);
        gpio_pull_up(inputs[i]);
    }

    /* I2C0 -> OLED A on GP28 (SDA) / GP29 (SCL) */
    i2c_init(i2c0, I2C_BAUD);
    gpio_set_function(I2C0_SDA, GPIO_FUNC_I2C);
    gpio_set_function(I2C0_SCL, GPIO_FUNC_I2C);
    gpio_pull_up(I2C0_SDA);
    gpio_pull_up(I2C0_SCL);

    /* I2C1 -> OLED B on GP26 (SDA) / GP27 (SCL) */
    i2c_init(i2c1, I2C_BAUD);
    gpio_set_function(I2C1_SDA, GPIO_FUNC_I2C);
    gpio_set_function(I2C1_SCL, GPIO_FUNC_I2C);
    gpio_pull_up(I2C1_SDA);
    gpio_pull_up(I2C1_SCL);

    /* WS2812 PIO setup */
    uint ws_offset = pio_add_program(ws_pio, &ws2812_program);
    ws_sm          = (uint)pio_claim_unused_sm(ws_pio, true);
    ws2812_program_init(ws_pio, ws_sm, ws_offset, WS2812_PIN, 800000.0f);
    ws2812_set(pack_grb(0, 32, 0));   /* dim green = boot complete */

    /* Init both OLEDs */
    sleep_ms(50);
    ssd1306_init(i2c0);
    ssd1306_init(i2c1);

    /* Initial encoder state */
    sleep_ms(10);
    enc_a.prev_ab = (uint8_t)((gpio_get(ENC_A_PINA) << 1) | gpio_get(ENC_A_PINB));
    enc_b.prev_ab = (uint8_t)((gpio_get(ENC_B_PINA) << 1) | gpio_get(ENC_B_PINB));

    /* Initial button state */
    for (int i = 0; i < N_BTN; i++) {
        btn[i].last_raw = !gpio_get(BTN_PIN[i]);
        btn[i].state    = false;
    }

    /* Start polling timer @ 2 kHz */
    struct repeating_timer poll_timer;
    add_repeating_timer_us(-POLL_PERIOD_US, poll_callback, NULL, &poll_timer);

    printf("Running. Rotate encoders / press buttons to see events.\n");

    /* Main render + telemetry loop @ ~30 fps */
    absolute_time_t next_render = make_timeout_time_ms(RENDER_PERIOD_MS);
    while (true) {
        if (absolute_time_diff_us(get_absolute_time(), next_render) <= 0) {
            render_oled(i2c0, 0);
            render_oled(i2c1, 1);

            /* WS2812 state encoding */
            uint32_t now_us  = time_us_32();
            uint32_t total_miss = enc_a.missed + enc_b.missed;
            uint32_t since_a = now_us - enc_a.last_event_us;
            uint32_t since_b = now_us - enc_b.last_event_us;
            uint32_t since_enc = (since_a < since_b) ? since_a : since_b;

            uint32_t color;
            if (total_miss > 0) {
                color = pack_grb(64, 0, 0);     /* red = missed counts */
            } else if (any_held) {
                color = pack_grb(48, 48, 0);    /* yellow = button held */
            } else if (since_enc < 200000) {
                color = pack_grb(0, 0, 48);     /* blue = encoder active */
            } else {
                color = pack_grb(0, 16, 0);     /* dim green = idle */
            }
            ws2812_set(color);

            telemetry_tick(now_us);

            next_render = make_timeout_time_ms(RENDER_PERIOD_MS);
        }
        tight_loop_contents();
    }
}
