#include "include/sdrpp_mobile_api.h"
#include "remote_sources.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <chrono>
#include <regex>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dsp/stream.h>
#include <dsp/types.h>
#include <utils/net.h>
#include "../../source_modules/rtl_tcp_source/src/rtl_tcp_client.h"
#include "../../source_modules/file_source/src/wavreader.h"

namespace {

constexpr std::size_t kSpectrumBins = 256;
constexpr std::size_t kFftSize = 1024;
constexpr std::size_t kMaxBufferedPcm =
    48000u * 2u * 6u; // 6 seconds stereo.

enum class MobileSourceKind : int {
    None = 0,
    RtlTcp = 1,
    File = 2,
    Network = 3,
    SdrppServer = 4,
    SpyServer = 5,
};

class MobileSourceRuntime {
public:
    explicit MobileSourceRuntime(sdrpp_engine_t dspEngine)
        : engine(dspEngine) {}

    ~MobileSourceRuntime() {
        disconnect();
    }

    int connectRtlTcp(
        const char* host,
        int port,
        uint32_t sampleRateHz,
        uint32_t frequencyHz) {
        if (!engine || !host || !*host || port <= 0 || port > 65535) {
            setError("Invalid RTL-TCP connection parameters");
            return -1;
        }

        disconnect();

        {
            std::lock_guard<std::mutex> lock(stateMutex);
            sampleRate = sampleRateHz;
            frequency = frequencyHz;
            lastError.clear();
        }

        iqStream.clearReadStop();
        iqStream.clearWriteStop();
        running.store(true);

        consumerThread =
            std::thread(&MobileSourceRuntime::consumerLoop, this);

        try {
            auto client =
                rtltcp::connect(&iqStream, std::string(host), port);

            {
                std::lock_guard<std::mutex> lock(clientMutex);
                rtlClient = client;
            }

            // Match the official RTL-TCP source module startup sequence.
            client->setFrequency(frequencyHz);
            client->setSampleRate(sampleRateHz);
            client->setPPM(ppm);
            client->setDirectSampling(directSampling);
            client->setAGCMode(rtlAgc ? 1 : 0);
            client->setBiasTee(biasTee);
            client->setOffsetTuning(offsetTuning);
            if (tunerAgc) {
                client->setGainMode(0);
            }
            else {
                client->setGainMode(1);
                client->setGainIndex(gainIndex);
            }

            connected.store(client->isOpen());
            if (!connected.load()) {
                setError("RTL-TCP socket closed during startup");
                disconnect();
                return -1;
            }
            sourceKind.store(
                static_cast<int>(MobileSourceKind::RtlTcp));
            centerFrequency.store(frequencyHz);
            sdrpp_dsp_set_frequency_offset(engine, 0.0f);
            return 0;
        }
        catch (const std::exception& e) {
            setError(e.what());
        }
        catch (...) {
            setError("Unknown RTL-TCP connection error");
        }

        disconnect();
        return -1;
    }

    int openFile(
        const char* path,
        bool float32Mode,
        uint32_t requestedCenterFrequency) {
        if (!engine || !path || !*path) {
            setError("Invalid IQ file path");
            return -1;
        }

        disconnect();

        try {
            auto reader = std::make_unique<WavReader>(
                std::string(path));
            if (!reader->isValid()) {
                setError("Invalid WAV IQ file");
                return -1;
            }

            const uint32_t fileSampleRate =
                reader->getSampleRate();
            if (fileSampleRate == 0) {
                setError("IQ WAV sample rate is zero");
                return -1;
            }

            if (!float32Mode) {
                if (reader->getChannelCount() != 2 ||
                    reader->getBitDepth() != 16) {
                    setError(
                        "PCM IQ WAV must be stereo 16-bit, or enable Float32 mode");
                    return -1;
                }
            }

            uint32_t fileCenter = requestedCenterFrequency;
            if (fileCenter == 0) {
                fileCenter = parseFrequencyFromPath(path);
            }
            if (fileCenter == 0) {
                fileCenter = 100000000u;
            }

            {
                std::lock_guard<std::mutex> lock(stateMutex);
                sampleRate = fileSampleRate;
                frequency = fileCenter;
                lastError.clear();
            }
            centerFrequency.store(fileCenter);
            fileFloat32 = float32Mode;
            fileReader = std::move(reader);

            sdrpp_dsp_set_sample_rate(engine, fileSampleRate);
            sdrpp_dsp_set_frequency_offset(engine, 0.0f);

            iqStream.clearReadStop();
            iqStream.clearWriteStop();
            running.store(true);
            connected.store(true);
            sourceKind.store(
                static_cast<int>(MobileSourceKind::File));

            consumerThread =
                std::thread(&MobileSourceRuntime::consumerLoop, this);
            fileThread =
                std::thread(&MobileSourceRuntime::fileProducerLoop, this);
            return 0;
        }
        catch (const std::exception& e) {
            setError(e.what());
        }
        catch (...) {
            setError("Unknown IQ file source error");
        }

        disconnect();
        return -1;
    }

