#include "../include/sdrpp_mobile_api.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace {

#pragma pack(push, 1)
struct WavHeader {
    char riff[4] = {'R', 'I', 'F', 'F'};
    uint32_t fileSize = 0;
    char wave[4] = {'W', 'A', 'V', 'E'};
    char fmt[4] = {'f', 'm', 't', ' '};
    uint32_t fmtSize = 16;
    uint16_t format = 1;
    uint16_t channels = 2;
    uint32_t sampleRate = 1024000;
    uint32_t byteRate = 1024000 * 4;
    uint16_t blockAlign = 4;
    uint16_t bits = 16;
    char data[4] = {'d', 'a', 't', 'a'};
    uint32_t dataSize = 0;
};
#pragma pack(pop)

bool writeIqWav(const std::string& path) {
    constexpr uint32_t sampleRate = 1024000;
    constexpr double audioHz = 1000.0;
    constexpr double deviationHz = 2500.0;
    constexpr double pi = 3.14159265358979323846;
    constexpr uint32_t seconds = 2;
    const std::size_t complexCount =
        static_cast<std::size_t>(sampleRate) * seconds;

    std::vector<int16_t> data(complexCount * 2);
    double phase = 0.0;

    for (std::size_t i = 0; i < complexCount; ++i) {
        const double t =
            static_cast<double>(i) /
            static_cast<double>(sampleRate);
        const double mod =
            std::sin(2.0 * pi * audioHz * t);
        phase +=
            2.0 * pi * deviationHz * mod /
            static_cast<double>(sampleRate);
        data[i * 2] = static_cast<int16_t>(
            std::lround(26000.0 * std::cos(phase)));
        data[i * 2 + 1] = static_cast<int16_t>(
            std::lround(26000.0 * std::sin(phase)));
    }

    WavHeader header;
    header.dataSize =
        static_cast<uint32_t>(data.size() * sizeof(int16_t));
    header.fileSize =
        header.dataSize + sizeof(WavHeader) - 8;

    std::ofstream out(path, std::ios::binary);
    if (!out) {
        return false;
    }
    out.write(
        reinterpret_cast<const char*>(&header),
        sizeof(header));
    out.write(
        reinterpret_cast<const char*>(data.data()),
        static_cast<std::streamsize>(header.dataSize));
    return out.good();
}

} // namespace

int main() {
    const std::string path =
        "/tmp/145100000Hz_sdrpp_mobile_iq.wav";
    if (!writeIqWav(path)) {
        std::fprintf(stderr, "failed to create IQ WAV\n");
        return 1;
    }

    sdrpp_engine_t engine =
        sdrpp_dsp_create(
            1024000,
            SDRPP_MODE_NFM,
            12500.0f);
    if (!engine) {
        return 2;
    }

    sdrpp_source_t source = sdrpp_source_create(engine);
    if (!source) {
        sdrpp_dsp_destroy(engine);
        return 3;
    }

    if (sdrpp_source_open_file(
            source,
            path.c_str(),
            0,
            0) != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(
            source,
            error,
            sizeof(error));
        std::fprintf(
            stderr,
            "open file failed: %s\n",
            error);
        return 4;
    }

    if (sdrpp_source_get_kind(source) != 2) {
        std::fprintf(stderr, "wrong source kind\n");
        return 5;
    }

    if (sdrpp_source_get_sample_rate(source) != 1024000) {
        std::fprintf(stderr, "wrong file sample rate\n");
        return 6;
    }

    if (sdrpp_source_get_center_frequency(source) !=
        145100000u) {
        std::fprintf(
            stderr,
            "filename center frequency was not detected\n");
        return 7;
    }

    // Exercise file-source VFO offset path.
    sdrpp_source_set_frequency(source, 145100000u);

    std::vector<int16_t> pcm(48000 * 2);
    std::vector<float> spectrum(256);
    std::size_t totalPcm = 0;
    std::size_t bins = 0;

    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::seconds(3);

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
        "native File Source: pcm=%zu spectrum=%zu\n",
        totalPcm,
        bins);

    sdrpp_source_disconnect(source);
    sdrpp_source_destroy(source);
    sdrpp_dsp_destroy(engine);
    std::remove(path.c_str());

    if (totalPcm <= 4000) {
        return 8;
    }
    if (bins != 256) {
        return 9;
    }
    return 0;
}
