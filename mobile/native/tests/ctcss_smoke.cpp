#include "../include/sdrpp_mobile_api.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

int main() {
    constexpr uint32_t sampleRate = 1024000;
    constexpr double toneHz = 100.0;
    constexpr double deviationHz = 700.0;
    constexpr double pi = 3.14159265358979323846;

    sdrpp_engine_t engine =
        sdrpp_dsp_create(sampleRate, SDRPP_MODE_NFM, 12500.0f);
    if (!engine) {
        std::fprintf(stderr, "failed to create engine\n");
        return 1;
    }

    sdrpp_dsp_set_ctcss(engine, 1, -2);

    constexpr size_t complexPerChunk = 32768;
    std::vector<uint8_t> iq(complexPerChunk * 2);
    std::vector<int16_t> pcm(32768);

    double carrierPhase = 0.0;
    uint64_t sampleIndex = 0;
    const uint64_t totalSamples =
        static_cast<uint64_t>(sampleRate) * 4u;

    while (sampleIndex < totalSamples) {
        const size_t count = static_cast<size_t>(
            std::min<uint64_t>(
                complexPerChunk,
                totalSamples - sampleIndex));

        for (size_t i = 0; i < count; ++i) {
            const double t =
                static_cast<double>(sampleIndex + i) /
                static_cast<double>(sampleRate);
            const double audio =
                std::sin(2.0 * pi * toneHz * t);
            const double instantHz = deviationHz * audio;
            carrierPhase +=
                2.0 * pi * instantHz /
                static_cast<double>(sampleRate);

            const double ci = std::cos(carrierPhase);
            const double cq = std::sin(carrierPhase);
            iq[i * 2] = static_cast<uint8_t>(
                std::lround(127.5 + 100.0 * ci));
            iq[i * 2 + 1] = static_cast<uint8_t>(
                std::lround(127.5 + 100.0 * cq));
        }

        sdrpp_dsp_process_u8(
            engine,
            iq.data(),
            count * 2,
            pcm.data(),
            pcm.size());
        sampleIndex += count;
    }

    int toneIndex = -1;
    float detectedHz = 0.0f;
    const int valid =
        sdrpp_dsp_get_ctcss(engine, &toneIndex, &detectedHz);

    std::printf(
        "CTCSS valid=%d index=%d tone=%.1fHz\n",
        valid,
        toneIndex,
        detectedHz);

    sdrpp_dsp_destroy(engine);

    if (!valid) {
        std::fprintf(stderr, "no CTCSS tone detected\n");
        return 2;
    }
    if (std::fabs(detectedHz - 100.0f) > 3.0f) {
        std::fprintf(
            stderr,
            "unexpected CTCSS tone %.1fHz\n",
            detectedHz);
        return 3;
    }

    return 0;
}
