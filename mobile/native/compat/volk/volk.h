#pragma once

/*
 * Portable VOLK compatibility layer for the mobile FFI bridge.
 *
 * SDR++'s DSP headers are written against VOLK. The normal desktop/Android
 * SDR++ build links the real VOLK library. The Flutter bridge initially uses
 * these scalar-compatible entry points so the exact SDR++ DSP classes can be
 * embedded without pulling the full SDR++ GUI/module build into the APK.
 *
 * This file intentionally implements only the primitives required by the
 * official demodulator/resampler classes used by sdrpp_mobile_dsp.cpp.
 */

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#ifndef VOLK_VERSION
#define VOLK_VERSION 030100
#endif

struct lv_32fc_t {
    float r;
    float i;
};

static inline lv_32fc_t lv_cmake(float r, float i) {
    return lv_32fc_t{r, i};
}

static inline int volk_get_alignment() {
    return 32;
}

static inline void* volk_malloc(std::size_t size, std::size_t alignment) {
#if defined(_WIN32)
    return _aligned_malloc(size, alignment);
#else
    void* ptr = nullptr;
    if (posix_memalign(&ptr, alignment, size) != 0) {
        return nullptr;
    }
    return ptr;
#endif
}

static inline void volk_free(void* ptr) {
#if defined(_WIN32)
    _aligned_free(ptr);
#else
    std::free(ptr);
#endif
}

static inline void volk_32fc_magnitude_32f(
    float* out,
    const lv_32fc_t* in,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = std::sqrt(in[n].r * in[n].r + in[n].i * in[n].i);
    }
}

static inline void volk_32f_x2_dot_prod_32f(
    float* result,
    const float* input,
    const float* taps,
    unsigned int count) {
    float acc = 0.0f;
    for (unsigned int n = 0; n < count; ++n) {
        acc += input[n] * taps[n];
    }
    *result = acc;
}

static inline void volk_32fc_32f_dot_prod_32fc(
    lv_32fc_t* result,
    const lv_32fc_t* input,
    const float* taps,
    unsigned int count) {
    float re = 0.0f;
    float im = 0.0f;
    for (unsigned int n = 0; n < count; ++n) {
        re += input[n].r * taps[n];
        im += input[n].i * taps[n];
    }
    result->r = re;
    result->i = im;
}

static inline void volk_32fc_x2_dot_prod_32fc(
    lv_32fc_t* result,
    const lv_32fc_t* a,
    const lv_32fc_t* b,
    unsigned int count) {
    float re = 0.0f;
    float im = 0.0f;
    for (unsigned int n = 0; n < count; ++n) {
        re += a[n].r * b[n].r - a[n].i * b[n].i;
        im += a[n].r * b[n].i + a[n].i * b[n].r;
    }
    result->r = re;
    result->i = im;
}

static inline void volk_32fc_deinterleave_real_32f(
    float* out,
    const lv_32fc_t* in,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = in[n].r;
    }
}

static inline void volk_32f_x2_interleave_32fc(
    lv_32fc_t* out,
    const float* i,
    const float* q,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n].r = i[n];
        out[n].i = q[n];
    }
}

static inline void volk_32f_accumulator_s32f(
    float* result,
    const float* input,
    unsigned int count) {
    float acc = 0.0f;
    for (unsigned int n = 0; n < count; ++n) {
        acc += input[n];
    }
    *result = acc;
}

static inline void volk_32f_s32f_multiply_32f(
    float* out,
    const float* input,
    float scalar,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = input[n] * scalar;
    }
}

static inline void volk_32f_x2_multiply_32f(
    float* out,
    const float* a,
    const float* b,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = a[n] * b[n];
    }
}

static inline void volk_32fc_x2_multiply_32fc(
    lv_32fc_t* out,
    const lv_32fc_t* a,
    const lv_32fc_t* b,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n].r = a[n].r * b[n].r - a[n].i * b[n].i;
        out[n].i = a[n].r * b[n].i + a[n].i * b[n].r;
    }
}

static inline void volk_32f_x2_add_32f(
    float* out,
    const float* a,
    const float* b,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = a[n] + b[n];
    }
}

static inline void volk_32f_x2_subtract_32f(
    float* out,
    const float* a,
    const float* b,
    unsigned int count) {
    for (unsigned int n = 0; n < count; ++n) {
        out[n] = a[n] - b[n];
    }
}

static inline void volk_32fc_s32fc_x2_rotator2_32fc(
    lv_32fc_t* out,
    const lv_32fc_t* input,
    const lv_32fc_t* phase_inc,
    lv_32fc_t* phase,
    unsigned int count) {
    lv_32fc_t p = *phase;
    const lv_32fc_t inc = *phase_inc;

    for (unsigned int n = 0; n < count; ++n) {
        out[n].r = input[n].r * p.r - input[n].i * p.i;
        out[n].i = input[n].r * p.i + input[n].i * p.r;

        const float nr = p.r * inc.r - p.i * inc.i;
        const float ni = p.r * inc.i + p.i * inc.r;
        p.r = nr;
        p.i = ni;

        if ((n & 0xFFu) == 0xFFu) {
            const float norm = std::sqrt(p.r * p.r + p.i * p.i);
            if (norm > 0.0f) {
                p.r /= norm;
                p.i /= norm;
            }
        }
    }

    *phase = p;
}

static inline void volk_32fc_s32fc_x2_rotator_32fc(
    lv_32fc_t* out,
    const lv_32fc_t* input,
    lv_32fc_t phase_inc,
    lv_32fc_t* phase,
    unsigned int count) {
    volk_32fc_s32fc_x2_rotator2_32fc(
        out,
        input,
        &phase_inc,
        phase,
        count);
}
