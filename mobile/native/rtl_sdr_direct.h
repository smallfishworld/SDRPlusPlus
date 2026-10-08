#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dsp/stream.h>
#include <dsp/types.h>

namespace mobile {

class RtlSdrDirectClient {
public:
    explicit RtlSdrDirectClient(dsp::stream<dsp::complex_t>* output);
    ~RtlSdrDirectClient();

    bool open(
        int systemFd,
        uint32_t sampleRateHz,
        uint32_t frequencyHz);

    void close();
    bool isOpen() const;

    bool setFrequency(uint32_t frequencyHz);
    bool setSampleRate(uint32_t sampleRateHz);
    bool setTunerAgc(bool enabled);
    bool setGainIndex(int index);
    bool setGainTenthDb(int gainTenthDb);
    bool setPpm(int ppm);
    bool setRtlAgc(bool enabled);
    bool setDirectSampling(int mode);
    bool setOffsetTuning(bool enabled);
    bool setBiasTee(bool enabled);

    uint32_t sampleRate() const;
    std::string lastError() const;

private:
    struct Api;
    static void asyncCallback(
        unsigned char* buffer,
        uint32_t length,
        void* context);
    void worker();
    void setError(const std::string& value);
    bool loadApi();
    void unloadApi();

    dsp::stream<dsp::complex_t>* output = nullptr;
    std::unique_ptr<Api> api;
    void* device = nullptr;
    void* library = nullptr;
    std::thread workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> opened{false};
    std::atomic<uint32_t> currentSampleRate{1024000};
    std::atomic<uint32_t> currentFrequency{100000000};
    mutable std::mutex mutex;
    std::string error;
    std::vector<int> gains;
};

} // namespace mobile
