#include "include/sdrpp_mobile_api.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include <dsp/types.h>
#include <dsp/taps/from_array.h>
#include <dsp/demod/am.h>
#include <dsp/demod/fm.h>
#include <dsp/channel/frequency_xlator.h>
#include <dsp/demod/broadcast_fm.h>
#include <dsp/demod/ssb.h>
#include <dsp/demod/cw.h>
#include <dsp/filter/deephasis.h>
#include <dsp/filter/fir.h>
#include <dsp/taps/high_pass.h>
#include <dsp/multirate/rational_resampler.h>
#include <dsp/noise_reduction/noise_blanker.h>
#include <dsp/noise_reduction/power_squelch.h>
#include "../../decoder_modules/radio/src/rds_demod.h"
#include "../../decoder_modules/radio/src/rds.h"

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
        if (wfmBroadcast) {
            wfmBroadcast->reset();
        }
        if (rdsDemod) {
            rdsDemod->reset();
        }
        if (audioResampler) {
            audioResampler->reset();
        }
        if (stereoAudioResampler) {
            stereoAudioResampler->reset();
        }
        if (stereoDeemphasis) {
            stereoDeemphasis->reset();
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

        if (noiseBlankerEnabled && noiseBlanker) {
            noiseBlanker->process(ifCount, ifBuffer.data(), ifBuffer.data());
        }

        if (squelchEnabled && powerSquelch) {
            powerSquelch->process(ifCount, ifBuffer.data(), ifBuffer.data());
        }

        if (mode == SDRPP_MODE_WFM && wfmBroadcast) {
            ensureStereoCapacity(static_cast<size_t>(ifCount) + 4096);
            ensureRdsCapacity(
                static_cast<size_t>(
                    std::ceil(
                        (static_cast<double>(ifCount) * 5000.0) /
                        ifSampleRate)) + 4096);
            int rdsCount = 0;
            int stereoCount = wfmBroadcast->process(
                ifCount,
                ifBuffer.data(),
                stereoDemodBuffer.data(),
                rdsCount,
                rdsBaseband.data());
            if (rdsCount > 0 && rdsDemod) {
                ensureRdsSymbolCapacity(
                    static_cast<size_t>(rdsCount) + 4096);
                int symbolCount = rdsDemod->process(
                    rdsCount,
                    rdsBaseband.data(),
                    rdsSoft.data(),
                    rdsBits.data());
                if (symbolCount > 0) {
                    rdsDecoder.process(rdsBits.data(), symbolCount);
                }
            }
            if (stereoCount <= 0) {
                return 0;
            }

            const dsp::stereo_t* stereoData = stereoDemodBuffer.data();
            int audioFrames = stereoCount;

            if (stereoAudioResampler) {
                const size_t expectedAudio = static_cast<size_t>(
                    std::ceil(
                        (static_cast<double>(stereoCount) * kOutputSampleRate) /
                        ifSampleRate)) + 4096;
                ensureStereoAudioCapacity(expectedAudio);
                audioFrames = stereoAudioResampler->process(
                    stereoCount,
                    stereoDemodBuffer.data(),
                    stereoAudioBuffer.data());
                stereoData = stereoAudioBuffer.data();
            }

            if (audioFrames <= 0) {
                return 0;
            }

            if (stereoDeemphasis && deemphasisUs > 0) {
                stereoDeemphasis->process(
                    audioFrames,
                    stereoData,
                    stereoAudioBuffer2.data());
                stereoData = stereoAudioBuffer2.data();
            }

            if (highPassEnabled && stereoHighPass) {
                ensureStereoAudioCapacity(static_cast<size_t>(audioFrames));
                stereoHighPass->process(
                    audioFrames,
                    stereoData,
                    stereoAudioBuffer.data());
                stereoData = stereoAudioBuffer.data();
            }

            const size_t frameCapacity = outCapacity / 2;
            const size_t writeFrames = std::min<size_t>(
                static_cast<size_t>(audioFrames),
                frameCapacity);
            for (size_t i = 0; i < writeFrames; ++i) {
                const float left =
                    std::clamp(stereoData[i].l, -1.0f, 1.0f);
                const float right =
                    std::clamp(stereoData[i].r, -1.0f, 1.0f);
                outPcm[i * 2] =
                    static_cast<int16_t>(std::lrint(left * 30000.0f));
                outPcm[i * 2 + 1] =
                    static_cast<int16_t>(std::lrint(right * 30000.0f));
            }
            return writeFrames * 2;
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

        if (highPassEnabled && monoHighPass) {
            ensureAudioCapacity(static_cast<size_t>(audioCount));
            monoHighPass->process(
                audioCount,
                audioData,
                audioBuffer2.data());
            audioData = audioBuffer2.data();
        }

        const size_t frameCapacity = outCapacity / 2;
        const size_t writeFrames = std::min<size_t>(
            static_cast<size_t>(audioCount),
            frameCapacity);

        for (size_t i = 0; i < writeFrames; ++i) {
            const float sample = std::clamp(audioData[i], -1.0f, 1.0f);
            const int16_t pcm =
                static_cast<int16_t>(std::lrint(sample * 30000.0f));
            outPcm[i * 2] = pcm;
            outPcm[i * 2 + 1] = pcm;
        }

        return writeFrames * 2;
    }

    void setSquelch(bool enabled, float levelDb) {
        std::lock_guard<std::mutex> lock(mutex);
        squelchEnabled = enabled;
        squelchLevelDb = levelDb;
        if (powerSquelch) {
            powerSquelch->setLevel(squelchLevelDb);
        }
    }

    void setNoiseBlanker(bool enabled, float level) {
        std::lock_guard<std::mutex> lock(mutex);
        noiseBlankerEnabled = enabled;
        noiseBlankerLevel = std::clamp(level, 1.0f, 10.0f);
        if (noiseBlanker) {
            noiseBlanker->setLevel(noiseBlankerLevel);
        }
    }

    void setHighPass(bool enabled) {
        std::lock_guard<std::mutex> lock(mutex);
        highPassEnabled = enabled;
    }

    void setDeemphasis(int modeUs) {
        std::lock_guard<std::mutex> lock(mutex);
        if (modeUs != 0 && modeUs != 22 && modeUs != 50 && modeUs != 75) {
            modeUs = 50;
        }
        deemphasisUs = modeUs;
        if (stereoDeemphasis && deemphasisUs > 0) {
            stereoDeemphasis->setTau(static_cast<double>(deemphasisUs) * 1e-6);
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

        stereoDeemphasis.reset();
        stereoAudioResampler.reset();
        monoHighPass.reset();
        stereoHighPass.reset();
        noiseBlanker.reset();
        powerSquelch.reset();
        audioResampler.reset();
        am.reset();
        nfm.reset();
        wfmBroadcast.reset();
        rdsDemod.reset();
        ssb.reset();
        cw.reset();
        rfResampler.reset();

        rfResampler = std::make_unique<
            dsp::multirate::RationalResampler<dsp::complex_t>>();
        rfResampler->init(nullptr, inputSampleRate, ifSampleRate);
        // The bridge calls process() directly; its threaded output stream is
        // therefore not needed.
        rfResampler->out.free();

        noiseBlanker =
            std::make_unique<dsp::noise_reduction::NoiseBlanker>();
        noiseBlanker->init(nullptr, 500.0 / ifSampleRate, noiseBlankerLevel);
        noiseBlanker->out.free();

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
                wfmBroadcast = std::make_unique<dsp::demod::BroadcastFM>();
                wfmBroadcast->init(
                    nullptr,
                    bandwidth / 2.0,
                    ifSampleRate,
                    true,
                    true,
                    true);
                wfmBroadcast->out.free();
                wfmBroadcast->rdsOut.free();

                rdsDemod = std::make_unique<RDSDemod>();
                rdsDemod->init(nullptr, false);
                rdsDemod->out.free();
                rdsDemod->soft.free();
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

        if (mode == SDRPP_MODE_WFM) {
            stereoAudioResampler = std::make_unique<
                dsp::multirate::RationalResampler<dsp::stereo_t>>();
            stereoAudioResampler->init(
                nullptr,
                ifSampleRate,
                kOutputSampleRate);
            stereoAudioResampler->out.free();

            stereoDeemphasis =
                std::make_unique<dsp::filter::Deemphasis<dsp::stereo_t>>();
            stereoDeemphasis->init(
                nullptr,
                static_cast<double>(std::max(1, deemphasisUs)) * 1e-6,
                kOutputSampleRate);
            stereoDeemphasis->out.free();
        }
        else if (ifSampleRate != kOutputSampleRate) {
            audioResampler =
                std::make_unique<dsp::multirate::RationalResampler<float>>();
            audioResampler->init(nullptr, ifSampleRate, kOutputSampleRate);
            audioResampler->out.free();
        }

        auto hpTaps = dsp::taps::highPass(
            300.0,
            100.0,
            kOutputSampleRate);
        monoHighPass =
            std::make_unique<dsp::filter::FIR<float, float>>();
        monoHighPass->init(nullptr, hpTaps);
        monoHighPass->out.free();

        stereoHighPass =
            std::make_unique<dsp::filter::FIR<dsp::stereo_t, float>>();
        stereoHighPass->init(nullptr, hpTaps);
        stereoHighPass->out.free();

        // Working buffers. They grow on demand without being recreated for
        // every TCP packet.
        ensureInputCapacity(32768);
        ensureIfCapacity(32768);
        ensureDemodCapacity(32768);
        ensureAudioCapacity(65536);
        ensureStereoCapacity(32768);
        ensureStereoAudioCapacity(65536);
        ensureRdsCapacity(8192);
        ensureRdsSymbolCapacity(8192);
    }

    int demodulate(int count) {
        switch (mode) {
            case SDRPP_MODE_AM:
                return am ? am->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_NFM:
                return nfm ? nfm->process(count, ifBuffer.data(), demodBuffer.data()) : 0;
            case SDRPP_MODE_WFM:
                return 0;
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

    void ensureStereoCapacity(size_t count) {
        if (stereoDemodBuffer.size() < count) {
            stereoDemodBuffer.resize(count);
        }
    }

    void ensureStereoAudioCapacity(size_t count) {
        if (stereoAudioBuffer.size() < count) {
            stereoAudioBuffer.resize(count);
        }
        if (stereoAudioBuffer2.size() < count) {
            stereoAudioBuffer2.resize(count);
        }
    }

    void ensureRdsCapacity(size_t count) {
        if (rdsBaseband.size() < count) {
            rdsBaseband.resize(count);
        }
    }

    void ensureRdsSymbolCapacity(size_t count) {
        if (rdsSoft.size() < count) {
            rdsSoft.resize(count);
        }
        if (rdsBits.size() < count) {
            rdsBits.resize(count);
        }
    }

    int getRds(
        char* programService,
        size_t programServiceCapacity,
        char* radioText,
        size_t radioTextCapacity) {
        if (mode != SDRPP_MODE_WFM || !rdsDemod) {
            if (programService && programServiceCapacity) {
                programService[0] = '\0';
            }
            if (radioText && radioTextCapacity) {
                radioText[0] = '\0';
            }
            return 0;
        }

        bool valid = false;
        std::string ps;
        std::string rt;
        if (rdsDecoder.PSNameValid()) {
            ps = rdsDecoder.getPSName(false);
            valid = true;
        }
        if (rdsDecoder.radioTextValid()) {
            rt = rdsDecoder.getRadioText(false);
            valid = true;
        }

        auto writeString = [](char* dst, size_t cap, const std::string& src) {
            if (!dst || cap == 0) {
                return;
            }
            const size_t n = std::min(cap - 1, src.size());
            std::memcpy(dst, src.data(), n);
            dst[n] = '\0';
        };

        writeString(programService, programServiceCapacity, ps);
        writeString(radioText, radioTextCapacity, rt);
        return valid ? 1 : 0;
    }

    std::mutex mutex;
    uint32_t inputSampleRate = 1024000;
    double ifSampleRate = 50000.0;
    sdrpp_mode_t mode = SDRPP_MODE_AM;
    float bandwidth = 10000.0f;

    bool squelchEnabled = false;
    float squelchLevelDb = -82.0f;
    bool noiseBlankerEnabled = false;
    float noiseBlankerLevel = 10.0f;
    bool highPassEnabled = false;
    int deemphasisUs = 50;

    std::unique_ptr<dsp::multirate::RationalResampler<dsp::complex_t>>
        rfResampler;
    std::unique_ptr<dsp::noise_reduction::NoiseBlanker> noiseBlanker;
    std::unique_ptr<dsp::noise_reduction::PowerSquelch> powerSquelch;

    std::unique_ptr<dsp::demod::AM<float>> am;
    std::unique_ptr<dsp::demod::FM<float>> nfm;
    std::unique_ptr<dsp::demod::BroadcastFM> wfmBroadcast;
    std::unique_ptr<RDSDemod> rdsDemod;
    rds::Decoder rdsDecoder;
    std::unique_ptr<dsp::demod::SSB<float>> ssb;
    std::unique_ptr<dsp::demod::CW<float>> cw;

    std::unique_ptr<dsp::multirate::RationalResampler<float>>
        audioResampler;
    std::unique_ptr<
        dsp::multirate::RationalResampler<dsp::stereo_t>>
        stereoAudioResampler;
    std::unique_ptr<dsp::filter::Deemphasis<dsp::stereo_t>>
        stereoDeemphasis;
    std::unique_ptr<dsp::filter::FIR<float, float>> monoHighPass;
    std::unique_ptr<dsp::filter::FIR<dsp::stereo_t, float>> stereoHighPass;

    std::vector<dsp::complex_t> rfInput;
    std::vector<dsp::complex_t> ifBuffer;
    std::vector<float> demodBuffer;
    std::vector<float> audioBuffer;
    std::vector<float> audioBuffer2;
    std::vector<dsp::stereo_t> stereoDemodBuffer;
    std::vector<dsp::stereo_t> stereoAudioBuffer;
    std::vector<dsp::stereo_t> stereoAudioBuffer2;
    std::vector<dsp::complex_t> rdsBaseband;
    std::vector<float> rdsSoft;
    std::vector<uint8_t> rdsBits;
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

int sdrpp_dsp_set_noise_blanker(
    sdrpp_engine_t engine,
    int enabled,
    float level) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setNoiseBlanker(enabled != 0, level);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_high_pass(
    sdrpp_engine_t engine,
    int enabled) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setHighPass(enabled != 0);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_deemphasis(
    sdrpp_engine_t engine,
    int mode_us) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setDeemphasis(mode_us);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_get_rds(
    sdrpp_engine_t engine,
    char* program_service,
    size_t program_service_capacity,
    char* radio_text,
    size_t radio_text_capacity) {
    if (!engine) {
        return 0;
    }
    try {
        return asEngine(engine)->getRds(
            program_service,
            program_service_capacity,
            radio_text,
            radio_text_capacity);
    }
    catch (...) {
        return 0;
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
    return "SDR++ official DSP core bridge v4 · WFM stereo/RDS + radio post-processing";
}

} // extern "C"
