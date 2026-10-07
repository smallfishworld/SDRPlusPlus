#include "include/sdrpp_mobile_api.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include <dsp/types.h>
#include <dsp/demod/am.h>
#include <dsp/demod/fm.h>
#include <dsp/demod/ssb.h>
#include <dsp/demod/cw.h>
#include <dsp/filter/deephasis.h>
#include <dsp/multirate/rational_resampler.h>
#include <dsp/noise_reduction/power_squelch.h>

namespace {

constexpr double kOutputSampleRate = 48000.0;

class MobileDspEngine {
public:
    MobileDspEngine(uint32_t inputRate, sdrpp_mode_t initialMode, float initialBandwidth)
        : inputSampleRate(std::max<uint32_t>(250000, inputRate)),
          mode(initialMode),
          bandwidth(std::max(50.0f, initialBandwidth)) {
        rebuild();
    }

    void setSampleRate(uint32_t rate) {
        std::lock_guard<std::mutex> lock(mutex);
        inputSampleRate = std::max<uint32_t>(250000, rate);
        rebuildLocked();
    }

    void setMode(sdrpp_mode_t newMode) {
        std::lock_guard<std::mutex> lock(mutex);
        mode = newMode;
        bandwidth = defaultBandwidth(newMode, bandwidth);
        rebuildLocked();
    }

    void setBandwidth(float newBandwidth) {
        std::lock_guard<std::mutex> lock(mutex);
        bandwidth = clampBandwidth(mode, newBandwidth);
        rebuildLocked();
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mutex);
        if (rfResampler) {
            rfResampler->reset();
        }
        if (am) {
            am->reset();
        }
        if (nfm) {
            nfm->reset();
        }
        if (wfm) {
            wfm->reset();
        }
        if (audioResampler) {
            audioResampler->reset();
        }
        if (deemphasis) {
            deemphasis->reset();
        }

        // SSB/CW blocks do not expose a complete public reset method. Rebuild
        // only those modes on retune so their translator/AGC history cannot
        // leak across channels.
        if (ssb || cw) {
            rebuildLocked();
        }
    }

    size_t process(
        const uint8_t* iq,
        size_t iqBytes,
        int16_t* outPcm,
        size_t outCapacity) {
        if (!iq || !outPcm || iqBytes < 2 || outCapacity == 0) {
            return 0;
        }

        std::lock_guard<std::mutex> lock(mutex);

        const size_t complexCount = iqBytes / 2;
        ensureInputCapacity(complexCount);

        // Same unsigned RTL-TCP conversion used by SDR++'s official
        // rtl_tcp_source client.
        for (size_t i = 0; i < complexCount; ++i) {
            rfInput[i].re = (static_cast<float>(iq[i * 2]) - 128.0f) / 128.0f;
            rfInput[i].im = (static_cast<float>(iq[i * 2 + 1]) - 128.0f) / 128.0f;
        }

        const size_t expectedIf = static_cast<size_t>(
            std::ceil((static_cast<double>(complexCount) * ifSampleRate) /
                      static_cast<double>(inputSampleRate))) + 4096;
        ensureIfCapacity(std::max<size_t>(expectedIf, complexCount / 2 + 4096));

        int ifCount = rfResampler
            ? rfResampler->process(
                  static_cast<int>(complexCount),
                  rfInput.data(),
                  ifBuffer.data())
            : 0;

        if (ifCount <= 0) {
            return 0;
        }

        if (squelchEnabled && powerSquelch) {
            powerSquelch->process(ifCount, ifBuffer.data(), ifBuffer.data());
        }

        ensureDemodCapacity(static_cast<size_t>(ifCount) + 4096);
        int demodCount = demodulate(ifCount);
        if (demodCount <= 0) {
            return 0;
        }

        const float* audioData = demodBuffer.data();
        int audioCount = demodCount;

        if (audioResampler) {
            const size_t expectedAudio = static_cast<size_t>(
                std::ceil((static_cast<double>(demodCount) * kOutputSampleRate) /
                          ifSampleRate)) + 4096;
            ensureAudioCapacity(expectedAudio);
            audioCount = audioResampler->process(
                demodCount,
                demodBuffer.data(),
                audioBuffer.data());
            audioData = audioBuffer.data();
        }

        if (audioCount <= 0) {
            return 0;
        }

        if (deemphasis) {
            // De-emphasis is part of SDR++'s normal WFM AF chain.
            deemphasis->process(audioCount, audioData, audioBuffer2.data());
            audioData = audioBuffer2.data();
        }

        const size_t writeCount = std::min<size_t>(
            static_cast<size_t>(audioCount),
            outCapacity);

        for (size_t i = 0; i < writeCount; ++i) {
            const float sample = std::clamp(audioData[i], -1.0f, 1.0f);
            outPcm[i] = static_cast<int16_t>(std::lrint(sample * 30000.0f));
        }

        return writeCount;
    }

