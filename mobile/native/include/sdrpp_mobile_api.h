#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* sdrpp_engine_t;

typedef enum {
    SDRPP_MODE_NFM = 0,
    SDRPP_MODE_WFM = 1,
    SDRPP_MODE_AM  = 2,
    SDRPP_MODE_DSB = 3,
    SDRPP_MODE_USB = 4,
    SDRPP_MODE_CW  = 5,
    SDRPP_MODE_LSB = 6,
    SDRPP_MODE_RAW = 7,
} sdrpp_mode_t;

typedef enum {
    SDRPP_CONNECTION_DISCONNECTED = 0,
    SDRPP_CONNECTION_CONNECTING = 1,
    SDRPP_CONNECTION_CONNECTED = 2,
    SDRPP_CONNECTION_ERROR = 3,
} sdrpp_connection_state_t;

typedef struct {
    sdrpp_connection_state_t connection;
    uint64_t frequency_hz;
    uint32_t sample_rate_hz;
    float bandwidth_hz;
    sdrpp_mode_t mode;
    float volume;
} sdrpp_state_t;

sdrpp_engine_t sdrpp_engine_create(void);
void sdrpp_engine_destroy(sdrpp_engine_t engine);

int sdrpp_engine_connect_rtl_tcp(
    sdrpp_engine_t engine,
    const char* host,
    uint16_t port,
    uint32_t sample_rate_hz);

void sdrpp_engine_disconnect(sdrpp_engine_t engine);

int sdrpp_engine_set_frequency(sdrpp_engine_t engine, uint64_t frequency_hz);
int sdrpp_engine_set_mode(sdrpp_engine_t engine, sdrpp_mode_t mode);
int sdrpp_engine_set_bandwidth(sdrpp_engine_t engine, float bandwidth_hz);
int sdrpp_engine_set_squelch(sdrpp_engine_t engine, int enabled, float level_db);
int sdrpp_engine_set_gain_auto(sdrpp_engine_t engine, int enabled);
int sdrpp_engine_set_gain(sdrpp_engine_t engine, float gain_db);
int sdrpp_engine_set_volume(sdrpp_engine_t engine, float volume);

size_t sdrpp_engine_read_fft(
    sdrpp_engine_t engine,
    float* out_bins,
    size_t capacity);

int sdrpp_engine_get_state(sdrpp_engine_t engine, sdrpp_state_t* out_state);

#ifdef __cplusplus
}
#endif
