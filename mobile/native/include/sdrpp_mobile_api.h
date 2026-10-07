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

/*
 * Clear resampler/demodulator/AGC history after retuning so old-channel state
 * and buffered audio cannot mute or contaminate the new frequency.
 */
SDRPP_MOBILE_API void sdrpp_dsp_reset(sdrpp_engine_t engine);

/*
 * Process interleaved unsigned 8-bit RTL-TCP IQ:
 *   I0 Q0 I1 Q1 ...
 *
 * Output is signed 16-bit mono PCM at 48 kHz. The return value is the number
 * of PCM samples written to out_pcm.
 */
SDRPP_MOBILE_API size_t sdrpp_dsp_process_u8(
    sdrpp_engine_t engine,
    const uint8_t* iq,
    size_t iq_bytes,
    int16_t* out_pcm,
    size_t out_capacity_samples);

SDRPP_MOBILE_API uint32_t sdrpp_dsp_output_sample_rate(void);

/* Returns a short implementation/build identifier for diagnostics. */
SDRPP_MOBILE_API const char* sdrpp_dsp_backend_name(void);

#ifdef __cplusplus
}
#endif
