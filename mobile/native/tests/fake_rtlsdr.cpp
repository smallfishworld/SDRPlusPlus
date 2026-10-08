#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

struct FakeRtlDevice {
    std::atomic<bool> cancel{false};
    uint32_t sampleRate = 1024000;
    uint32_t frequency = 127250000;
    int gain = 0;
};

extern "C" {

int rtlsdr_open_sys_dev(void** out, int /*fd*/) {
    if (!out) {
        return -1;
    }
    *out = new FakeRtlDevice();
    return 0;
}

int rtlsdr_close(void* dev) {
    delete static_cast<FakeRtlDevice*>(dev);
    return 0;
}

int rtlsdr_set_sample_rate(void* dev, uint32_t value) {
    static_cast<FakeRtlDevice*>(dev)->sampleRate = value;
    return 0;
}

uint32_t rtlsdr_get_sample_rate(void* dev) {
    return static_cast<FakeRtlDevice*>(dev)->sampleRate;
}

int rtlsdr_set_center_freq(void* dev, uint32_t value) {
    static_cast<FakeRtlDevice*>(dev)->frequency = value;
    return 0;
}

uint32_t rtlsdr_get_center_freq(void* dev) {
    return static_cast<FakeRtlDevice*>(dev)->frequency;
}

int rtlsdr_set_freq_correction(void*, int) { return 0; }
int rtlsdr_set_tuner_bandwidth(void*, uint32_t) { return 0; }
int rtlsdr_set_direct_sampling(void*, int) { return 0; }
int rtlsdr_set_bias_tee(void*, int) { return 0; }
int rtlsdr_set_agc_mode(void*, int) { return 0; }
int rtlsdr_set_tuner_gain_mode(void*, int) { return 0; }

int rtlsdr_set_tuner_gain(void* dev, int value) {
    static_cast<FakeRtlDevice*>(dev)->gain = value;
    return 0;
}

int rtlsdr_get_tuner_gains(void*, int* values) {
    static const int gains[] = {-99, -40, 0, 77, 144, 197, 280, 496};
    if (!values) {
        return static_cast<int>(sizeof(gains) / sizeof(gains[0]));
    }
    for (std::size_t i = 0; i < sizeof(gains) / sizeof(gains[0]); ++i) {
        values[i] = gains[i];
    }
    return static_cast<int>(sizeof(gains) / sizeof(gains[0]));
}

int rtlsdr_set_offset_tuning(void*, int) { return 0; }
int rtlsdr_reset_buffer(void*) { return 0; }

int rtlsdr_cancel_async(void* dev) {
    static_cast<FakeRtlDevice*>(dev)->cancel.store(true);
    return 0;
}

int rtlsdr_read_async(
    void* raw,
    void (*callback)(unsigned char*, uint32_t, void*),
    void* context,
    uint32_t /*bufferCount*/,
    uint32_t bufferLength) {
    auto* dev = static_cast<FakeRtlDevice*>(raw);
    dev->cancel.store(false);

    const uint32_t length =
        std::max<uint32_t>(2048, bufferLength & ~1u);
    std::vector<unsigned char> bytes(length);
    constexpr double pi = 3.14159265358979323846;
    constexpr double audioHz = 1000.0;
    constexpr double deviationHz = 2500.0;
    double phase = 0.0;
    uint64_t sampleIndex = 0;

    while (!dev->cancel.load() && sampleIndex < dev->sampleRate * 3ull) {
        const uint32_t complexCount = length / 2u;
        for (uint32_t i = 0; i < complexCount; ++i) {
            const double t =
                static_cast<double>(sampleIndex + i) /
                static_cast<double>(dev->sampleRate);
            const double mod = std::sin(2.0 * pi * audioHz * t);
            phase +=
                2.0 * pi * deviationHz * mod /
                static_cast<double>(dev->sampleRate);
            bytes[i * 2u] = static_cast<unsigned char>(
                std::lround(127.5 + 100.0 * std::cos(phase)));
            bytes[i * 2u + 1u] = static_cast<unsigned char>(
                std::lround(127.5 + 100.0 * std::sin(phase)));
        }

        callback(bytes.data(), length, context);
        sampleIndex += complexCount;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return 0;
}

} // extern "C"
