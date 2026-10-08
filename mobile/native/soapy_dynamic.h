#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dsp/stream.h>
#include <dsp/types.h>

namespace mobile {

class SoapyDynamicClient {
public:
    explicit SoapyDynamicClient(dsp::stream<dsp::complex_t>* output);
    ~SoapyDynamicClient();

    static bool runtimeAvailable();
    static std::vector<std::string> enumerate(
        const std::string& filter = std::string());

    bool open(
        const std::string& deviceArgs,
        uint32_t requestedSampleRate,
        uint32_t frequencyHz,
        double bandwidthHz,
        double gainDb,
        bool agc,
        std::size_t channel = 0);

    void close();

    bool setFrequency(uint32_t frequencyHz);
    bool setSampleRate(uint32_t sampleRateHz);
    bool setBandwidth(double bandwidthHz);
    bool setGain(double gainDb);
    bool setAgc(bool enabled);

    bool isOpen() const;
    uint32_t sampleRate() const;
    uint32_t frequency() const;
    std::string driverKey() const;
    std::string hardwareKey() const;
    std::string lastError() const;

private:
    void workerLoop();
    void setError(const std::string& message);

    dsp::stream<dsp::complex_t>* output = nullptr;

    mutable std::mutex mutex;
    void* device = nullptr;
    void* stream = nullptr;
    std::size_t channel = 0;
    std::atomic<bool> running{false};
    std::thread worker;

    uint32_t currentSampleRate = 0;
    uint32_t currentFrequency = 0;
    double currentBandwidth = 0.0;
    double currentGain = 0.0;
    bool currentAgc = false;
    std::string currentDriver;
    std::string currentHardware;
    std::string error;
};

} // namespace mobile
