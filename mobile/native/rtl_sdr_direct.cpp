#include "rtl_sdr_direct.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace mobile {

namespace {

#if defined(_WIN32)
void* openLibrary(const char* name) {
    return reinterpret_cast<void*>(LoadLibraryA(name));
}
void closeLibrary(void* handle) {
    if (handle) {
        FreeLibrary(reinterpret_cast<HMODULE>(handle));
    }
}
void* loadSymbol(void* handle, const char* name) {
    return reinterpret_cast<void*>(
        GetProcAddress(reinterpret_cast<HMODULE>(handle), name));
}
#else
void* openLibrary(const char* name) {
    return dlopen(name, RTLD_NOW | RTLD_LOCAL);
}
void closeLibrary(void* handle) {
    if (handle) {
        dlclose(handle);
    }
}
void* loadSymbol(void* handle, const char* name) {
    return dlsym(handle, name);
}
#endif

template <typename T>
bool bindSymbol(void* library, const char* name, T& target) {
    target = reinterpret_cast<T>(loadSymbol(library, name));
    return target != nullptr;
}

} // namespace

struct RtlSdrDirectClient::Api {
    using AsyncCallback =
        void (*)(unsigned char*, uint32_t, void*);

    int (*openSysDevice)(void**, int) = nullptr;
    int (*close)(void*) = nullptr;
    int (*setSampleRate)(void*, uint32_t) = nullptr;
    uint32_t (*getSampleRate)(void*) = nullptr;
    int (*setCenterFrequency)(void*, uint32_t) = nullptr;
    uint32_t (*getCenterFrequency)(void*) = nullptr;
    int (*setFreqCorrection)(void*, int) = nullptr;
    int (*setTunerBandwidth)(void*, uint32_t) = nullptr;
    int (*setDirectSampling)(void*, int) = nullptr;
    int (*setBiasTee)(void*, int) = nullptr;
    int (*setAgcMode)(void*, int) = nullptr;
    int (*setTunerGainMode)(void*, int) = nullptr;
    int (*setTunerGain)(void*, int) = nullptr;
    int (*getTunerGains)(void*, int*) = nullptr;
    int (*setOffsetTuning)(void*, int) = nullptr;
    int (*resetBuffer)(void*) = nullptr;
    int (*readAsync)(
        void*,
        AsyncCallback,
        void*,
        uint32_t,
        uint32_t) = nullptr;
    int (*cancelAsync)(void*) = nullptr;
};

RtlSdrDirectClient::RtlSdrDirectClient(
    dsp::stream<dsp::complex_t>* outputStream)
    : output(outputStream) {}

RtlSdrDirectClient::~RtlSdrDirectClient() {
    close();
    unloadApi();
}

bool RtlSdrDirectClient::loadApi() {
    if (api && library) {
        return true;
    }

#if defined(_WIN32)
    const char* names[] = {"rtlsdr.dll", "librtlsdr.dll"};
#elif defined(__APPLE__)
    const char* names[] = {"librtlsdr.dylib"};
#else
    const char* names[] = {"librtlsdr.so", "librtlsdr.so.0"};
#endif

    for (const char* name : names) {
        library = openLibrary(name);
        if (library) {
            break;
        }
    }

    if (!library) {
        setError(
            "librtlsdr is not packaged for this platform");
        return false;
    }

    auto next = std::make_unique<Api>();
    bool ok = true;
    ok &= bindSymbol(
        library,
        "rtlsdr_open_sys_dev",
        next->openSysDevice);
    ok &= bindSymbol(library, "rtlsdr_close", next->close);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_sample_rate",
        next->setSampleRate);
    ok &= bindSymbol(
        library,
        "rtlsdr_get_sample_rate",
        next->getSampleRate);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_center_freq",
        next->setCenterFrequency);
    ok &= bindSymbol(
        library,
        "rtlsdr_get_center_freq",
        next->getCenterFrequency);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_freq_correction",
        next->setFreqCorrection);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_tuner_bandwidth",
        next->setTunerBandwidth);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_direct_sampling",
        next->setDirectSampling);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_bias_tee",
        next->setBiasTee);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_agc_mode",
        next->setAgcMode);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_tuner_gain_mode",
        next->setTunerGainMode);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_tuner_gain",
        next->setTunerGain);
    ok &= bindSymbol(
        library,
        "rtlsdr_get_tuner_gains",
        next->getTunerGains);
    ok &= bindSymbol(
        library,
        "rtlsdr_set_offset_tuning",
        next->setOffsetTuning);
    ok &= bindSymbol(
        library,
        "rtlsdr_reset_buffer",
        next->resetBuffer);
    ok &= bindSymbol(
        library,
        "rtlsdr_read_async",
        next->readAsync);
    ok &= bindSymbol(
        library,
        "rtlsdr_cancel_async",
        next->cancelAsync);

    if (!ok) {
        setError(
            "librtlsdr does not expose the Android system-device API");
        closeLibrary(library);
        library = nullptr;
        return false;
    }

    api = std::move(next);
    return true;
}

