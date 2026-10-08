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

static inline bool fftwf_is_power_of_two(int n) {
    return n > 0 && (n & (n - 1)) == 0;
}

static inline void fftwf_execute(fftwf_plan plan) {
    if (!plan) {
        return;
    }
    constexpr float kPi = 3.14159265358979323846f;
    const int n = plan->n;

    if (fftwf_is_power_of_two(n)) {
        // Iterative radix-2 path keeps the Broadcast IFNR (32 bins) cheap
        // enough for mobile use. FFTW's backward transform is unnormalised,
        // so this compatibility path intentionally does not scale it.
        for (int i = 0; i < n; ++i) {
            int x = i;
            int r = 0;
            for (int bits = n; bits > 1; bits >>= 1) {
                r = (r << 1) | (x & 1);
                x >>= 1;
            }
            plan->out[r][0] = plan->in[i][0];
            plan->out[r][1] = plan->in[i][1];
        }

        for (int len = 2; len <= n; len <<= 1) {
            const float angle =
                static_cast<float>(plan->sign) *
                2.0f * kPi /
                static_cast<float>(len);
            const float wLenRe = std::cos(angle);
            const float wLenIm = std::sin(angle);
            const int half = len >> 1;

            for (int base = 0; base < n; base += len) {
                float wRe = 1.0f;
                float wIm = 0.0f;
                for (int j = 0; j < half; ++j) {
                    const int even = base + j;
                    const int odd = even + half;
                    const float oddRe =
                        plan->out[odd][0] * wRe -
                        plan->out[odd][1] * wIm;
                    const float oddIm =
                        plan->out[odd][0] * wIm +
                        plan->out[odd][1] * wRe;
                    const float evenRe = plan->out[even][0];
                    const float evenIm = plan->out[even][1];

                    plan->out[even][0] = evenRe + oddRe;
                    plan->out[even][1] = evenIm + oddIm;
                    plan->out[odd][0] = evenRe - oddRe;
                    plan->out[odd][1] = evenIm - oddIm;

                    const float nextRe =
                        wRe * wLenRe - wIm * wLenIm;
                    wIm = wRe * wLenIm + wIm * wLenRe;
                    wRe = nextRe;
                }
            }
        }
        return;
    }

    // Small non-power-of-two presets (9/15/31 bins) use a direct DFT.
    for (int k = 0; k < n; ++k) {
        float sumRe = 0.0f;
        float sumIm = 0.0f;
        for (int t = 0; t < n; ++t) {
            const float angle =
                static_cast<float>(plan->sign) *
                2.0f * kPi *
                static_cast<float>(k * t) /
                static_cast<float>(n);
            const float cs = std::cos(angle);
            const float sn = std::sin(angle);
            const float re = plan->in[t][0];
            const float im = plan->in[t][1];
            sumRe += re * cs - im * sn;
            sumIm += re * sn + im * cs;
        }
        plan->out[k][0] = sumRe;
        plan->out[k][1] = sumIm;
    }
}
