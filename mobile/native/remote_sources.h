#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include <dsp/stream.h>
#include <dsp/types.h>
#include <utils/net.h>

namespace mobile {

class SpyServerSourceClient {
public:
    explicit SpyServerSourceClient(dsp::stream<dsp::complex_t>* output);
    ~SpyServerSourceClient();

    bool connect(
        const std::string& host,
        int port,
        uint32_t requestedSampleRate,
        uint32_t frequencyHz);
    void close();
    bool isOpen() const;

    bool setFrequency(uint32_t frequencyHz);
    bool setSampleRate(uint32_t requestedSampleRate);
    bool setGain(uint32_t gainIndex);

    uint32_t sampleRate() const;
    std::string lastError() const;

private:
    struct DeviceInfo {
        uint32_t deviceType = 0;
        uint32_t maxSampleRate = 0;
        uint32_t decimationStages = 0;
        uint32_t maxGainIndex = 0;
        uint32_t minFrequency = 0;
        uint32_t maxFrequency = 0;
        uint32_t minIqDecimation = 0;
        uint32_t forcedIqFormat = 0;
    };

    bool readMessage(uint32_t& messageType, uint32_t& flags, std::string& body);
    bool sendSetting(uint32_t setting, uint32_t value);
    bool configureSampleRate(uint32_t requestedSampleRate);
    void worker();
    void pushIq(const uint8_t* data, std::size_t bytes, uint32_t messageType, uint32_t flags);
    void setError(const std::string& value);

    dsp::stream<dsp::complex_t>* output = nullptr;
    mutable std::mutex mutex;
    std::shared_ptr<net::Socket> socket;
    std::thread workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> connected{false};
    std::atomic<uint32_t> currentSampleRate{1000000};
    std::atomic<uint32_t> currentFrequency{100000000};
    DeviceInfo deviceInfo;
    int decimation = 0;
    std::string error;
};

class SdrppServerSourceClient {
public:
    explicit SdrppServerSourceClient(dsp::stream<dsp::complex_t>* output);
    ~SdrppServerSourceClient();

    bool connect(
        const std::string& host,
        int port,
        uint32_t frequencyHz);
    void close();
    bool isOpen() const;

    bool setFrequency(uint32_t frequencyHz);
    uint32_t sampleRate() const;
    std::string lastError() const;

private:
    bool sendCommand(uint32_t command, const void* data, std::size_t bytes);
    bool readPacket(uint32_t& type, std::string& payload, int timeoutMs);
    bool awaitUi();
    void worker();
    void handleCommand(const uint8_t* data, std::size_t size);
    void handleBaseband(const uint8_t* data, std::size_t size);
    void pushComplex(const dsp::complex_t* data, std::size_t count);
    void setError(const std::string& value);

    dsp::stream<dsp::complex_t>* output = nullptr;
    mutable std::mutex mutex;
    std::shared_ptr<net::Socket> socket;
    std::thread workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> connected{false};
    std::atomic<uint32_t> currentSampleRate{1000000};
    std::atomic<uint32_t> currentFrequency{100000000};
    std::string error;
};

} // namespace mobile