void RtlSdrDirectClient::unloadApi() {
    api.reset();
    closeLibrary(library);
    library = nullptr;
}

bool RtlSdrDirectClient::open(
    int systemFd,
    uint32_t sampleRateHz,
    uint32_t frequencyHz) {
    close();

    if (!output || systemFd < 0) {
        setError("Invalid RTL-SDR USB file descriptor");
        return false;
    }
    if (!loadApi()) {
        return false;
    }

    void* openedDevice = nullptr;
    if (api->openSysDevice(&openedDevice, systemFd) < 0 ||
        !openedDevice) {
        setError(
            "rtlsdr_open_sys_dev failed. Check Android USB permission.");
        return false;
    }

    device = openedDevice;
    currentSampleRate.store(sampleRateHz);
    currentFrequency.store(frequencyHz);

    const bool configured =
        api->setSampleRate(device, sampleRateHz) >= 0 &&
        api->setCenterFrequency(device, frequencyHz) >= 0 &&
        api->setTunerBandwidth(device, 0) >= 0;

    if (!configured) {
        setError("Could not configure RTL-SDR USB device");
        api->close(device);
        device = nullptr;
        return false;
    }

    int gainCount = api->getTunerGains(device, nullptr);
    gains.clear();
    if (gainCount > 0 && gainCount < 1024) {
        gains.resize(static_cast<std::size_t>(gainCount));
        const int readCount =
            api->getTunerGains(device, gains.data());
        if (readCount <= 0) {
            gains.clear();
        }
        else {
            gains.resize(
                static_cast<std::size_t>(readCount));
            std::sort(gains.begin(), gains.end());
        }
    }

    api->setTunerGainMode(device, 0);
    api->setAgcMode(device, 0);
    api->setFreqCorrection(device, 0);
    api->setDirectSampling(device, 0);
    api->setBiasTee(device, 0);
    api->setOffsetTuning(device, 0);
    api->resetBuffer(device);

    output->clearReadStop();
    output->clearWriteStop();

    running.store(true);
    opened.store(true);
    {
        std::lock_guard<std::mutex> lock(mutex);
        error.clear();
    }
    workerThread =
        std::thread(&RtlSdrDirectClient::worker, this);
    return true;
}

void RtlSdrDirectClient::close() {
    running.store(false);
    opened.store(false);

    if (device && api) {
        try {
            api->cancelAsync(device);
        }
        catch (...) {
        }
    }

    if (output) {
        output->stopWriter();
    }

    if (workerThread.joinable()) {
        workerThread.join();
    }

    if (device && api) {
        api->close(device);
        device = nullptr;
    }

    if (output) {
        output->clearWriteStop();
        output->clearReadStop();
    }
}

bool RtlSdrDirectClient::isOpen() const {
    return opened.load() &&
        running.load() &&
        device != nullptr;
}

bool RtlSdrDirectClient::setFrequency(
    uint32_t frequencyHz) {
    if (!device || !api) {
        return false;
    }

    // Match SDR++'s retry behavior; some RTL tuners do not
    // immediately report the requested frequency after retune.
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (api->setCenterFrequency(
                device,
                frequencyHz) < 0) {
            continue;
        }
        if (api->getCenterFrequency(device) == frequencyHz) {
            currentFrequency.store(frequencyHz);
            return true;
        }
    }
    return false;
}