    int connectNetwork(
        const char* host,
        int port,
        uint32_t sampleRateHz,
        int protocol,
        int sampleType,
        uint32_t requestedCenterFrequency) {
        if (!engine || !host || !*host ||
            port <= 0 || port > 65535 ||
            protocol < 0 || protocol > 1 ||
            sampleType < 0 || sampleType > 3) {
            setError("Invalid Network Source parameters");
            return -1;
        }

        disconnect();

        try {
            std::shared_ptr<net::Socket> socket;
            if (protocol == 0) {
                socket = net::connect(
                    std::string(host),
                    port);
            }
            else {
                socket = net::openudp(
                    std::string(host),
                    port,
                    "0.0.0.0",
                    port,
                    true);
            }

            {
                std::lock_guard<std::mutex> lock(networkMutex);
                networkSocket = socket;
            }

            const uint32_t center =
                requestedCenterFrequency != 0
                    ? requestedCenterFrequency
                    : 100000000u;

            {
                std::lock_guard<std::mutex> lock(stateMutex);
                sampleRate = std::max<uint32_t>(
                    1000u,
                    sampleRateHz);
                frequency = center;
                lastError.clear();
            }
            centerFrequency.store(center);
            networkProtocol = protocol;
            networkSampleType = sampleType;

            sdrpp_dsp_set_sample_rate(
                engine,
                std::max<uint32_t>(1000u, sampleRateHz));
            sdrpp_dsp_set_frequency_offset(engine, 0.0f);

            iqStream.clearReadStop();
            iqStream.clearWriteStop();
            running.store(true);
            connected.store(true);
            sourceKind.store(
                static_cast<int>(MobileSourceKind::Network));

            consumerThread =
                std::thread(&MobileSourceRuntime::consumerLoop, this);
            networkThread =
                std::thread(
                    &MobileSourceRuntime::networkProducerLoop,
                    this);
            return 0;
        }
        catch (const std::exception& e) {
            setError(e.what());
        }
        catch (...) {
            setError("Unknown Network Source error");
        }

        disconnect();
        return -1;
    }

    int connectSdrppServer(
        const char* host,
        int port,
        uint32_t frequencyHz) {
        if (!engine || !host || !*host ||
            port <= 0 || port > 65535) {
            setError("Invalid SDR++ Server parameters");
            return -1;
        }

        disconnect();

        try {
            auto client =
                std::make_unique<mobile::SdrppServerSourceClient>(
                    &iqStream);

            iqStream.clearReadStop();
            iqStream.clearWriteStop();
            running.store(true);
            consumerThread =
                std::thread(&MobileSourceRuntime::consumerLoop, this);

            if (!client->connect(
                    std::string(host),
                    port,
                    frequencyHz)) {
                setError(client->lastError());
                running.store(false);
                iqStream.stopReader();
                iqStream.stopWriter();
                if (consumerThread.joinable()) {
                    consumerThread.join();
                }
                iqStream.clearReadStop();
                iqStream.clearWriteStop();
                return -1;
            }

            {
                std::lock_guard<std::mutex> lock(remoteMutex);
                sdrppServerClient = std::move(client);
            }

            const uint32_t actualRate =
                std::max<uint32_t>(
                    1000u,
                    sdrppServerClient->sampleRate());
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                sampleRate = actualRate;
                frequency = frequencyHz;
                lastError.clear();
            }
            centerFrequency.store(frequencyHz);
            sdrpp_dsp_set_sample_rate(engine, actualRate);
            sdrpp_dsp_set_frequency_offset(engine, 0.0f);

            connected.store(true);
            sourceKind.store(
                static_cast<int>(MobileSourceKind::SdrppServer));
            return 0;
        }
        catch (const std::exception& e) {
            setError(e.what());
        }
        catch (...) {
            setError("Unknown SDR++ Server source error");
        }

