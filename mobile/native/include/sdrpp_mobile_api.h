#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define SDRPP_MOBILE_API __declspec(dllexport)
#else
#define SDRPP_MOBILE_API __attribute__((visibility("default")))
#endif

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

/*
 * DSP-only mobile bridge.
 *
 * The Flutter transport can continue feeding RTL-TCP unsigned 8-bit IQ while
 * the demodulation/resampling path below uses SDR++'s official C++ DSP blocks.
 * This keeps Flutter out of the high-rate signal processing implementation.
 */
SDRPP_MOBILE_API sdrpp_engine_t sdrpp_dsp_create(
    uint32_t input_sample_rate_hz,
    sdrpp_mode_t mode,
    float bandwidth_hz);

SDRPP_MOBILE_API void sdrpp_dsp_destroy(sdrpp_engine_t engine);

SDRPP_MOBILE_API int sdrpp_dsp_set_sample_rate(
    sdrpp_engine_t engine,
    uint32_t input_sample_rate_hz);

SDRPP_MOBILE_API int sdrpp_dsp_set_mode(
    sdrpp_engine_t engine,
    sdrpp_mode_t mode);

SDRPP_MOBILE_API int sdrpp_dsp_set_bandwidth(
    sdrpp_engine_t engine,
    float bandwidth_hz);

SDRPP_MOBILE_API int sdrpp_dsp_set_frequency_offset(
    sdrpp_engine_t engine,
    float offset_hz);

SDRPP_MOBILE_API int sdrpp_dsp_set_squelch(
    sdrpp_engine_t engine,
    int enabled,
    float level_db);

SDRPP_MOBILE_API int sdrpp_dsp_set_noise_blanker(
    sdrpp_engine_t engine,
    int enabled,
    float level);

SDRPP_MOBILE_API int sdrpp_dsp_set_high_pass(
    sdrpp_engine_t engine,
    int enabled);

SDRPP_MOBILE_API int sdrpp_dsp_set_deemphasis(
    sdrpp_engine_t engine,
    int mode_us);

SDRPP_MOBILE_API int sdrpp_dsp_set_ctcss(
    sdrpp_engine_t engine,
    int mode,
    int tone_index);

SDRPP_MOBILE_API int sdrpp_dsp_get_ctcss(
    sdrpp_engine_t engine,
    int* tone_index,
    float* tone_hz);

SDRPP_MOBILE_API int sdrpp_dsp_set_fm_ifnr(
    sdrpp_engine_t engine,
    int enabled,
    int preset);

SDRPP_MOBILE_API int sdrpp_dsp_set_am_agc(
    sdrpp_engine_t engine,
    int carrier_agc,
    float attack_ms,
    float decay_ms);

SDRPP_MOBILE_API int sdrpp_dsp_set_ssb_agc(
    sdrpp_engine_t engine,
    float attack_ms,
    float decay_ms);

SDRPP_MOBILE_API int sdrpp_dsp_set_cw_options(
    sdrpp_engine_t engine,
    int tone_hz,
    float attack_ms,
    float decay_ms);

SDRPP_MOBILE_API int sdrpp_dsp_set_nfm_options(
    sdrpp_engine_t engine,
    int low_pass);

SDRPP_MOBILE_API int sdrpp_dsp_set_wfm_options(
    sdrpp_engine_t engine,
    int stereo,
    int low_pass,
    int rds_enabled);

/*
 * Read current RDS Program Service / RadioText strings.
 * Returns 1 when at least one field is currently valid, 0 otherwise.
 */
SDRPP_MOBILE_API int sdrpp_dsp_get_rds(
    sdrpp_engine_t engine,
    char* program_service,
    size_t program_service_capacity,
    char* radio_text,
    size_t radio_text_capacity);

/*
 * Clear resampler/demodulator/AGC history after retuning so old-channel state
 * and buffered audio cannot mute or contaminate the new frequency.
 */
SDRPP_MOBILE_API void sdrpp_dsp_reset(sdrpp_engine_t engine);

/*
 * Process interleaved unsigned 8-bit RTL-TCP IQ:
 *   I0 Q0 I1 Q1 ...
 *
 * Output is signed 16-bit interleaved stereo PCM at 48 kHz. Mono modes are
 * duplicated to L/R; WFM uses SDR++ BroadcastFM stereo decoding. The return
 * value is the number of int16 values written to out_pcm (two per frame).
 */
SDRPP_MOBILE_API size_t sdrpp_dsp_process_u8(
    sdrpp_engine_t engine,
    const uint8_t* iq,
    size_t iq_bytes,
    int16_t* out_pcm,
    size_t out_capacity_samples);

/* Process interleaved float32 IQ already normalized to [-1, 1]. */
SDRPP_MOBILE_API size_t sdrpp_dsp_process_cf32(
    sdrpp_engine_t engine,
    const float* iq_interleaved,
    size_t complex_samples,
    int16_t* out_pcm,
    size_t out_capacity_samples);

typedef void* sdrpp_source_t;

SDRPP_MOBILE_API sdrpp_source_t sdrpp_source_create(
    sdrpp_engine_t engine);
SDRPP_MOBILE_API void sdrpp_source_destroy(sdrpp_source_t source);

