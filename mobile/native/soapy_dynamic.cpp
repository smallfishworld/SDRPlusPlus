#include "soapy_dynamic.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace mobile {
namespace {

constexpr int kSoapyRx = 1;
constexpr long kReadTimeoutUs = 200000;

struct SoapyKwargs {
    std::size_t size;
    char** keys;
    char** vals;
};

struct SoapyApi {
#if defined(_WIN32)
    HMODULE core = nullptr;
    std::vector<HMODULE> modules;
#else
    void* core = nullptr;
    std::vector<void*> modules;
#endif

    using Device = void;
    using Stream = void;

    using FnLastError = const char* (*)();
    using FnEnumerateStr =
        SoapyKwargs* (*)(const char*, std::size_t*);
    using FnKwargsToString = char* (*)(const SoapyKwargs*);
    using FnKwargsListClear = void (*)(SoapyKwargs*, std::size_t);
    using FnFree = void (*)(void*);
    using FnMakeStr = Device* (*)(const char*);
    using FnUnmake = int (*)(Device*);
    using FnGetString = char* (*)(const Device*);
    using FnSetRate =
        int (*)(Device*, int, std::size_t, double);
    using FnGetRate =
        double (*)(const Device*, int, std::size_t);
    using FnListRates =
        double* (*)(const Device*, int, std::size_t, std::size_t*);
    using FnSetFrequency =
        int (*)(Device*, int, std::size_t, double, const SoapyKwargs*);
    using FnGetFrequency =
        double (*)(const Device*, int, std::size_t);
    using FnSetBandwidth =
        int (*)(Device*, int, std::size_t, double);
    using FnListBandwidths =
        double* (*)(const Device*, int, std::size_t, std::size_t*);
    using FnHasGainMode =
        bool (*)(const Device*, int, std::size_t);
    using FnSetGainMode =
        int (*)(Device*, int, std::size_t, bool);
    using FnSetGain =
        int (*)(Device*, int, std::size_t, double);
    using FnSetupStream = Stream* (*)(
        Device*,
        int,
        const char*,
        const std::size_t*,
        std::size_t,
        const SoapyKwargs*);
    using FnCloseStream = int (*)(Device*, Stream*);
    using FnGetMtu = std::size_t (*)(const Device*, Stream*);
    using FnActivateStream =
        int (*)(Device*, Stream*, int, long long, std::size_t);
    using FnDeactivateStream =
        int (*)(Device*, Stream*, int, long long);
    using FnReadStream = int (*)(
        Device*,
        Stream*,
        void* const*,
        std::size_t,
        int*,
        long long*,
        long);

    FnLastError lastError = nullptr;
    FnEnumerateStr enumerateStr = nullptr;
    FnKwargsToString kwargsToString = nullptr;
    FnKwargsListClear kwargsListClear = nullptr;
    FnFree freeFn = nullptr;
    FnMakeStr makeStr = nullptr;
    FnUnmake unmake = nullptr;
    FnGetString getDriverKey = nullptr;
    FnGetString getHardwareKey = nullptr;
    FnSetRate setSampleRate = nullptr;
    FnGetRate getSampleRate = nullptr;
    FnListRates listSampleRates = nullptr;
    FnSetFrequency setFrequency = nullptr;
    FnGetFrequency getFrequency = nullptr;
    FnSetBandwidth setBandwidth = nullptr;
    FnListBandwidths listBandwidths = nullptr;
    FnHasGainMode hasGainMode = nullptr;
    FnSetGainMode setGainMode = nullptr;
    FnSetGain setGain = nullptr;
    FnSetupStream setupStream = nullptr;
    FnCloseStream closeStream = nullptr;
    FnGetMtu getStreamMtu = nullptr;
    FnActivateStream activateStream = nullptr;
    FnDeactivateStream deactivateStream = nullptr;
    FnReadStream readStream = nullptr;

    bool attempted = false;
    bool loaded = false;

    template <typename T>
    bool loadSymbol(T& target, const char* name) {
#if defined(_WIN32)
        target = reinterpret_cast<T>(
            GetProcAddress(core, name));
#else
        target = reinterpret_cast<T>(
            dlsym(core, name));
#endif
        return target != nullptr;
    }