        disconnect();
        return -1;
    }

    int connectSpyServer(
        const char* host,
        int port,
        uint32_t requestedSampleRate,
        uint32_t frequencyHz) {
        if (!engine || !host || !*host ||
            port <= 0 || port > 65535) {
            setError("Invalid SpyServer parameters");
            return -1;
        }

        disconnect();

        try {
            auto client =
                std::make_unique<mobile::SpyServerSourceClient>(
                    &iqStream);

            iqStream.clearReadStop();
            iqStream.clearWriteStop();
            running.store(true);
            consumerThread =
                std::thread(&MobileSourceRuntime::consumerLoop, this);

            if (!client->connect(
                    std::string(host),
                    port,
                    requestedSampleRate,
                    frequencyHz)) {
                setError(client->lastError());
                running.store(false);
                iqStream.stopReader();
                iqStream.stopWriter();
                if (consumerThread.joinable()) {
                    consumerThread.join();
                }
                iqStream.clearReadStop();
                iqStream.clearWriteStop();
                return -1;
            }

            {
                std::lock_guard<std::mutex> lock(remoteMutex);
                spyServerClient = std::move(client);
            }

            const uint32_t actualRate =
                std::max<uint32_t>(
                    1000u,
                    spyServerClient->sampleRate());
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                sampleRate = actualRate;
                frequency = frequencyHz;
                lastError.clear();
            }
            centerFrequency.store(frequencyHz);
            sdrpp_dsp_set_sample_rate(engine, actualRate);
            sdrpp_dsp_set_frequency_offset(engine, 0.0f);

            connected.store(true);
            sourceKind.store(
                static_cast<int>(MobileSourceKind::SpyServer));
            return 0;
        }
        catch (const std::exception& e) {
            setError(e.what());
        }
        catch (...) {
            setError("Unknown SpyServer source error");
        }

