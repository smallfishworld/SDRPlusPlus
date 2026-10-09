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
#include <dsp/noise_reduction/ctcss_squelch.h>
#include <dsp/noise_reduction/fm_if.h>
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

    void setFrequencyOffset(float offsetHz) {
        std::lock_guard<std::mutex> lock(mutex);
        const double halfRate =
            static_cast<double>(inputSampleRate) / 2.0;
        frequencyOffsetHz = std::clamp<double>(
            static_cast<double>(offsetHz),
            -halfRate,
            halfRate);
        if (channelXlator) {
            channelXlator->setOffset(
                -frequencyOffsetHz,
                inputSampleRate);
            channelXlator->reset();
        }
        if (channelXlator) {
            channelXlator->reset();
        }
        if (rfResampler) {
            rfResampler->reset();
        }
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
        if (fmIfNr) {
            fmIfNr->reset();
        }

        // SSB/CW and CTCSS detector state are easiest to reset by rebuilding
        // their official SDR++ blocks after a retune.
        if (ssb || cw || (ctcssMode != 0 && ctcss)) {
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
            rfInput[i].re =
                (static_cast<float>(iq[i * 2]) - 128.0f) / 128.0f;
            rfInput[i].im =
                (static_cast<float>(iq[i * 2 + 1]) - 128.0f) / 128.0f;
        }

        return processPreparedLocked(
            complexCount,
            outPcm,
            outCapacity);
    }

    size_t processComplex(
        const float* iqInterleaved,
        size_t complexCount,
        int16_t* outPcm,
        size_t outCapacity) {
        if (!iqInterleaved || !outPcm ||
            complexCount == 0 || outCapacity == 0) {
            return 0;
        }

        std::lock_guard<std::mutex> lock(mutex);
        ensureInputCapacity(complexCount);
        for (size_t i = 0; i < complexCount; ++i) {
            rfInput[i].re = iqInterleaved[i * 2];
            rfInput[i].im = iqInterleaved[i * 2 + 1];
        }

        return processPreparedLocked(
            complexCount,
            outPcm,
            outCapacity);
    }

    size_t processPreparedLocked(
        size_t complexCount,
        int16_t* outPcm,
        size_t outCapacity) {
        const size_t expectedIf = static_cast<size_t>(
            std::ceil((static_cast<double>(complexCount) * ifSampleRate) /
                      static_cast<double>(inputSampleRate))) + 4096;
        ensureIfCapacity(std::max<size_t>(expectedIf, complexCount / 2 + 4096));

        const dsp::complex_t* rfData = rfInput.data();
        if (channelXlator && std::fabs(frequencyOffsetHz) > 0.01) {
            ensureTranslatedCapacity(complexCount);
            channelXlator->process(
                static_cast<int>(complexCount),
                rfInput.data(),
                translatedBuffer.data());
            rfData = translatedBuffer.data();
        }

        int ifCount = rfResampler
            ? rfResampler->process(
                  static_cast<int>(complexCount),
                  rfData,
                  ifBuffer.data())
            : 0;

        if (ifCount <= 0) {
            return 0;
        }

        const bool noiseBlankerAllowed =
            mode == SDRPP_MODE_USB ||
            mode == SDRPP_MODE_LSB ||
            mode == SDRPP_MODE_DSB ||
            mode == SDRPP_MODE_RAW;
        if (noiseBlankerEnabled && noiseBlanker && noiseBlankerAllowed) {
            noiseBlanker->process(ifCount, ifBuffer.data(), ifBuffer.data());
        }

        if (squelchEnabled && powerSquelch) {
            powerSquelch->process(ifCount, ifBuffer.data(), ifBuffer.data());
        }

        if (fmIfNrEnabled && fmIfNr &&
            (mode == SDRPP_MODE_NFM || mode == SDRPP_MODE_WFM)) {
            fmIfNr->process(ifCount, ifBuffer.data(), ifBuffer.data());
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

        ensureCtcssCapacity(static_cast<size_t>(audioCount));
        for (int i = 0; i < audioCount; ++i) {
            const float sample = audioData[i];
            ctcssInputBuffer[i] = dsp::stereo_t{sample, sample};
        }

        const dsp::stereo_t* finalStereo = ctcssInputBuffer.data();
        if (ctcssMode != 0 && ctcss && mode == SDRPP_MODE_NFM) {
            ctcss->process(
                audioCount,
                ctcssInputBuffer.data(),
                ctcssOutputBuffer.data());
            finalStereo = ctcssOutputBuffer.data();
        }

        const size_t frameCapacity = outCapacity / 2;
        const size_t writeFrames = std::min<size_t>(
            static_cast<size_t>(audioCount),
            frameCapacity);

        for (size_t i = 0; i < writeFrames; ++i) {
            const float left =
                std::clamp(finalStereo[i].l, -1.0f, 1.0f);
            const float right =
                std::clamp(finalStereo[i].r, -1.0f, 1.0f);
            outPcm[i * 2] =
                static_cast<int16_t>(std::lrint(left * 30000.0f));
            outPcm[i * 2 + 1] =
                static_cast<int16_t>(std::lrint(right * 30000.0f));
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

    void setCtcss(int modeValue, int toneIndex) {
        std::lock_guard<std::mutex> lock(mutex);
        ctcssMode = std::clamp(modeValue, 0, 2);
        ctcssToneIndex = toneIndex;
        if (!ctcss) {
            return;
        }

        if (ctcssMode == 1) {
            ctcss->setRequiredTone(
                dsp::noise_reduction::CTCSS_TONE_NONE);
        }
        else if (ctcssMode == 2) {
            if (toneIndex == -2) {
                ctcss->setRequiredTone(
                    dsp::noise_reduction::CTCSS_TONE_ANY);
            }
            else {
                const int maxTone =
                    dsp::noise_reduction::_CTCSS_TONE_COUNT - 1;
                const int clampedTone =
                    std::clamp(toneIndex, 0, maxTone);
                ctcssToneIndex = clampedTone;
                ctcss->setRequiredTone(
                    static_cast<dsp::noise_reduction::CTCSSTone>(
                        clampedTone));
            }
        }
    }

    int getCtcss(int* toneIndex, float* toneHz) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!ctcss || mode != SDRPP_MODE_NFM) {
            if (toneIndex) {
                *toneIndex = -1;
            }
            if (toneHz) {
                *toneHz = 0.0f;
            }
            return 0;
        }

        const auto tone = ctcss->getCurrentTone();
        if (toneIndex) {
            *toneIndex = static_cast<int>(tone);
        }
        if (toneHz) {
            *toneHz =
                (tone >= 0 &&
                 tone < dsp::noise_reduction::_CTCSS_TONE_COUNT)
                    ? dsp::noise_reduction::CTCSS_TONES[tone]
                    : 0.0f;
        }
        return tone == dsp::noise_reduction::CTCSS_TONE_NONE ? 0 : 1;
    }

    void setFmIfNr(bool enabled, int preset) {
        std::lock_guard<std::mutex> lock(mutex);
        fmIfNrEnabled = enabled;
        fmIfNrPreset = std::clamp(preset, 0, 3);
        if (fmIfNr) {
            fmIfNr->setBins(ifNrBins(fmIfNrPreset));
        }
    }

    void setAmAgc(bool carrier, float attackMs, float decayMs) {
        std::lock_guard<std::mutex> lock(mutex);
        amCarrierAgc = carrier;
        amAgcAttackMs = std::clamp(attackMs, 1.0f, 200.0f);
        amAgcDecayMs = std::clamp(decayMs, 1.0f, 20.0f);
        if (am) {
            am->setAGCMode(
                amCarrierAgc
                    ? dsp::demod::AM<float>::AGCMode::CARRIER
                    : dsp::demod::AM<float>::AGCMode::AUDIO);
            am->setAGCAttack(amAgcAttackMs / ifSampleRate);
            am->setAGCDecay(amAgcDecayMs / ifSampleRate);
        }
    }

    void setSsbAgc(float attackMs, float decayMs) {
        std::lock_guard<std::mutex> lock(mutex);
        ssbAgcAttackMs = std::clamp(attackMs, 1.0f, 200.0f);
        ssbAgcDecayMs = std::clamp(decayMs, 1.0f, 20.0f);
        if (ssb) {
            ssb->setAGCAttack(ssbAgcAttackMs / ifSampleRate);
            ssb->setAGCDecay(ssbAgcDecayMs / ifSampleRate);
        }
    }

    void setCwOptions(int toneHz, float attackMs, float decayMs) {
        std::lock_guard<std::mutex> lock(mutex);
        cwToneHz = std::clamp(toneHz, 250, 1250);
        cwAgcAttackMs = std::clamp(attackMs, 1.0f, 200.0f);
        cwAgcDecayMs = std::clamp(decayMs, 1.0f, 20.0f);
        if (cw) {
            cw->setTone(cwToneHz);
            cw->setAGCAttack(cwAgcAttackMs / ifSampleRate);
            cw->setAGCDecay(cwAgcDecayMs / ifSampleRate);
        }
    }

    void setNfmOptions(bool lowPass) {
        std::lock_guard<std::mutex> lock(mutex);
        nfmLowPass = lowPass;
        if (nfm) {
            nfm->setLowPass(nfmLowPass);
        }
    }

    void setWfmOptions(bool stereo, bool lowPass, bool rdsEnabled) {
        std::lock_guard<std::mutex> lock(mutex);
        wfmStereo = stereo;
        wfmLowPass = lowPass;
        wfmRdsEnabled = rdsEnabled;
        if (wfmBroadcast) {
            wfmBroadcast->setStereo(wfmStereo);
            wfmBroadcast->setLowPass(wfmLowPass);
            wfmBroadcast->setRDSOut(wfmRdsEnabled);
        }
    }

    int getRds(
        char* programService,
        size_t programServiceCapacity,
        char* radioText,
        size_t radioTextCapacity) {
        std::lock_guard<std::mutex> lock(mutex);
        return getRdsLocked(
            programService,
            programServiceCapacity,
            radioText,
            radioTextCapacity);
    }

private:
    static int ifNrBins(int preset) {
        switch (preset) {
            case 0: return 9;   // NOAA APT
            case 1: return 15;  // Voice
            case 2: return 31;  // Narrow Band
            case 3: return 32;  // Broadcast
            default: return 15;
        }
    }

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
        fmIfNr.reset();
        ctcss.reset();
        audioResampler.reset();
        am.reset();
        nfm.reset();
        wfmBroadcast.reset();
        rdsDemod.reset();
        ssb.reset();
        cw.reset();
        channelXlator.reset();
        rfResampler.reset();

        channelXlator =
            std::make_unique<dsp::channel::FrequencyXlator>();
        channelXlator->init(
            nullptr,
            -frequencyOffsetHz,
            inputSampleRate);
        channelXlator->out.free();

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

        fmIfNr =
            std::make_unique<dsp::noise_reduction::FMIF>();
        fmIfNr->init(nullptr, ifNrBins(fmIfNrPreset));
        fmIfNr->out.free();

        switch (mode) {
            case SDRPP_MODE_AM: {
                am = std::make_unique<dsp::demod::AM<float>>();
                const double attack = amAgcAttackMs / ifSampleRate;
                const double decay = amAgcDecayMs / ifSampleRate;
                const double dcRate = 100.0 / ifSampleRate;
                am->init(
                    nullptr,
                    amCarrierAgc
                        ? dsp::demod::AM<float>::AGCMode::CARRIER
                        : dsp::demod::AM<float>::AGCMode::AUDIO,
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
                nfm->init(nullptr, ifSampleRate, bandwidth, nfmLowPass);
                nfm->out.free();
                break;
            }

            case SDRPP_MODE_WFM: {
                wfmBroadcast = std::make_unique<dsp::demod::BroadcastFM>();
                wfmBroadcast->init(
                    nullptr,
                    bandwidth / 2.0,
                    ifSampleRate,
                    wfmStereo,
                    wfmLowPass,
                    wfmRdsEnabled);
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
                const double attack = ssbAgcAttackMs / ifSampleRate;
                const double decay = ssbAgcDecayMs / ifSampleRate;
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
                const double attack = cwAgcAttackMs / ifSampleRate;
                const double decay = cwAgcDecayMs / ifSampleRate;
                cw->init(nullptr, cwToneHz, attack, decay, ifSampleRate);
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

        ctcss =
            std::make_unique<dsp::noise_reduction::CTCSSSquelch>();
        ctcss->init(nullptr, kOutputSampleRate);
        if (ctcssMode == 1) {
            ctcss->setRequiredTone(
                dsp::noise_reduction::CTCSS_TONE_NONE);
        }
        else if (ctcssMode == 2) {
            if (ctcssToneIndex == -2) {
                ctcss->setRequiredTone(
                    dsp::noise_reduction::CTCSS_TONE_ANY);
            }
            else {
                const int maxTone =
                    dsp::noise_reduction::_CTCSS_TONE_COUNT - 1;
                ctcssToneIndex =
                    std::clamp(ctcssToneIndex, 0, maxTone);
                ctcss->setRequiredTone(
                    static_cast<dsp::noise_reduction::CTCSSTone>(
                        ctcssToneIndex));
            }
        }
        ctcss->out.free();

        // Working buffers. They grow on demand without being recreated for
        // every TCP packet.
        ensureInputCapacity(32768);
        ensureTranslatedCapacity(32768);
        ensureIfCapacity(32768);
        ensureDemodCapacity(32768);
        ensureAudioCapacity(65536);
        ensureStereoCapacity(32768);
        ensureStereoAudioCapacity(65536);
        ensureCtcssCapacity(65536);
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

    void ensureTranslatedCapacity(size_t count) {
        if (translatedBuffer.size() < count) {
            translatedBuffer.resize(count);
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

    void ensureCtcssCapacity(size_t count) {
        if (ctcssInputBuffer.size() < count) {
            ctcssInputBuffer.resize(count);
        }
        if (ctcssOutputBuffer.size() < count) {
            ctcssOutputBuffer.resize(count);
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

    int getRdsLocked(
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
    double frequencyOffsetHz = 0.0;

    bool squelchEnabled = false;
    float squelchLevelDb = -82.0f;
    bool noiseBlankerEnabled = false;
    float noiseBlankerLevel = 10.0f;
    bool highPassEnabled = false;
    int deemphasisUs = 50;

    int ctcssMode = 0;
    int ctcssToneIndex = -2;
    bool fmIfNrEnabled = false;
    int fmIfNrPreset = 1;

    bool amCarrierAgc = false;
    float amAgcAttackMs = 50.0f;
    float amAgcDecayMs = 5.0f;
    float ssbAgcAttackMs = 50.0f;
    float ssbAgcDecayMs = 5.0f;
    int cwToneHz = 800;
    float cwAgcAttackMs = 100.0f;
    float cwAgcDecayMs = 5.0f;
    bool nfmLowPass = true;
    bool wfmStereo = false;
    bool wfmLowPass = true;
    bool wfmRdsEnabled = true;

    std::unique_ptr<dsp::channel::FrequencyXlator> channelXlator;
    std::unique_ptr<dsp::multirate::RationalResampler<dsp::complex_t>>
        rfResampler;
    std::unique_ptr<dsp::noise_reduction::NoiseBlanker> noiseBlanker;
    std::unique_ptr<dsp::noise_reduction::PowerSquelch> powerSquelch;
    std::unique_ptr<dsp::noise_reduction::FMIF> fmIfNr;
    std::unique_ptr<dsp::noise_reduction::CTCSSSquelch> ctcss;

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
    std::vector<dsp::complex_t> translatedBuffer;
    std::vector<dsp::complex_t> ifBuffer;
    std::vector<float> demodBuffer;
    std::vector<float> audioBuffer;
    std::vector<float> audioBuffer2;
    std::vector<dsp::stereo_t> stereoDemodBuffer;
    std::vector<dsp::stereo_t> stereoAudioBuffer;
    std::vector<dsp::stereo_t> stereoAudioBuffer2;
    std::vector<dsp::stereo_t> ctcssInputBuffer;
    std::vector<dsp::stereo_t> ctcssOutputBuffer;
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

int sdrpp_dsp_set_frequency_offset(
    sdrpp_engine_t engine,
    float offset_hz) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setFrequencyOffset(offset_hz);
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

int sdrpp_dsp_set_ctcss(
    sdrpp_engine_t engine,
    int mode,
    int tone_index) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setCtcss(mode, tone_index);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_get_ctcss(
    sdrpp_engine_t engine,
    int* tone_index,
    float* tone_hz) {
    if (!engine) {
        return 0;
    }
    try {
        return asEngine(engine)->getCtcss(tone_index, tone_hz);
    }
    catch (...) {
        return 0;
    }
}

int sdrpp_dsp_set_fm_ifnr(
    sdrpp_engine_t engine,
    int enabled,
    int preset) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setFmIfNr(enabled != 0, preset);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_am_agc(
    sdrpp_engine_t engine,
    int carrier_agc,
    float attack_ms,
    float decay_ms) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setAmAgc(
            carrier_agc != 0,
            attack_ms,
            decay_ms);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_ssb_agc(
    sdrpp_engine_t engine,
    float attack_ms,
    float decay_ms) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setSsbAgc(attack_ms, decay_ms);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_cw_options(
    sdrpp_engine_t engine,
    int tone_hz,
    float attack_ms,
    float decay_ms) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setCwOptions(
            tone_hz,
            attack_ms,
            decay_ms);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_nfm_options(
    sdrpp_engine_t engine,
    int low_pass) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setNfmOptions(low_pass != 0);
        return 0;
    }
    catch (...) {
        return -1;
    }
}

int sdrpp_dsp_set_wfm_options(
    sdrpp_engine_t engine,
    int stereo,
    int low_pass,
    int rds_enabled) {
    if (!engine) {
        return -1;
    }
    try {
        asEngine(engine)->setWfmOptions(
            stereo != 0,
            low_pass != 0,
            rds_enabled != 0);
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

size_t sdrpp_dsp_process_cf32(
    sdrpp_engine_t engine,
    const float* iq_interleaved,
    size_t complex_samples,
    int16_t* out_pcm,
    size_t out_capacity_samples) {
    if (!engine) {
        return 0;
    }
    try {
        return asEngine(engine)->processComplex(
            iq_interleaved,
            complex_samples,
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
    return "SDR++ official DSP core bridge v5 · CTCSS + FM IFNR + full radio controls";
}

} // extern "C"