    bool load() {
        if (attempted) {
            return loaded;
        }
        attempted = true;

#if defined(_WIN32)
        const char* coreNames[] = {
            "SoapySDR.dll",
            "libSoapySDR.dll",
        };
        for (const char* name : coreNames) {
            core = LoadLibraryA(name);
            if (core) {
                break;
            }
        }
#else
        const char* coreNames[] = {
            "libSoapySDR.so",
            "libSoapySDR.so.0.8",
            "libSoapySDR.so.0.7",
        };
        for (const char* name : coreNames) {
            core = dlopen(
                name,
                RTLD_NOW | RTLD_GLOBAL);
            if (core) {
                break;
            }
        }
#endif
        if (!core) {
            loaded = false;
            return false;
        }

        loaded =
            loadSymbol(lastError, "SoapySDRDevice_lastError") &&
            loadSymbol(
                enumerateStr,
                "SoapySDRDevice_enumerateStrArgs") &&
            loadSymbol(
                kwargsToString,
                "SoapySDRKwargs_toString") &&
            loadSymbol(
                kwargsListClear,
                "SoapySDRKwargsList_clear") &&
            loadSymbol(freeFn, "SoapySDR_free") &&
            loadSymbol(makeStr, "SoapySDRDevice_makeStrArgs") &&
            loadSymbol(unmake, "SoapySDRDevice_unmake") &&
            loadSymbol(
                getDriverKey,
                "SoapySDRDevice_getDriverKey") &&
            loadSymbol(
                getHardwareKey,
                "SoapySDRDevice_getHardwareKey") &&
            loadSymbol(
                setSampleRate,
                "SoapySDRDevice_setSampleRate") &&
            loadSymbol(
                getSampleRate,
                "SoapySDRDevice_getSampleRate") &&
            loadSymbol(
                listSampleRates,
                "SoapySDRDevice_listSampleRates") &&
            loadSymbol(
                setFrequency,
                "SoapySDRDevice_setFrequency") &&
            loadSymbol(
                getFrequency,
                "SoapySDRDevice_getFrequency") &&
            loadSymbol(
                setBandwidth,
                "SoapySDRDevice_setBandwidth") &&
            loadSymbol(
                listBandwidths,
                "SoapySDRDevice_listBandwidths") &&
            loadSymbol(
                hasGainMode,
                "SoapySDRDevice_hasGainMode") &&
            loadSymbol(
                setGainMode,
                "SoapySDRDevice_setGainMode") &&
            loadSymbol(
                setGain,
                "SoapySDRDevice_setGain") &&
            loadSymbol(
                setupStream,
                "SoapySDRDevice_setupStream") &&
            loadSymbol(
                closeStream,
                "SoapySDRDevice_closeStream") &&
            loadSymbol(
                getStreamMtu,
                "SoapySDRDevice_getStreamMTU") &&
            loadSymbol(
                activateStream,
                "SoapySDRDevice_activateStream") &&
            loadSymbol(
                deactivateStream,
                "SoapySDRDevice_deactivateStream") &&
            loadSymbol(
                readStream,
                "SoapySDRDevice_readStream");

        if (!loaded) {
            return false;
        }

        // SDR++'s desktop Soapy source relies on Soapy's module loader.
        // Mobile packages the modules as native libraries in the same APK.
        // Explicitly opening known module names lets their static factory
        // registration run even when the compiled installation prefix is not
        // meaningful inside the Android application sandbox.
        const char* moduleNames[] = {
#if defined(_WIN32)
            "rtlsdrSupport.dll",
            "HackRFSupport.dll",
            "airspySupport.dll",
            "airspyhfSupport.dll",
            "bladeRFSupport.dll",
            "LMS7Support.dll",
            "PlutoSDRSupport.dll",
            "UHD-SDRSupport.dll",
#else
            "librtlsdrSupport.so",
            "libHackRFSupport.so",
            "libairspySupport.so",
            "libairspyhfSupport.so",
            "libbladeRFSupport.so",
            "libLMS7Support.so",
            "libPlutoSDRSupport.so",
            "libUHD-SDRSupport.so",
            "libremoteSupport.so",
#endif
        };

        for (const char* name : moduleNames) {
#if defined(_WIN32)
            HMODULE module = LoadLibraryA(name);
            if (module) {
                modules.push_back(module);
            }
#else
            void* module =
                dlopen(name, RTLD_NOW | RTLD_GLOBAL);
            if (module) {
                modules.push_back(module);
            }
#endif
        }

        return true;
    }