        disconnect();
        return -1;
    }

    int kind() const {
        return sourceKind.load();
    }

    uint32_t getSampleRate() const {
        std::lock_guard<std::mutex> lock(stateMutex);
        return sampleRate;
    }

    uint32_t getCenterFrequency() const {
        return centerFrequency.load();
    }

    void disconnect() {
        connected.store(false);
        running.store(false);

        std::shared_ptr<rtltcp::Client> client;
        {
            std::lock_guard<std::mutex> lock(clientMutex);
            client = rtlClient;
            rtlClient.reset();
        }

        if (client) {
            try {
                client->close();
            }
            catch (...) {
            }
        }

        std::shared_ptr<net::Socket> network;
        {
            std::lock_guard<std::mutex> lock(networkMutex);
            network = networkSocket;
            networkSocket.reset();
        }
        if (network) {
            try {
                network->close();
            }
            catch (...) {
            }
        }

        iqStream.stopWriter();
        iqStream.stopReader();

        if (fileThread.joinable()) {
            fileThread.join();
        }
        if (networkThread.joinable()) {
            networkThread.join();
        }
        if (consumerThread.joinable()) {
            consumerThread.join();
        }

        fileReader.reset();
        fileFloat32 = false;
        sourceKind.store(
            static_cast<int>(MobileSourceKind::None));
        centerFrequency.store(0);

        iqStream.clearReadStop();
        iqStream.clearWriteStop();

        {
            std::lock_guard<std::mutex> lock(audioMutex);
            audioQueue.clear();
        }
        {
            std::lock_guard<std::mutex> lock(spectrumMutex);
            spectrumValid = false;
        }
    }

    bool isConnected() const {
        if (!connected.load()) {
            return false;
        }

        const auto kindValue =
            static_cast<MobileSourceKind>(sourceKind.load());
        if (kindValue == MobileSourceKind::File) {
            return running.load() && fileReader != nullptr;
        }
        if (kindValue == MobileSourceKind::Network) {
            std::lock_guard<std::mutex> lock(networkMutex);
            return networkSocket && networkSocket->isOpen();
        }
        if (kindValue == MobileSourceKind::RtlTcp) {
            std::lock_guard<std::mutex> lock(clientMutex);
            return rtlClient && rtlClient->isOpen();
        }
        return false;
    }

    int setFrequency(uint32_t value) {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            frequency = value;
        }

        const auto kindValue =
            static_cast<MobileSourceKind>(sourceKind.load());
        if (kindValue == MobileSourceKind::File ||
            kindValue == MobileSourceKind::Network) {
            const int64_t offset =
                static_cast<int64_t>(value) -
                static_cast<int64_t>(centerFrequency.load());
            sdrpp_dsp_set_frequency_offset(
                engine,
                static_cast<float>(offset));
            sdrpp_dsp_reset(engine);
            return 0;
        }

        sdrpp_dsp_set_frequency_offset(engine, 0.0f);
        sdrpp_dsp_reset(engine);
        return withClient([&](rtltcp::Client& client) {
            client.setFrequency(value);
        });
    }

    int setSampleRate(uint32_t value) {
        const auto kindValue =
            static_cast<MobileSourceKind>(sourceKind.load());
        if (kindValue == MobileSourceKind::File) {
            return -1;
        }
        if (kindValue == MobileSourceKind::Network) {
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                sampleRate = std::max<uint32_t>(1000u, value);
            }
            sdrpp_dsp_set_sample_rate(
                engine,
                std::max<uint32_t>(1000u, value));
            return 0;
        }
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            sampleRate = value;
        }
        sdrpp_dsp_set_sample_rate(engine, value);
        return withClient([&](rtltcp::Client& client) {
            client.setSampleRate(value);
        });
    }

    int setTunerAgc(bool enabled) {
        tunerAgc = enabled;
        return withClient([&](rtltcp::Client& client) {
            client.setGainMode(enabled ? 0 : 1);
            if (!enabled) {
                client.setGainIndex(gainIndex);
            }
        });
    }

    int setGainIndex(int value) {
        gainIndex = std::clamp(value, 0, 1000);
        return withClient([&](rtltcp::Client& client) {
            client.setGainIndex(gainIndex);
        });
    }

    int setGainTenthDb(int value) {
        gainTenthDb = value;
        return withClient([&](rtltcp::Client& client) {
            client.setGain(gainTenthDb);
        });
    }

    int setPpm(int value) {
        ppm = value;
        return withClient([&](rtltcp::Client& client) {
            client.setPPM(ppm);
        });
    }

    int setRtlAgc(bool enabled) {
        rtlAgc = enabled;
        return withClient([&](rtltcp::Client& client) {
            client.setAGCMode(enabled ? 1 : 0);
        });
    }

    int setDirectSampling(int value) {
        directSampling = std::clamp(value, 0, 2);
        return withClient([&](rtltcp::Client& client) {
            client.setDirectSampling(directSampling);
        });
    }

    int setOffsetTuning(bool enabled) {
        offsetTuning = enabled;
        return withClient([&](rtltcp::Client& client) {
            client.setOffsetTuning(enabled);
        });
    }

    int setBiasTee(bool enabled) {
        biasTee = enabled;
        return withClient([&](rtltcp::Client& client) {
            client.setBiasTee(enabled);
        });
    }

    std::size_t readAudio(
        int16_t* out,
        std::size_t capacity) {
        if (!out || capacity == 0) {
            return 0;
        }

        std::lock_guard<std::mutex> lock(audioMutex);
        const std::size_t count =
            std::min<std::size_t>(capacity, audioQueue.size());
        for (std::size_t i = 0; i < count; ++i) {
            out[i] = audioQueue.front();
            audioQueue.pop_front();
        }
        return count;
    }

    std::size_t readSpectrum(
        float* out,
        std::size_t capacity) {
        if (!out || capacity == 0) {
            return 0;
        }

        std::lock_guard<std::mutex> lock(spectrumMutex);
        if (!spectrumValid) {
            return 0;
        }

        const std::size_t count =
            std::min<std::size_t>(capacity, spectrum.size());
        std::copy_n(spectrum.begin(), count, out);
        return count;
    }

    int copyLastError(char* out, std::size_t capacity) {
        if (!out || capacity == 0) {
            return 0;
        }

        std::lock_guard<std::mutex> lock(stateMutex);
        const std::size_t count =
            std::min<std::size_t>(capacity - 1, lastError.size());
        std::memcpy(out, lastError.data(), count);
        out[count] = '\0';
        return static_cast<int>(count);
    }

