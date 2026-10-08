#include "../include/sdrpp_mobile_api.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

int main() {
    sdrpp_engine_t engine =
        sdrpp_dsp_create(1024000, SDRPP_MODE_NFM, 12500.0f);
    if (!engine) {
        return 1;
    }

    sdrpp_source_t source = sdrpp_source_create(engine);
    if (!source) {
        sdrpp_dsp_destroy(engine);
        return 2;
    }

    if (sdrpp_source_connect_rtl_sdr_fd(
            source,
            42,
            1024000,
            145100000) != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(source, error, sizeof(error));
        std::fprintf(stderr, "RTL-SDR USB connect failed: %s\n", error);
        return 3;
    }

    if (sdrpp_source_get_kind(source) != 6) {
        return 4;
    }

    sdrpp_source_set_tuner_agc(source, 0);
    sdrpp_source_set_gain_tenth_db(source, 197);
    sdrpp_source_set_ppm(source, 2);
    sdrpp_source_set_rtl_agc(source, 0);
    sdrpp_source_set_bias_tee(source, 0);
    sdrpp_source_set_direct_sampling(source, 0);
    sdrpp_source_set_frequency(source, 145125000);

    std::vector<int16_t> pcm(48000 * 2);
    std::vector<float> spectrum(256);
    std::size_t totalPcm = 0;
    std::size_t bins = 0;

    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::seconds(4);

    while (std::chrono::steady_clock::now() < deadline) {
        totalPcm += sdrpp_source_read_audio(
            source,
            pcm.data(),
            pcm.size());
        const auto n = sdrpp_source_read_spectrum(
            source,
            spectrum.data(),
            spectrum.size());
        if (n > 0) {
            bins = n;
        }
        if (totalPcm > 4000 && bins == 256) {
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(20));
    }

    std::printf(
        "direct RTL-SDR USB: sr=%u pcm=%zu spectrum=%zu\n",
        sdrpp_source_get_sample_rate(source),
        totalPcm,
        bins);

    sdrpp_source_disconnect(source);
    sdrpp_source_destroy(source);
    sdrpp_dsp_destroy(engine);

    if (totalPcm <= 4000) {
        return 5;
    }
    if (bins != 256) {
        return 6;
    }
    return 0;
}