    std::string errorText(const char* fallback) const {
        if (lastError) {
            const char* value = lastError();
            if (value && *value) {
                return value;
            }
        }
        return fallback ? fallback : "SoapySDR error";
    }

    std::string copyAndFree(char* value) const {
        if (!value) {
            return {};
        }
        std::string result(value);
        if (freeFn) {
            freeFn(value);
        }
        return result;
    }
};

SoapyApi& api() {
    static SoapyApi instance;
    return instance;
}

double nearestValue(
    double requested,
    double* values,
    std::size_t count) {
    if (!values || count == 0) {
        return requested;
    }

    double best = values[0];
    double bestDelta = std::fabs(best - requested);
    for (std::size_t i = 1; i < count; ++i) {
        const double delta =
            std::fabs(values[i] - requested);
        if (delta < bestDelta) {
            best = values[i];
            bestDelta = delta;
        }
    }
    return best;
}

} // namespace

SoapyDynamicClient::SoapyDynamicClient(
    dsp::stream<dsp::complex_t>* output)
    : output(output) {}

SoapyDynamicClient::~SoapyDynamicClient() {
    close();
}

bool SoapyDynamicClient::runtimeAvailable() {
    return api().load();
}

std::vector<std::string> SoapyDynamicClient::enumerate(
    const std::string& filter) {
    auto& a = api();
    std::vector<std::string> result;
    if (!a.load()) {
        return result;
    }

    std::size_t count = 0;
    SoapyKwargs* entries =
        a.enumerateStr(filter.c_str(), &count);
    if (!entries || count == 0) {
        if (entries) {
            a.kwargsListClear(entries, count);
        }
        return result;
    }

    result.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        char* textValue =
            a.kwargsToString(&entries[i]);
        result.push_back(a.copyAndFree(textValue));
    }
    a.kwargsListClear(entries, count);
    return result;
}