    void setSquelch(bool enabled, float levelDb) {
        std::lock_guard<std::mutex> lock(mutex);
        squelchEnabled = enabled;
        squelchLevelDb = levelDb;
        if (powerSquelch) {
            powerSquelch->setLevel(squelchLevelDb);
        }
    }

private:
    static double ifRateForMode(sdrpp_mode_t value) {
        // Keep the bridge at or above 48 kHz so SDR++'s RationalResampler is
        // always used in its mature downsample/equal-rate path.
        switch (value) {
            case SDRPP_MODE_WFM: return 250000.0;
            case SDRPP_MODE_AM:  return 50000.0;
            case SDRPP_MODE_NFM: return 50000.0;
            case SDRPP_MODE_USB:
            case SDRPP_MODE_LSB:
            case SDRPP_MODE_DSB:
            case SDRPP_MODE_CW:
            case SDRPP_MODE_RAW:
            default:
                return 48000.0;
        }
    }

    static float defaultBandwidth(sdrpp_mode_t value, float current) {
        if (current > 0.0f) {
            return clampBandwidth(value, current);
        }
        switch (value) {
            case SDRPP_MODE_WFM: return 150000.0f;
            case SDRPP_MODE_NFM: return 12500.0f;
            case SDRPP_MODE_AM:  return 10000.0f;
            case SDRPP_MODE_USB:
            case SDRPP_MODE_LSB: return 2800.0f;
            case SDRPP_MODE_DSB: return 4600.0f;
            case SDRPP_MODE_CW:  return 500.0f;
            default:             return 10000.0f;
        }
    }

    static float clampBandwidth(sdrpp_mode_t value, float bw) {
        switch (value) {
            case SDRPP_MODE_WFM:
                return std::clamp(bw, 50000.0f, 250000.0f);
            case SDRPP_MODE_NFM:
                return std::clamp(bw, 1000.0f, 50000.0f);
            case SDRPP_MODE_AM:
                return std::clamp(bw, 1000.0f, 50000.0f);
            case SDRPP_MODE_USB:
            case SDRPP_MODE_LSB:
                return std::clamp(bw, 500.0f, 12000.0f);
            case SDRPP_MODE_DSB:
                return std::clamp(bw, 1000.0f, 12000.0f);
            case SDRPP_MODE_CW:
                return std::clamp(bw, 50.0f, 3000.0f);
            default:
                return std::max(50.0f, bw);
        }
    }

    void rebuild() {
        std::lock_guard<std::mutex> lock(mutex);
        rebuildLocked();
    }