private:
    static uint32_t parseFrequencyFromPath(
        const std::string& path) {
        try {
            const std::regex expr("([0-9]+)Hz");
            std::smatch match;
            if (!std::regex_search(path, match, expr) ||
                match.size() < 2) {
                return 0;
            }

            const unsigned long long value =
                std::stoull(match[1].str());
            if (value > 0xFFFFFFFFull) {
                return 0;
            }
            return static_cast<uint32_t>(value);
        }
        catch (...) {
            return 0;
        }
    }

    void fileProducerLoop() {
        WavReader* reader = fileReader.get();
        if (!reader) {
            connected.store(false);
            return;
        }

        const uint32_t sr =
            std::max<uint32_t>(1u, reader->getSampleRate());
        const std::size_t blockSize =
            std::max<std::size_t>(
                256u,
                std::min<std::size_t>(
                    static_cast<std::size_t>(sr / 200u),
                    static_cast<std::size_t>(STREAM_BUFFER_SIZE)));

        std::vector<int16_t> pcmIq;
        std::vector<dsp::complex_t> floatIq;
        if (fileFloat32) {
            floatIq.resize(blockSize);
        }
        else {
            pcmIq.resize(blockSize * 2u);
        }

        auto nextWake = std::chrono::steady_clock::now();
        const auto blockDuration =
            std::chrono::microseconds(
                static_cast<int64_t>(
                    (1000000.0 *
                     static_cast<double>(blockSize)) /
                    static_cast<double>(sr)));

        while (running.load()) {
            if (fileFloat32) {
                reader->readSamples(
                    floatIq.data(),
                    blockSize * sizeof(dsp::complex_t));
                std::memcpy(
                    iqStream.writeBuf,
                    floatIq.data(),
                    blockSize * sizeof(dsp::complex_t));
            }
            else {
                reader->readSamples(
                    pcmIq.data(),
                    pcmIq.size() * sizeof(int16_t));
                for (std::size_t i = 0; i < blockSize; ++i) {
                    iqStream.writeBuf[i].re =
                        static_cast<float>(pcmIq[i * 2]) /
                        32768.0f;
                    iqStream.writeBuf[i].im =
                        static_cast<float>(pcmIq[i * 2 + 1]) /
                        32768.0f;
                }
            }

            if (!iqStream.swap(
                    static_cast<int>(blockSize))) {
                break;
            }

            nextWake += blockDuration;
            std::this_thread::sleep_until(nextWake);
        }
    }

    static std::size_t networkSampleSize(int type) {
        switch (type) {
            case 0: return sizeof(int8_t) * 2u;
            case 1: return sizeof(int16_t) * 2u;
            case 2: return sizeof(int32_t) * 2u;
            case 3: return sizeof(float) * 2u;
            default: return sizeof(int16_t) * 2u;
        }
    }

    void networkProducerLoop() {
        std::shared_ptr<net::Socket> socket;
        {
            std::lock_guard<std::mutex> lock(networkMutex);
            socket = networkSocket;
        }
        if (!socket) {
            connected.store(false);
            return;
        }

        uint32_t sr;
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            sr = std::max<uint32_t>(1000u, sampleRate);
        }

        const std::size_t blockSize =
            std::max<std::size_t>(
                256u,
                std::min<std::size_t>(
                    static_cast<std::size_t>(sr / 200u),
                    static_cast<std::size_t>(STREAM_BUFFER_SIZE)));
        const std::size_t sampleSize =
            networkSampleSize(networkSampleType);
        const bool forceSize = networkProtocol == 0;
        const std::size_t frameSamples =
            forceSize
                ? blockSize
                : static_cast<std::size_t>(STREAM_BUFFER_SIZE);
        std::vector<uint8_t> buffer(
            frameSamples * sampleSize);

        while (running.load() && socket->isOpen()) {
            const int bytes = socket->recv(
                buffer.data(),
                buffer.size(),
                forceSize);
            if (bytes <= 0) {
                break;
            }

            const std::size_t count =
                static_cast<std::size_t>(bytes) / sampleSize;
            if (count == 0) {
                continue;
            }

            switch (networkSampleType) {
                case 0: {
                    const auto* in =
                        reinterpret_cast<const int8_t*>(
                            buffer.data());
                    for (std::size_t i = 0; i < count; ++i) {
                        iqStream.writeBuf[i].re =
                            static_cast<float>(in[i * 2]) /
                            128.0f;
                        iqStream.writeBuf[i].im =
                            static_cast<float>(in[i * 2 + 1]) /
                            128.0f;
                    }
                    break;
                }
                case 1: {
                    const auto* in =
                        reinterpret_cast<const int16_t*>(
                            buffer.data());
                    for (std::size_t i = 0; i < count; ++i) {
                        iqStream.writeBuf[i].re =
                            static_cast<float>(in[i * 2]) /
                            32768.0f;
                        iqStream.writeBuf[i].im =
                            static_cast<float>(in[i * 2 + 1]) /
                            32768.0f;
                    }
                    break;
                }
                case 2: {
                    const auto* in =
                        reinterpret_cast<const int32_t*>(
                            buffer.data());
                    for (std::size_t i = 0; i < count; ++i) {
                        iqStream.writeBuf[i].re =
                            static_cast<float>(
                                static_cast<double>(in[i * 2]) /
                                2147483647.0);
                        iqStream.writeBuf[i].im =
                            static_cast<float>(
                                static_cast<double>(in[i * 2 + 1]) /
                                2147483647.0);
                    }
                    break;
                }
                case 3: {
                    const auto* in =
                        reinterpret_cast<const float*>(
                            buffer.data());
                    std::memcpy(
                        iqStream.writeBuf,
                        in,
                        count * sizeof(dsp::complex_t));
                    break;
                }
                default:
                    break;
            }

            if (!iqStream.swap(static_cast<int>(count))) {
                break;
            }
        }

        connected.store(false);
    }

    template <typename F>
    int withClient(F&& fn) {
        std::lock_guard<std::mutex> lock(clientMutex);
        if (!rtlClient || !rtlClient->isOpen()) {
            return -1;
        }
        try {
            fn(*rtlClient);
            return 0;
        }
        catch (...) {
            return -1;
        }
    }

    void setError(const std::string& value) {
        std::lock_guard<std::mutex> lock(stateMutex);
        lastError = value;
    }

    void consumerLoop() {
        std::vector<int16_t> pcm;
        uint64_t samplesUntilSpectrum = 0;

        while (running.load()) {
            const int count = iqStream.read();
            if (count < 0) {
                break;
            }

            if (count == 0) {
                iqStream.flush();
                continue;
            }

            uint32_t currentSampleRate;
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                currentSampleRate = sampleRate;
            }

            if (samplesUntilSpectrum <=
                static_cast<uint64_t>(count)) {
                if (count >= static_cast<int>(kFftSize)) {
                    computeSpectrum(iqStream.readBuf);
                }
                samplesUntilSpectrum =
                    std::max<uint32_t>(1024u, currentSampleRate / 20u);
            }
            else {
                samplesUntilSpectrum -=
                    static_cast<uint64_t>(count);
            }

            const std::size_t pcmCapacity =
                std::max<std::size_t>(
                    static_cast<std::size_t>(count) * 2u + 8192u,
                    16384u);
            if (pcm.size() < pcmCapacity) {
                pcm.resize(pcmCapacity);
            }

            const std::size_t written =
                sdrpp_dsp_process_cf32(
                    engine,
                    reinterpret_cast<const float*>(iqStream.readBuf),
                    static_cast<std::size_t>(count),
                    pcm.data(),
                    pcm.size());

            iqStream.flush();

            if (written > 0) {
                std::lock_guard<std::mutex> lock(audioMutex);
                const std::size_t overflow =
                    audioQueue.size() + written > kMaxBufferedPcm
                        ? audioQueue.size() + written - kMaxBufferedPcm
                        : 0;
                for (std::size_t i = 0; i < overflow; ++i) {
                    audioQueue.pop_front();
                }
                audioQueue.insert(
                    audioQueue.end(),
                    pcm.begin(),
                    pcm.begin() + static_cast<std::ptrdiff_t>(written));
            }

            std::lock_guard<std::mutex> lock(clientMutex);
            if (rtlClient && !rtlClient->isOpen()) {
                connected.store(false);
            }
        }
    }

    void computeSpectrum(const dsp::complex_t* input) {
        std::array<double, kFftSize> re{};
        std::array<double, kFftSize> im{};

        constexpr double pi =
            3.1415926535897932384626433832795;

        for (std::size_t i = 0; i < kFftSize; ++i) {
            const double window =
                0.5 -
                0.5 * std::cos(
                    (2.0 * pi * static_cast<double>(i)) /
                    static_cast<double>(kFftSize - 1));
            re[i] = input[i].re * window;
            im[i] = input[i].im * window;
        }

        std::size_t j = 0;
        for (std::size_t i = 1; i < kFftSize; ++i) {
            std::size_t bit = kFftSize >> 1;
            while (j & bit) {
                j ^= bit;
                bit >>= 1;
            }
            j ^= bit;
            if (i < j) {
                std::swap(re[i], re[j]);
                std::swap(im[i], im[j]);
            }
        }

        for (std::size_t len = 2;
             len <= kFftSize;
             len <<= 1) {
            const double angle =
                -2.0 * pi / static_cast<double>(len);
            const double wLenRe = std::cos(angle);
            const double wLenIm = std::sin(angle);

            for (std::size_t base = 0;
                 base < kFftSize;
                 base += len) {
                double wRe = 1.0;
                double wIm = 0.0;
                const std::size_t half = len >> 1;

                for (std::size_t k = 0; k < half; ++k) {
                    const std::size_t even = base + k;
                    const std::size_t odd = even + half;

                    const double oddRe =
                        re[odd] * wRe - im[odd] * wIm;
                    const double oddIm =
                        re[odd] * wIm + im[odd] * wRe;

                    const double evenRe = re[even];
                    const double evenIm = im[even];

                    re[even] = evenRe + oddRe;
                    im[even] = evenIm + oddIm;
                    re[odd] = evenRe - oddRe;
                    im[odd] = evenIm - oddIm;

                    const double nextWRe =
                        wRe * wLenRe - wIm * wLenIm;
                    wIm =
                        wRe * wLenIm + wIm * wLenRe;
                    wRe = nextWRe;
                }
            }
        }

        std::array<float, kSpectrumBins> next{};
        constexpr std::size_t merge =
            kFftSize / kSpectrumBins;
        const double normDb =
            20.0 * std::log10(static_cast<double>(kFftSize));

        for (std::size_t outBin = 0;
             outBin < kSpectrumBins;
             ++outBin) {
            double maxDb = -160.0;
            for (std::size_t m = 0; m < merge; ++m) {
                const std::size_t shifted =
                    (outBin * merge + m + kFftSize / 2) %
                    kFftSize;
                const double magnitude =
                    std::sqrt(
                        re[shifted] * re[shifted] +
                        im[shifted] * im[shifted]);
                const double db =
                    20.0 * std::log10(magnitude + 1e-12) -
                    normDb;
                maxDb = std::max(maxDb, db);
            }
            next[outBin] = static_cast<float>(maxDb);
        }

        {
            std::lock_guard<std::mutex> lock(spectrumMutex);
            spectrum = next;
            spectrumValid = true;
        }
    }

    sdrpp_engine_t engine = nullptr;
    dsp::stream<dsp::complex_t> iqStream;

    mutable std::mutex clientMutex;
    std::shared_ptr<rtltcp::Client> rtlClient;

    std::thread consumerThread;
    std::thread fileThread;
    std::thread networkThread;
    std::atomic<bool> running{false};
    std::atomic<bool> connected{false};
    std::atomic<int> sourceKind{
        static_cast<int>(MobileSourceKind::None)};
    std::atomic<uint32_t> centerFrequency{0};

    std::unique_ptr<WavReader> fileReader;
    bool fileFloat32 = false;

    mutable std::mutex networkMutex;
    std::shared_ptr<net::Socket> networkSocket;
    int networkProtocol = 0;
    int networkSampleType = 1;

    mutable std::mutex stateMutex;
    uint32_t sampleRate = 1024000;
    uint32_t frequency = 127250000;
    std::string lastError;

    bool tunerAgc = true;
    bool rtlAgc = false;
    int gainIndex = 0;
    int gainTenthDb = 0;
    int ppm = 0;
    int directSampling = 0;
    bool offsetTuning = false;
    bool biasTee = false;

    std::mutex audioMutex;
    std::deque<int16_t> audioQueue;

    std::mutex spectrumMutex;
    std::array<float, kSpectrumBins> spectrum{};
    bool spectrumValid = false;
};