bool SoapyDynamicClient::open(
    const std::string& deviceArgs,
    uint32_t requestedSampleRate,
    uint32_t frequencyHz,
    double bandwidthHz,
    double gainDb,
    bool agc,
    std::size_t requestedChannel) {
    close();

    auto& a = api();
    if (!a.load()) {
        setError(
            "SoapySDR runtime is not packaged or could not be loaded");
        return false;
    }
    if (!output) {
        setError("SoapySDR output stream is null");
        return false;
    }

    Device* opened = nullptr;
    Stream* openedStream = nullptr;

    opened = a.makeStr(deviceArgs.c_str());
    if (!opened) {
        setError(a.errorText("Could not open SoapySDR device"));
        return false;
    }

    channel = requestedChannel;

    std::size_t rateCount = 0;
    double* rates =
        a.listSampleRates(
            opened,
            kSoapyRx,
            channel,
            &rateCount);
    const double selectedRate =
        nearestValue(
            static_cast<double>(
                std::max<uint32_t>(1000u, requestedSampleRate)),
            rates,
            rateCount);
    if (rates) {
        a.freeFn(rates);
    }

    if (a.setSampleRate(
            opened,
            kSoapyRx,
            channel,
            selectedRate) != 0) {
        setError(a.errorText("SoapySDR rejected sample rate"));
        a.unmake(opened);
        return false;
    }

    if (a.setFrequency(
            opened,
            kSoapyRx,
            channel,
            static_cast<double>(frequencyHz),
            nullptr) != 0) {
        setError(a.errorText("SoapySDR rejected frequency"));
        a.unmake(opened);
        return false;
    }

    if (bandwidthHz > 0.0) {
        std::size_t bwCount = 0;
        double* bandwidths =
            a.listBandwidths(
                opened,
                kSoapyRx,
                channel,
                &bwCount);
        const double selectedBandwidth =
            nearestValue(
                bandwidthHz,
                bandwidths,
                bwCount);
        if (bandwidths) {
            a.freeFn(bandwidths);
        }
        if (selectedBandwidth > 0.0) {
            // Some drivers report no programmable bandwidth. Treat a
            // rejected optional bandwidth as non-fatal.
            a.setBandwidth(
                opened,
                kSoapyRx,
                channel,
                selectedBandwidth);
            currentBandwidth = selectedBandwidth;
        }
    }

    if (a.hasGainMode(opened, kSoapyRx, channel)) {
        if (a.setGainMode(
                opened,
                kSoapyRx,
                channel,
                agc) != 0) {
            setError(a.errorText("SoapySDR rejected AGC mode"));
            a.unmake(opened);
            return false;
        }
    }
    if (!agc) {
        a.setGain(opened, kSoapyRx, channel, gainDb);
    }

    const std::size_t selectedChannel = channel;
    openedStream = a.setupStream(
        opened,
        kSoapyRx,
        "CF32",
        &selectedChannel,
        1,
        nullptr);
    if (!openedStream) {
        setError(a.errorText("SoapySDR setupStream failed"));
        a.unmake(opened);
        return false;
    }

    if (a.activateStream(
            opened,
            openedStream,
            0,
            0,
            0) != 0) {
        setError(a.errorText("SoapySDR activateStream failed"));
        a.closeStream(opened, openedStream);
        a.unmake(opened);
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(mutex);
        device = opened;
        stream = openedStream;
        currentSampleRate = static_cast<uint32_t>(
            std::llround(
                a.getSampleRate(
                    opened,
                    kSoapyRx,
                    channel)));
        currentFrequency = static_cast<uint32_t>(
            std::llround(
                a.getFrequency(
                    opened,
                    kSoapyRx,
                    channel)));
        currentGain = gainDb;
        currentAgc = agc;
        currentDriver =
            a.copyAndFree(a.getDriverKey(opened));
        currentHardware =
            a.copyAndFree(a.getHardwareKey(opened));
        error.clear();
    }

    output->clearReadStop();
    output->clearWriteStop();
    running.store(true);
    worker = std::thread(
        &SoapyDynamicClient::workerLoop,
        this);
    return true;
}

void SoapyDynamicClient::close() {
    running.store(false);

    if (worker.joinable()) {
        worker.join();
    }

    auto& a = api();
    Device* dev = nullptr;
    Stream* streamHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex);
        dev = reinterpret_cast<Device*>(device);
        streamHandle = reinterpret_cast<Stream*>(stream);
        device = nullptr;
        stream = nullptr;
        currentSampleRate = 0;
        currentFrequency = 0;
    }

    if (a.loaded && dev && streamHandle) {
        a.deactivateStream(
            dev,
            streamHandle,
            0,
            0);
        a.closeStream(dev, streamHandle);
    }
    if (a.loaded && dev) {
        a.unmake(dev);
    }
}

bool SoapyDynamicClient::setFrequency(
    uint32_t frequencyHz) {
    auto& a = api();
    std::lock_guard<std::mutex> lock(mutex);
    auto* dev = reinterpret_cast<Device*>(device);
    if (!a.loaded || !dev) {
        return false;
    }
    if (a.setFrequency(
            dev,
            kSoapyRx,
            channel,
            static_cast<double>(frequencyHz),
            nullptr) != 0) {
        error = a.errorText("SoapySDR frequency update failed");
        return false;
    }
    currentFrequency = frequencyHz;
    return true;
}

bool SoapyDynamicClient::setSampleRate(
    uint32_t sampleRateHz) {
    auto& a = api();
    std::lock_guard<std::mutex> lock(mutex);
    auto* dev = reinterpret_cast<Device*>(device);
    if (!a.loaded || !dev) {
        return false;
    }
    if (a.setSampleRate(
            dev,
            kSoapyRx,
            channel,
            static_cast<double>(sampleRateHz)) != 0) {
        error = a.errorText("SoapySDR sample-rate update failed");
        return false;
    }
    currentSampleRate = static_cast<uint32_t>(
        std::llround(
            a.getSampleRate(dev, kSoapyRx, channel)));
    return true;
}