    void rebuildLocked() {
        ifSampleRate = ifRateForMode(mode);
        bandwidth = clampBandwidth(mode, bandwidth);

        deemphasis.reset();
        powerSquelch.reset();
        audioResampler.reset();
        am.reset();
        nfm.reset();
        wfm.reset();
        ssb.reset();
        cw.reset();
        rfResampler.reset();

        rfResampler = std::make_unique<
            dsp::multirate::RationalResampler<dsp::complex_t>>();
        rfResampler->init(nullptr, inputSampleRate, ifSampleRate);
        // The bridge calls process() directly; its threaded output stream is
        // therefore not needed.
        rfResampler->out.free();

        powerSquelch =
            std::make_unique<dsp::noise_reduction::PowerSquelch>();
        powerSquelch->init(nullptr, squelchLevelDb);
        powerSquelch->out.free();

        switch (mode) {
            case SDRPP_MODE_AM: {
                am = std::make_unique<dsp::demod::AM<float>>();
                const double attack = 50.0 / ifSampleRate;
                const double decay = 5.0 / ifSampleRate;
                const double dcRate = 100.0 / ifSampleRate;
                am->init(
                    nullptr,
                    dsp::demod::AM<float>::AGCMode::AUDIO,
                    bandwidth,
                    attack,
                    decay,
                    dcRate,
                    ifSampleRate);
                am->out.free();
                break;
            }

            case SDRPP_MODE_NFM: {
                nfm = std::make_unique<dsp::demod::FM<float>>();
                nfm->init(nullptr, ifSampleRate, bandwidth, true);
                nfm->out.free();
                break;
            }

            case SDRPP_MODE_WFM: {
                // Official SDR++ FM detector/filter core. The full stereo/RDS
                // BroadcastFM wrapper is the next native bridge milestone.
                wfm = std::make_unique<dsp::demod::FM<float>>();
                wfm->init(nullptr, ifSampleRate, bandwidth, true);
                wfm->out.free();
                break;
            }

            case SDRPP_MODE_USB:
            case SDRPP_MODE_LSB:
            case SDRPP_MODE_DSB: {
                ssb = std::make_unique<dsp::demod::SSB<float>>();
                auto ssbMode = dsp::demod::SSB<float>::Mode::DSB;
                if (mode == SDRPP_MODE_USB) {
                    ssbMode = dsp::demod::SSB<float>::Mode::USB;
                }
                else if (mode == SDRPP_MODE_LSB) {
                    ssbMode = dsp::demod::SSB<float>::Mode::LSB;
                }
                const double attack = 50.0 / ifSampleRate;
                const double decay = 5.0 / ifSampleRate;
                ssb->init(
                    nullptr,
                    ssbMode,
                    bandwidth,
                    ifSampleRate,
                    attack,
                    decay);
                ssb->out.free();
                break;
            }

            case SDRPP_MODE_CW: {
                cw = std::make_unique<dsp::demod::CW<float>>();
                const double attack = 100.0 / ifSampleRate;
                const double decay = 5.0 / ifSampleRate;
                cw->init(nullptr, 800.0, attack, decay, ifSampleRate);
                cw->out.free();
                break;
            }

            case SDRPP_MODE_RAW:
            default:
                break;
        }

        if (ifSampleRate != kOutputSampleRate) {
            audioResampler =
                std::make_unique<dsp::multirate::RationalResampler<float>>();
            audioResampler->init(nullptr, ifSampleRate, kOutputSampleRate);
            audioResampler->out.free();
        }

        if (mode == SDRPP_MODE_WFM) {
            deemphasis = std::make_unique<dsp::filter::Deemphasis<float>>();
            deemphasis->init(nullptr, 50e-6, kOutputSampleRate);
            deemphasis->out.free();
        }

        // Working buffers. They grow on demand without being recreated for
        // every TCP packet.
        ensureInputCapacity(32768);
        ensureIfCapacity(32768);
        ensureDemodCapacity(32768);
        ensureAudioCapacity(65536);
    }

    int demodulate(int count) {
        switch (mode) {
            case SDRPP_MODE_AM:
                return am ? am->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_NFM:
                return nfm ? nfm->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_WFM:
                return wfm ? wfm->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_USB:
            case SDRPP_MODE_LSB:
            case SDRPP_MODE_DSB:
                return ssb ? ssb->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_CW:
                return cw ? cw->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_RAW:
            default:
                return 0;
        }
    }

    void ensureInputCapacity(size_t count) {
        if (rfInput.size() < count) {
            rfInput.resize(count);
        }
    }

