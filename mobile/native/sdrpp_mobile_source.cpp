#include "include/sdrpp_mobile_api.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dsp/stream.h>
#include <dsp/types.h>
#include "../../source_modules/rtl_tcp_source/src/rtl_tcp_client.h"

namespace {

constexpr std::size_t kSpectrumBins = 256;
constexpr std::size_t kFftSize = 1024;
constexpr std::size_t kMaxBufferedPcm =
    48000u * 2u * 6u; // 6 seconds stereo.

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

        iqStream.stopReader();
        if (consumerThread.joinable()) {
            consumerThread.join();
        }
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
        std::lock_guard<std::mutex> lock(clientMutex);
        return rtlClient && rtlClient->isOpen();
    }

    int setFrequency(uint32_t value) {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            frequency = value;
        }
        sdrpp_dsp_reset(engine);
        return withClient([&](rtltcp::Client& client) {
            client.setFrequency(value);
        });
    }

    int setSampleRate(uint32_t value) {
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
    std::atomic<bool> running{false};
    std::atomic<bool> connected{false};

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
