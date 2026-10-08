#pragma once
#include <cmath>
#include <cstddef>
#include <cstdlib>

#define FFTW_FORWARD (-1)
#define FFTW_BACKWARD (1)
#define FFTW_ESTIMATE (0u)

typedef float fftwf_complex[2];

struct fftwf_plan_s {
    int n;
    fftwf_complex* in;
    fftwf_complex* out;
    int sign;
};

typedef fftwf_plan_s* fftwf_plan;

static inline void* fftwf_malloc(std::size_t size) {
    return std::malloc(size);
}

static inline void fftwf_free(void* ptr) {
    std::free(ptr);
}

static inline fftwf_plan fftwf_plan_dft_1d(
    int n,
    fftwf_complex* in,
    fftwf_complex* out,
    int sign,
    unsigned /*flags*/) {
    auto* plan = static_cast<fftwf_plan>(std::malloc(sizeof(fftwf_plan_s)));
    if (!plan) {
        return nullptr;
    }
    plan->n = n;
    plan->in = in;
    plan->out = out;
    plan->sign = sign;
    return plan;
}

static inline void fftwf_destroy_plan(fftwf_plan plan) {
    std::free(plan);
}

static inline void fftwf_execute(fftwf_plan plan) {
    if (!plan) {
        return;
    }
    constexpr float kPi = 3.14159265358979323846f;
    const int n = plan->n;
    for (int k = 0; k < n; ++k) {
        float sumRe = 0.0f;
        float sumIm = 0.0f;
        for (int t = 0; t < n; ++t) {
            const float angle =
                static_cast<float>(plan->sign) *
                2.0f * kPi *
                static_cast<float>(k * t) /
                static_cast<float>(n);
            const float c = std::cos(angle);
            const float s = std::sin(angle);
            const float re = plan->in[t][0];
            const float im = plan->in[t][1];
            sumRe += re * c - im * s;
            sumIm += re * s + im * c;
        }
        plan->out[k][0] = sumRe;
        plan->out[k][1] = sumIm;
    }
}