bool RtlSdrDirectClient::setSampleRate(
    uint32_t sampleRateHz) {
    if (!device || !api ||
        api->setSampleRate(device, sampleRateHz) < 0) {
        return false;
    }
    currentSampleRate.store(
        api->getSampleRate(device));
    return true;
}

bool RtlSdrDirectClient::setTunerAgc(bool enabled) {
    return device && api &&
        api->setTunerGainMode(device, enabled ? 0 : 1) >= 0;
}

bool RtlSdrDirectClient::setGainIndex(int index) {
    if (!device || !api || gains.empty()) {
        return false;
    }
    const int clamped =
        std::clamp(
            index,
            0,
            static_cast<int>(gains.size()) - 1);
    return api->setTunerGain(
        device,
        gains[static_cast<std::size_t>(clamped)]) >= 0;
}

bool RtlSdrDirectClient::setGainTenthDb(
    int gainTenthDb) {
    return device && api &&
        api->setTunerGain(device, gainTenthDb) >= 0;
}

bool RtlSdrDirectClient::setPpm(int ppm) {
    return device && api &&
        api->setFreqCorrection(device, ppm) >= 0;
}

bool RtlSdrDirectClient::setRtlAgc(bool enabled) {
    return device && api &&
        api->setAgcMode(device, enabled ? 1 : 0) >= 0;
}

bool RtlSdrDirectClient::setDirectSampling(int mode) {
    return device && api &&
        api->setDirectSampling(
            device,
            std::clamp(mode, 0, 2)) >= 0;
}

bool RtlSdrDirectClient::setOffsetTuning(bool enabled) {
    return device && api &&
        api->setOffsetTuning(device, enabled ? 1 : 0) >= 0;
}

bool RtlSdrDirectClient::setBiasTee(bool enabled) {
    return device && api &&
        api->setBiasTee(device, enabled ? 1 : 0) >= 0;
}

uint32_t RtlSdrDirectClient::sampleRate() const {
    return currentSampleRate.load();
}

std::string RtlSdrDirectClient::lastError() const {
    std::lock_guard<std::mutex> lock(mutex);
    return error;
}

void RtlSdrDirectClient::worker() {
    if (!device || !api) {
        running.store(false);
        opened.store(false);
        return;
    }

    api->resetBuffer(device);

    const uint32_t rate =
        std::max<uint32_t>(
            250000u,
            currentSampleRate.load());
    const int rounded =
        static_cast<int>(
            std::lround(
                static_cast<double>(rate) /
                (200.0 * 512.0))) *
        512;
    const uint32_t asyncLength =
        static_cast<uint32_t>(
            std::max(512, rounded));

    const int result = api->readAsync(
        device,
        &RtlSdrDirectClient::asyncCallback,
        this,
        0,
        asyncLength);

    if (result < 0 && running.load()) {
        setError("RTL-SDR asynchronous read failed");
    }

    running.store(false);
    opened.store(false);
}

void RtlSdrDirectClient::asyncCallback(
    unsigned char* buffer,
    uint32_t length,
    void* context) {
    auto* self =
        static_cast<RtlSdrDirectClient*>(context);
    if (!self || !self->running.load() ||
        !self->output || !buffer || length < 2) {
        return;
    }

    const std::size_t sampleCount =
        static_cast<std::size_t>(length / 2u);
    std::size_t offset = 0;

    while (offset < sampleCount &&
           self->running.load()) {
        const std::size_t chunk =
            std::min<std::size_t>(
                sampleCount - offset,
                STREAM_BUFFER_SIZE);

        for (std::size_t i = 0; i < chunk; ++i) {
            const std::size_t src =
                (offset + i) * 2u;
            self->output->writeBuf[i].re =
                (static_cast<float>(buffer[src]) - 127.4f) /
                128.0f;
            self->output->writeBuf[i].im =
                (static_cast<float>(buffer[src + 1u]) - 127.4f) /
                128.0f;
        }

        if (!self->output->swap(
                static_cast<int>(chunk))) {
            break;
        }
        offset += chunk;
    }
}

void RtlSdrDirectClient::setError(
    const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    error = value;
}

} // namespace mobile
