#include "../include/sdrpp_mobile_api.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
    constexpr uint32_t sampleRate = 1024000;
    constexpr double audioHz = 1000.0;
    constexpr double deviationHz = 2500.0;
    constexpr double pi = 3.14159265358979323846;

    sdrpp_engine_t engine =
        sdrpp_dsp_create(sampleRate, SDRPP_MODE_NFM, 12500.0f);
    if (!engine) {
        return 1;
    }

    if (sdrpp_dsp_set_fm_ifnr(engine, 1, 1) != 0) {
        sdrpp_dsp_destroy(engine);
        return 2;
    }

    constexpr size_t complexPerChunk = 32768;
    std::vector<uint8_t> iq(complexPerChunk * 2);
    std::vector<int16_t> pcm(65536);

    double phase = 0.0;
    uint64_t sampleIndex = 0;
    const uint64_t totalSamples =
        static_cast<uint64_t>(sampleRate) / 2;
    uint64_t audioEnergy = 0;

    while (sampleIndex < totalSamples) {
        const size_t count = static_cast<size_t>(
            std::min<uint64_t>(
                complexPerChunk,
                totalSamples - sampleIndex));

        for (size_t i = 0; i < count; ++i) {
            const double t =
                static_cast<double>(sampleIndex + i) /
                static_cast<double>(sampleRate);
            const double mod =
                std::sin(2.0 * pi * audioHz * t);
            phase +=
                2.0 * pi * deviationHz * mod /
                static_cast<double>(sampleRate);

            iq[i * 2] = static_cast<uint8_t>(
                std::lround(127.5 + 100.0 * std::cos(phase)));
            iq[i * 2 + 1] = static_cast<uint8_t>(
                std::lround(127.5 + 100.0 * std::sin(phase)));
        }

        const size_t written = sdrpp_dsp_process_u8(
            engine,
            iq.data(),
            count * 2,
            pcm.data(),
            pcm.size());

        for (size_t i = 0; i < written; ++i) {
            audioEnergy += static_cast<uint64_t>(
                std::abs(static_cast<int>(pcm[i])));
        }

        sampleIndex += count;
    }

    std::printf(
        "FM IFNR output energy=%llu\n",
        static_cast<unsigned long long>(audioEnergy));

    sdrpp_dsp_destroy(engine);

    if (audioEnergy < 100000) {
        std::fprintf(stderr, "FM IFNR produced no usable audio\n");
        return 3;
    }
    return 0;
}