SDRPP_MOBILE_API int sdrpp_source_connect_rtl_tcp(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz);

SDRPP_MOBILE_API int sdrpp_source_open_file(
    sdrpp_source_t source,
    const char* path,
    int float32_mode,
    uint32_t center_frequency_hz);

/*
 * Upstream network_source semantics:
 * protocol: 0 TCP client, 1 UDP
 * sample_type: 0 int8 IQ, 1 int16 IQ, 2 int32 IQ, 3 float32 IQ
 */
SDRPP_MOBILE_API int sdrpp_source_connect_network(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    int protocol,
    int sample_type,
    uint32_t center_frequency_hz);

SDRPP_MOBILE_API int sdrpp_source_connect_sdrpp_server(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t frequency_hz);

SDRPP_MOBILE_API int sdrpp_source_connect_spyserver(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz);

SDRPP_MOBILE_API int sdrpp_source_connect_rfspace(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz,
    int gain_db);

SDRPP_MOBILE_API int sdrpp_source_connect_hermes(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz,
    int gain_db);

SDRPP_MOBILE_API int sdrpp_source_connect_spectran_http(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t frequency_hz);

SDRPP_MOBILE_API int sdrpp_source_connect_rtl_sdr_fd(
    sdrpp_source_t source,
    int system_fd,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz);

/*
 * Generic SoapySDR hardware source. The device_args string uses the standard
 * Soapy markup syntax, for example "driver=rtlsdr" or
 * "driver=hackrf,serial=...".
 */
SDRPP_MOBILE_API int sdrpp_source_soapy_available(void);
SDRPP_MOBILE_API size_t sdrpp_source_soapy_enumerate(
    const char* filter_args,
    char* out_devices,
    size_t capacity);
SDRPP_MOBILE_API int sdrpp_source_connect_soapy(
    sdrpp_source_t source,
    const char* device_args,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz,
    double rf_bandwidth_hz,
    double gain_db,
    int agc,
    uint32_t channel);
SDRPP_MOBILE_API int sdrpp_source_get_soapy_driver(
    sdrpp_source_t source,
    char* out_text,
    size_t capacity);
SDRPP_MOBILE_API int sdrpp_source_get_soapy_hardware(
    sdrpp_source_t source,
    char* out_text,
    size_t capacity);

SDRPP_MOBILE_API int sdrpp_source_get_kind(
    sdrpp_source_t source);
SDRPP_MOBILE_API uint32_t sdrpp_source_get_sample_rate(
    sdrpp_source_t source);
SDRPP_MOBILE_API uint32_t sdrpp_source_get_center_frequency(
    sdrpp_source_t source);
SDRPP_MOBILE_API void sdrpp_source_disconnect(sdrpp_source_t source);
SDRPP_MOBILE_API int sdrpp_source_is_connected(sdrpp_source_t source);

SDRPP_MOBILE_API int sdrpp_source_set_frequency(
    sdrpp_source_t source,
    uint32_t frequency_hz);
SDRPP_MOBILE_API int sdrpp_source_set_sample_rate(
    sdrpp_source_t source,
    uint32_t sample_rate_hz);
SDRPP_MOBILE_API int sdrpp_source_set_tuner_agc(
    sdrpp_source_t source,
    int enabled);
SDRPP_MOBILE_API int sdrpp_source_set_gain_index(
    sdrpp_source_t source,
    int index);
SDRPP_MOBILE_API int sdrpp_source_set_gain_tenth_db(
    sdrpp_source_t source,
    int gain_tenth_db);
SDRPP_MOBILE_API int sdrpp_source_set_ppm(
    sdrpp_source_t source,
    int ppm);
SDRPP_MOBILE_API int sdrpp_source_set_rtl_agc(
    sdrpp_source_t source,
    int enabled);
SDRPP_MOBILE_API int sdrpp_source_set_direct_sampling(
    sdrpp_source_t source,
    int mode);
SDRPP_MOBILE_API int sdrpp_source_set_offset_tuning(
    sdrpp_source_t source,
    int enabled);
SDRPP_MOBILE_API int sdrpp_source_set_bias_tee(
    sdrpp_source_t source,
    int enabled);
SDRPP_MOBILE_API int sdrpp_source_set_rf_bandwidth(
    sdrpp_source_t source,
    double bandwidth_hz);

/* Non-blocking drains from the native source worker. */
SDRPP_MOBILE_API size_t sdrpp_source_read_audio(
    sdrpp_source_t source,
    int16_t* out_pcm,
    size_t capacity_samples);
SDRPP_MOBILE_API size_t sdrpp_source_read_spectrum(
    sdrpp_source_t source,
    float* out_db,
    size_t capacity_bins);

SDRPP_MOBILE_API int sdrpp_source_get_last_error(
    sdrpp_source_t source,
    char* out_error,
    size_t capacity);

SDRPP_MOBILE_API uint32_t sdrpp_dsp_output_sample_rate(void);

/* Returns a short implementation/build identifier for diagnostics. */
SDRPP_MOBILE_API const char* sdrpp_dsp_backend_name(void);

#ifdef __cplusplus
}
#endif