bool SoapyDynamicClient::setBandwidth(
    double bandwidthHz) {
    auto& a = api();
    std::lock_guard<std::mutex> lock(mutex);
    auto* dev = reinterpret_cast<Device*>(device);
    if (!a.loaded || !dev) {
        return false;
    }
    if (a.setBandwidth(
            dev,
            kSoapyRx,
            channel,
            bandwidthHz) != 0) {
        error = a.errorText("SoapySDR bandwidth update failed");
        return false;
    }
    currentBandwidth = bandwidthHz;
    return true;
}

bool SoapyDynamicClient::setGain(double gainDb) {
    auto& a = api();
    std::lock_guard<std::mutex> lock(mutex);
    auto* dev = reinterpret_cast<Device*>(device);
    if (!a.loaded || !dev) {
        return false;
    }
    if (a.setGain(
            dev,
            kSoapyRx,
            channel,
            gainDb) != 0) {
        error = a.errorText("SoapySDR gain update failed");
        return false;
    }
    currentGain = gainDb;
    return true;
}

bool SoapyDynamicClient::setAgc(bool enabled) {
    auto& a = api();
    std::lock_guard<std::mutex> lock(mutex);
    auto* dev = reinterpret_cast<Device*>(device);
    if (!a.loaded || !dev) {
        return false;
    }
    if (!a.hasGainMode(dev, kSoapyRx, channel)) {
        error = "SoapySDR device does not provide hardware AGC";
        return false;
    }
    if (a.setGainMode(
            dev,
            kSoapyRx,
            channel,
            enabled) != 0) {
        error = a.errorText("SoapySDR AGC update failed");
        return false;
    }
    currentAgc = enabled;
    return true;
}

bool SoapyDynamicClient::isOpen() const {
    std::lock_guard<std::mutex> lock(mutex);
    return device != nullptr &&
        stream != nullptr &&
        running.load();
}

uint32_t SoapyDynamicClient::sampleRate() const {
    std::lock_guard<std::mutex> lock(mutex);
    return currentSampleRate;
}

uint32_t SoapyDynamicClient::frequency() const {
    std::lock_guard<std::mutex> lock(mutex);
    return currentFrequency;
}

std::string SoapyDynamicClient::driverKey() const {
    std::lock_guard<std::mutex> lock(mutex);
    return currentDriver;
}

std::string SoapyDynamicClient::hardwareKey() const {
    std::lock_guard<std::mutex> lock(mutex);
    return currentHardware;
}

std::string SoapyDynamicClient::lastError() const {
    std::lock_guard<std::mutex> lock(mutex);
    return error;
}

void SoapyDynamicClient::workerLoop() {
    auto& a = api();

    Device* dev = nullptr;
    Stream* streamHandle = nullptr;
    std::size_t mtu = 0;
    {
        std::lock_guard<std::mutex> lock(mutex);
        dev = reinterpret_cast<Device*>(device);
        streamHandle = reinterpret_cast<Stream*>(stream);
        if (dev && streamHandle) {
            mtu = a.getStreamMtu(dev, streamHandle);
        }
    }

    const std::size_t blockSize =
        std::max<std::size_t>(
            256u,
            std::min<std::size_t>(
                mtu == 0 ? 16384u : mtu,
                static_cast<std::size_t>(STREAM_BUFFER_SIZE)));

    while (running.load()) {
        if (!dev || !streamHandle) {
            break;
        }

        void* buffers[1] = {
            static_cast<void*>(output->writeBuf),
        };
        int flags = 0;
        long long timeNs = 0;
        const int count = a.readStream(
            dev,
            streamHandle,
            buffers,
            blockSize,
            &flags,
            &timeNs,
            kReadTimeoutUs);

        if (!running.load()) {
            break;
        }
        if (count == -1) {
            // SOAPY_SDR_TIMEOUT is -1. Timeouts are expected on an idle
            // or just-activated stream and should not tear the source down.
            continue;
        }
        if (count < 0) {
            setError(
                a.errorText(
                    "SoapySDR readStream failed"));
            break;
        }
        if (count == 0) {
            continue;
        }

        if (!output->swap(count)) {
            break;
        }
    }

    running.store(false);
}

void SoapyDynamicClient::setError(
    const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex);
    error = message;
}

} // namespace mobile