    void ensureIfCapacity(size_t count) {
        if (ifBuffer.size() < count) {
            ifBuffer.resize(count);
        }
    }

    void ensureDemodCapacity(size_t count) {
        if (demodBuffer.size() < count) {
            demodBuffer.resize(count);
        }
    }

    void ensureAudioCapacity(size_t count) {
        if (audioBuffer.size() < count) {
            audioBuffer.resize(count);
        }
        if (audioBuffer2.size() < count) {
            audioBuffer2.resize(count);
        }
    }

    std::mutex mutex;
    uint32_t inputSampleRate = 1024000;
    double ifSampleRate = 50000.0;
    sdrpp_mode_t mode = SDRPP_MODE_AM;
    float bandwidth = 10000.0f;

    bool squelchEnabled = false;
    float squelchLevelDb = -82.0f;

    std::unique_ptr<dsp::multirate::RationalResampler<dsp::complex_t>>
        rfResampler;
    std::unique_ptr<dsp::noise_reduction::PowerSquelch> powerSquelch;

    std::unique_ptr<dsp::demod::AM<float>> am;
    std::unique_ptr<dsp::demod::FM<float>> nfm;
    std::unique_ptr<dsp::demod::FM<float>> wfm;
    std::unique_ptr<dsp::demod::SSB<float>> ssb;
    std::unique_ptr<dsp::demod::CW<float>> cw;

    std::unique_ptr<dsp::multirate::RationalResampler<float>>
        audioResampler;
    std::unique_ptr<dsp::filter::Deemphasis<float>> deemphasis;

    std::vector<dsp::complex_t> rfInput;
    std::vector<dsp::complex_t> ifBuffer;
    std::vector<float> demodBuffer;
    std::vector<float> audioBuffer;
    std::vector<float> audioBuffer2;
};

MobileDspEngine* asEngine(sdrpp_engine_t handle) {
    return reinterpret_cast<MobileDspEngine*>(handle);
}

} // namespace

extern "C" {

sdrpp_engine_t sdrpp_dsp_create(
    uint32_t input_sample_rate_hz,
    sdrpp_mode_t mode,
    float bandwidth_hz) {
    try {
        return reinterpret_cast<sdrpp_engine_t>(
            new MobileDspEngine(input_sample_rate_hz, mode, bandwidth_hz));
    }
    catch (...) {
        return nullptr;
    }
}

void sdrpp_dsp_destroy(sdrpp_engine_t engine) {
    delete asEngine(engine);
}

int sdrpp_dsp_set_sample_rate(
    sdrpp_engine_t engine,
    uint32_t input_sample_rate_hz) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setSampleRate(input_sample_rate_hz);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_mode(
    sdrpp_engine_t engine,
    sdrpp_mode_t mode) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setMode(mode);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_bandwidth(
    sdrpp_engine_t engine,
    float bandwidth_hz) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setBandwidth(bandwidth_hz);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_squelch(
    sdrpp_engine_t engine,
    int enabled,
    float level_db) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setSquelch(enabled != 0, level_db);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

void sdrpp_dsp_reset(sdrpp_engine_t engine) {
    if (!engine) {
        return;
    }
    try {
        asEngine(engine)->reset();
    }
    catch (...) {
    }
}

size_t sdrpp_dsp_process_u8(
    sdrpp_engine_t engine,
    const uint8_t* iq,
    size_t iq_bytes,
    int16_t* out_pcm,
    size_t out_capacity_samples) {
    if (!engine) {
        return 0;
    }
    try {
        return asEngine(engine)->process(
            iq,
            iq_bytes,
            out_pcm,
            out_capacity_samples);
    }
    catch (...) {
        return 0;
    }
}

uint32_t sdrpp_dsp_output_sample_rate(void) {
    return static_cast<uint32_t>(kOutputSampleRate);
}

const char* sdrpp_dsp_backend_name(void) {
    return "SDR++ official DSP core bridge v1";
}

} // extern "C"