MobileSourceRuntime* asSource(sdrpp_source_t source) {
    return reinterpret_cast<MobileSourceRuntime*>(source);
}

} // namespace

extern "C" {

sdrpp_source_t sdrpp_source_create(sdrpp_engine_t engine) {
    if (!engine) {
        return nullptr;
    }
    try {
        return reinterpret_cast<sdrpp_source_t>(
            new MobileSourceRuntime(engine));
    }
    catch (...) {
        return nullptr;
    }
}

void sdrpp_source_destroy(sdrpp_source_t source) {
    delete asSource(source);
}

int sdrpp_source_connect_rtl_tcp(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    uint32_t frequency_hz) {
    if (!source) {
        return -1;
    }
    return asSource(source)->connectRtlTcp(
        host,
        port,
        sample_rate_hz,
        frequency_hz);
}

int sdrpp_source_open_file(
    sdrpp_source_t source,
    const char* path,
    int float32_mode,
    uint32_t center_frequency_hz) {
    if (!source) {
        return -1;
    }
    return asSource(source)->openFile(
        path,
        float32_mode != 0,
        center_frequency_hz);
}

int sdrpp_source_connect_network(
    sdrpp_source_t source,
    const char* host,
    int port,
    uint32_t sample_rate_hz,
    int protocol,
    int sample_type,
    uint32_t center_frequency_hz) {
    if (!source) {
        return -1;
    }
    return asSource(source)->connectNetwork(
        host,
        port,
        sample_rate_hz,
        protocol,
        sample_type,
        center_frequency_hz);
}

int sdrpp_source_get_kind(sdrpp_source_t source) {
    return source ? asSource(source)->kind() : 0;
}

uint32_t sdrpp_source_get_sample_rate(
    sdrpp_source_t source) {
    return source
        ? asSource(source)->getSampleRate()
        : 0;
}

uint32_t sdrpp_source_get_center_frequency(
    sdrpp_source_t source) {
    return source
        ? asSource(source)->getCenterFrequency()
        : 0;
}

void sdrpp_source_disconnect(sdrpp_source_t source) {
    if (source) {
        asSource(source)->disconnect();
    }
}

int sdrpp_source_is_connected(sdrpp_source_t source) {
    return source && asSource(source)->isConnected() ? 1 : 0;
}

int sdrpp_source_set_frequency(
    sdrpp_source_t source,
    uint32_t frequency_hz) {
    return source
        ? asSource(source)->setFrequency(frequency_hz)
        : -1;
}

int sdrpp_source_set_sample_rate(
    sdrpp_source_t source,
    uint32_t sample_rate_hz) {
    return source
        ? asSource(source)->setSampleRate(sample_rate_hz)
        : -1;
}

int sdrpp_source_set_tuner_agc(
    sdrpp_source_t source,
    int enabled) {
    return source
        ? asSource(source)->setTunerAgc(enabled != 0)
        : -1;
}

int sdrpp_source_set_gain_index(
    sdrpp_source_t source,
    int index) {
    return source
        ? asSource(source)->setGainIndex(index)
        : -1;
}

int sdrpp_source_set_gain_tenth_db(
    sdrpp_source_t source,
    int gain_tenth_db) {
    return source
        ? asSource(source)->setGainTenthDb(gain_tenth_db)
        : -1;
}

int sdrpp_source_set_ppm(
    sdrpp_source_t source,
    int ppm) {
    return source
        ? asSource(source)->setPpm(ppm)
        : -1;
}

int sdrpp_source_set_rtl_agc(
    sdrpp_source_t source,
    int enabled) {
    return source
        ? asSource(source)->setRtlAgc(enabled != 0)
        : -1;
}

int sdrpp_source_set_direct_sampling(
    sdrpp_source_t source,
    int mode) {
    return source
        ? asSource(source)->setDirectSampling(mode)
        : -1;
}

int sdrpp_source_set_offset_tuning(
    sdrpp_source_t source,
    int enabled) {
    return source
        ? asSource(source)->setOffsetTuning(enabled != 0)
        : -1;
}

int sdrpp_source_set_bias_tee(
    sdrpp_source_t source,
    int enabled) {
    return source
        ? asSource(source)->setBiasTee(enabled != 0)
        : -1;
}

size_t sdrpp_source_read_audio(
    sdrpp_source_t source,
    int16_t* out_pcm,
    size_t capacity_samples) {
    return source
        ? asSource(source)->readAudio(
              out_pcm,
              capacity_samples)
        : 0;
}

size_t sdrpp_source_read_spectrum(
    sdrpp_source_t source,
    float* out_db,
    size_t capacity_bins) {
    return source
        ? asSource(source)->readSpectrum(
              out_db,
              capacity_bins)
        : 0;
}

int sdrpp_source_get_last_error(
    sdrpp_source_t source,
    char* out_error,
    size_t capacity) {
    return source
        ? asSource(source)->copyLastError(
              out_error,
              capacity)
        : 0;
}

} // extern "C"
