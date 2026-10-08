#include "remote_sources.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>

#include "../../source_modules/spyserver_source/src/spyserver_protocol.h"

namespace {

constexpr uint32_t kSpyCommandHello = SPYSERVER_CMD_HELLO;
constexpr uint32_t kSpyCommandSetSetting = SPYSERVER_CMD_SET_SETTING;

constexpr uint32_t kServerPacketCommand = 0;
constexpr uint32_t kServerPacketCommandAck = 1;
constexpr uint32_t kServerPacketBaseband = 2;
constexpr uint32_t kServerPacketBasebandCompressed = 3;
constexpr uint32_t kServerPacketError = 6;

constexpr uint32_t kServerCommandGetUi = 0x00;
constexpr uint32_t kServerCommandStart = 0x02;
constexpr uint32_t kServerCommandStop = 0x03;
constexpr uint32_t kServerCommandSetFrequency = 0x04;
constexpr uint32_t kServerCommandSetSampleType = 0x06;
constexpr uint32_t kServerCommandSetCompression = 0x07;
constexpr uint32_t kServerCommandSetSampleRate = 0x80;
constexpr uint32_t kServerCommandDisconnect = 0x81;

constexpr uint16_t kPcmI8 = 0;
constexpr uint16_t kPcmI16 = 1;
constexpr uint16_t kPcmF32 = 2;

#pragma pack(push, 1)
struct ServerPacketHeader {
    uint32_t type;
    uint32_t size;
};

struct ServerCommandHeader {
    uint32_t command;
};
#pragma pack(pop)

bool sendAll(
    const std::shared_ptr<net::Socket>& socket,
    const uint8_t* data,
    std::size_t size) {
    if (!socket || !socket->isOpen()) {
        return false;
    }
    std::size_t sent = 0;
    while (sent < size) {
        const int count = socket->send(data + sent, size - sent);
        if (count <= 0) {
            return false;
        }
        sent += static_cast<std::size_t>(count);
    }
    return true;
}

} // namespace

namespace mobile {

// -------------------------------------------------------------------------
// SpyServer
// -------------------------------------------------------------------------

SpyServerSourceClient::SpyServerSourceClient(
    dsp::stream<dsp::complex_t>* outputStream)
    : output(outputStream) {}

SpyServerSourceClient::~SpyServerSourceClient() {
    close();
}

bool SpyServerSourceClient::connect(
    const std::string& host,
    int port,
    uint32_t requestedSampleRate,
    uint32_t frequencyHz) {
    close();
    if (!output || host.empty() || port <= 0 || port > 65535) {
        setError("Invalid SpyServer parameters");
        return false;
    }

    try {
        auto nextSocket = net::connect(host, port);
        {
            std::lock_guard<std::mutex> lock(mutex);
            socket = nextSocket;
            error.clear();
        }

        // Official SpyServer HELLO command.
        const std::string appName = "SDR++ Receiver";
        const std::size_t helloBodySize =
            sizeof(SpyServerClientHandshake) + appName.size();
        std::vector<uint8_t> helloBody(helloBodySize);
        auto* handshake =
            reinterpret_cast<SpyServerClientHandshake*>(
                helloBody.data());
        handshake->ProtocolVersion = SPYSERVER_PROTOCOL_VERSION;
        std::memcpy(
            helloBody.data() + sizeof(SpyServerClientHandshake),
            appName.data(),
            appName.size());

        SpyServerCommandHeader helloHeader{};
        helloHeader.CommandType = kSpyCommandHello;
        helloHeader.BodySize =
            static_cast<uint32_t>(helloBody.size());

        std::vector<uint8_t> hello(
            sizeof(helloHeader) + helloBody.size());
        std::memcpy(hello.data(), &helloHeader, sizeof(helloHeader));
        std::memcpy(
            hello.data() + sizeof(helloHeader),
            helloBody.data(),
            helloBody.size());

        if (!sendAll(nextSocket, hello.data(), hello.size())) {
            setError("Could not send SpyServer handshake");
            close();
            return false;
        }

        // Wait for the server's device description before choosing
        // decimation/sample-rate settings.
        bool haveDeviceInfo = false;
        for (int attempt = 0; attempt < 16 && !haveDeviceInfo; ++attempt) {
            uint32_t messageType = 0;
            uint32_t flags = 0;
            std::string body;
            if (!readMessage(messageType, flags, body)) {
                break;
            }

            const uint32_t baseType = messageType & 0xFFFFu;
            if (baseType == SPYSERVER_MSG_TYPE_DEVICE_INFO &&
                body.size() >= sizeof(SpyServerDeviceInfo)) {
                SpyServerDeviceInfo info{};
                std::memcpy(&info, body.data(), sizeof(info));
                deviceInfo.deviceType = info.DeviceType;
                deviceInfo.maxSampleRate = info.MaximumSampleRate;
                deviceInfo.decimationStages = info.DecimationStageCount;
                deviceInfo.maxGainIndex = info.MaximumGainIndex;
                deviceInfo.minFrequency = info.MinimumFrequency;
                deviceInfo.maxFrequency = info.MaximumFrequency;
                deviceInfo.minIqDecimation = info.MinimumIQDecimation;
                deviceInfo.forcedIqFormat = info.ForcedIQFormat;
                haveDeviceInfo = true;
            }
        }

        if (!haveDeviceInfo || deviceInfo.maxSampleRate == 0) {
            setError("SpyServer did not provide device information");
            close();
            return false;
        }

        currentFrequency.store(frequencyHz);
        if (!configureSampleRate(requestedSampleRate)) {
            close();
            return false;
        }

        uint32_t iqFormat = SPYSERVER_STREAM_FORMAT_INT16;
        if (deviceInfo.forcedIqFormat != 0) {
            iqFormat = deviceInfo.forcedIqFormat;
        }

        if (!sendSetting(
                SPYSERVER_SETTING_STREAMING_MODE,
                SPYSERVER_STREAM_MODE_IQ_ONLY) ||
            !sendSetting(SPYSERVER_SETTING_IQ_FORMAT, iqFormat) ||
            !sendSetting(
                SPYSERVER_SETTING_IQ_DECIMATION,
                static_cast<uint32_t>(decimation)) ||
            !sendSetting(
                SPYSERVER_SETTING_IQ_FREQUENCY,
                frequencyHz) ||
            !sendSetting(
                SPYSERVER_SETTING_STREAMING_ENABLED,
                1)) {
            setError("Could not configure SpyServer stream");
            close();
            return false;
        }

        output->clearWriteStop();
        running.store(true);
        connected.store(true);
        workerThread =
            std::thread(&SpyServerSourceClient::worker, this);
        return true;
    }
    catch (const std::exception& e) {
        setError(e.what());
    }
    catch (...) {
        setError("Unknown SpyServer connection error");
    }

    close();
    return false;
}

void SpyServerSourceClient::close() {
    running.store(false);
    connected.store(false);

    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
        socket.reset();
    }

    if (current) {
        try {
            // Best-effort stop command before closing.
            SpyServerCommandHeader header{};
            SpyServerSettingTarget target{};
            header.CommandType = kSpyCommandSetSetting;
            header.BodySize = sizeof(target);
            target.Setting = SPYSERVER_SETTING_STREAMING_ENABLED;
            target.Value = 0;

            std::array<uint8_t, sizeof(header) + sizeof(target)> packet{};
            std::memcpy(packet.data(), &header, sizeof(header));
            std::memcpy(
                packet.data() + sizeof(header),
                &target,
                sizeof(target));
            sendAll(current, packet.data(), packet.size());
            current->close();
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
    if (output) {
        output->clearWriteStop();
    }
}

bool SpyServerSourceClient::isOpen() const {
    if (!connected.load()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex);
    return socket && socket->isOpen();
}

bool SpyServerSourceClient::setFrequency(uint32_t frequencyHz) {
    currentFrequency.store(frequencyHz);
    return sendSetting(
        SPYSERVER_SETTING_IQ_FREQUENCY,
        frequencyHz);
}

bool SpyServerSourceClient::setSampleRate(
    uint32_t requestedSampleRate) {
    return configureSampleRate(requestedSampleRate);
}

bool SpyServerSourceClient::setGain(uint32_t gainIndex) {
    const uint32_t clamped = std::min(
        gainIndex,
        deviceInfo.maxGainIndex);
    return sendSetting(SPYSERVER_SETTING_GAIN, clamped);
}

uint32_t SpyServerSourceClient::sampleRate() const {
    return currentSampleRate.load();
}

std::string SpyServerSourceClient::lastError() const {
    std::lock_guard<std::mutex> lock(mutex);
    return error;
}

bool SpyServerSourceClient::configureSampleRate(
    uint32_t requestedSampleRate) {
    if (deviceInfo.maxSampleRate == 0) {
        setError("SpyServer sample-rate metadata unavailable");
        return false;
    }

    const int minStage = static_cast<int>(
        deviceInfo.minIqDecimation);
    const int maxStage = static_cast<int>(
        std::max(
            deviceInfo.minIqDecimation,
            deviceInfo.decimationStages));

    int bestStage = minStage;
    uint32_t bestRate =
        deviceInfo.maxSampleRate >>
        std::min(bestStage, 30);
    uint64_t bestDelta =
        bestRate > requestedSampleRate
            ? static_cast<uint64_t>(bestRate - requestedSampleRate)
            : static_cast<uint64_t>(requestedSampleRate - bestRate);

    for (int stage = minStage; stage <= maxStage; ++stage) {
        const uint32_t rate =
            deviceInfo.maxSampleRate >>
            std::min(stage, 30);
        if (rate == 0) {
            continue;
        }
        const uint64_t delta =
            rate > requestedSampleRate
                ? static_cast<uint64_t>(rate - requestedSampleRate)
                : static_cast<uint64_t>(requestedSampleRate - rate);
        if (delta < bestDelta) {
            bestDelta = delta;
            bestStage = stage;
            bestRate = rate;
        }
    }

    decimation = bestStage;
    currentSampleRate.store(bestRate);

    return sendSetting(
        SPYSERVER_SETTING_IQ_DECIMATION,
        static_cast<uint32_t>(bestStage));
}

bool SpyServerSourceClient::sendSetting(
    uint32_t setting,
    uint32_t value) {
    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
    }
    if (!current || !current->isOpen()) {
        return false;
    }

    SpyServerCommandHeader header{};
    SpyServerSettingTarget target{};
    header.CommandType = kSpyCommandSetSetting;
    header.BodySize = sizeof(target);
    target.Setting = setting;
    target.Value = value;

    std::array<uint8_t, sizeof(header) + sizeof(target)> packet{};
    std::memcpy(packet.data(), &header, sizeof(header));
    std::memcpy(
        packet.data() + sizeof(header),
        &target,
        sizeof(target));
    return sendAll(current, packet.data(), packet.size());
}

bool SpyServerSourceClient::readMessage(
    uint32_t& messageType,
    uint32_t& flags,
    std::string& body) {
    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
    }
    if (!current || !current->isOpen()) {
        return false;
    }

    SpyServerMessageHeader header{};
    const int headerBytes = current->recv(
        reinterpret_cast<uint8_t*>(&header),
        sizeof(header),
        true,
        5000);
    if (headerBytes != static_cast<int>(sizeof(header))) {
        return false;
    }
    if (header.BodySize > SPYSERVER_MAX_MESSAGE_BODY_SIZE) {
        setError("SpyServer message is too large");
        return false;
    }

    body.resize(header.BodySize);
    if (header.BodySize > 0) {
        const int count = current->recv(
            reinterpret_cast<uint8_t*>(body.data()),
            header.BodySize,
            true,
            5000);
        if (count != static_cast<int>(header.BodySize)) {
            return false;
        }
    }

    messageType = header.MessageType & 0xFFFFu;
    flags = (header.MessageType >> 16u) & 0xFFFFu;
    return true;
}

void SpyServerSourceClient::worker() {
    while (running.load()) {
        uint32_t messageType = 0;
        uint32_t flags = 0;
        std::string body;
        if (!readMessage(messageType, flags, body)) {
            break;
        }

        if (messageType == SPYSERVER_MSG_TYPE_UINT8_IQ ||
            messageType == SPYSERVER_MSG_TYPE_INT16_IQ ||
            messageType == SPYSERVER_MSG_TYPE_FLOAT_IQ) {
            pushIq(
                reinterpret_cast<const uint8_t*>(body.data()),
                body.size(),
                messageType,
                flags);
        }
    }

    connected.store(false);
    running.store(false);
}

void SpyServerSourceClient::pushIq(
    const uint8_t* data,
    std::size_t bytes,
    uint32_t messageType,
    uint32_t flags) {
    if (!output || !data || bytes == 0) {
        return;
    }

    const float gain = std::pow(
        10.0f,
        static_cast<float>(flags) / 20.0f);
    const float safeGain =
        std::isfinite(gain) && gain > 0.000001f
            ? gain
            : 1.0f;

    std::size_t count = 0;
    if (messageType == SPYSERVER_MSG_TYPE_UINT8_IQ) {
        count = bytes / 2u;
    }
    else if (messageType == SPYSERVER_MSG_TYPE_INT16_IQ) {
        count = bytes / (sizeof(int16_t) * 2u);
    }
    else if (messageType == SPYSERVER_MSG_TYPE_FLOAT_IQ) {
        count = bytes / (sizeof(float) * 2u);
    }

    std::size_t offset = 0;
    while (offset < count && running.load()) {
        const std::size_t chunk = std::min<std::size_t>(
            count - offset,
            STREAM_BUFFER_SIZE);

        if (messageType == SPYSERVER_MSG_TYPE_UINT8_IQ) {
            const auto* in = data + offset * 2u;
            const float scale = 1.0f / (safeGain * 128.0f);
            for (std::size_t i = 0; i < chunk; ++i) {
                output->writeBuf[i].re =
                    (static_cast<float>(in[i * 2u]) - 128.0f) * scale;
                output->writeBuf[i].im =
                    (static_cast<float>(in[i * 2u + 1u]) - 128.0f) * scale;
            }
        }
        else if (messageType == SPYSERVER_MSG_TYPE_INT16_IQ) {
            const auto* in =
                reinterpret_cast<const int16_t*>(data) +
                offset * 2u;
            const float scale = 1.0f / (safeGain * 32768.0f);
            for (std::size_t i = 0; i < chunk; ++i) {
                output->writeBuf[i].re =
                    static_cast<float>(in[i * 2u]) * scale;
                output->writeBuf[i].im =
                    static_cast<float>(in[i * 2u + 1u]) * scale;
            }
        }
        else {
            const auto* in =
                reinterpret_cast<const float*>(data) +
                offset * 2u;
            for (std::size_t i = 0; i < chunk; ++i) {
                output->writeBuf[i].re =
                    in[i * 2u] * safeGain;
                output->writeBuf[i].im =
                    in[i * 2u + 1u] * safeGain;
            }
        }

        if (!output->swap(static_cast<int>(chunk))) {
            break;
        }
        offset += chunk;
    }
}

void SpyServerSourceClient::setError(
    const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    error = value;
}

// -------------------------------------------------------------------------
// SDR++ Server
// -------------------------------------------------------------------------

SdrppServerSourceClient::SdrppServerSourceClient(
    dsp::stream<dsp::complex_t>* outputStream)
    : output(outputStream) {}

SdrppServerSourceClient::~SdrppServerSourceClient() {
    close();
}

bool SdrppServerSourceClient::connect(
    const std::string& host,
    int port,
    uint32_t frequencyHz) {
    close();
    if (!output || host.empty() || port <= 0 || port > 65535) {
        setError("Invalid SDR++ Server parameters");
        return false;
    }

    try {
        auto nextSocket = net::connect(host, port);
        {
            std::lock_guard<std::mutex> lock(mutex);
            socket = nextSocket;
            error.clear();
        }

        // The official client requests the remote source UI first. Apart from
        // reserving the server, the reply may also contain a sample-rate
        // notification. The mobile client discards the GUI draw list.
        if (!awaitUi()) {
            close();
            return false;
        }

        const uint8_t sampleType =
            static_cast<uint8_t>(kPcmI16);
        const uint8_t compression = 0;
        if (!sendCommand(
                kServerCommandSetSampleType,
                &sampleType,
                sizeof(sampleType)) ||
            !sendCommand(
                kServerCommandSetCompression,
                &compression,
                sizeof(compression))) {
            setError("Could not configure SDR++ Server stream");
            close();
            return false;
        }

        currentFrequency.store(frequencyHz);
        const double frequency =
            static_cast<double>(frequencyHz);
        if (!sendCommand(
                kServerCommandSetFrequency,
                &frequency,
                sizeof(frequency)) ||
            !sendCommand(kServerCommandStart, nullptr, 0)) {
            setError("Could not start SDR++ Server stream");
            close();
            return false;
        }

        output->clearWriteStop();
        running.store(true);
        connected.store(true);
        workerThread =
            std::thread(&SdrppServerSourceClient::worker, this);
        return true;
    }
    catch (const std::exception& e) {
        setError(e.what());
    }
    catch (...) {
        setError("Unknown SDR++ Server connection error");
    }

    close();
    return false;
}

void SdrppServerSourceClient::close() {
    running.store(false);
    connected.store(false);

    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
    }

    if (current && current->isOpen()) {
        try {
            sendCommand(kServerCommandStop, nullptr, 0);
            current->close();
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
    if (output) {
        output->clearWriteStop();
    }

    {
        std::lock_guard<std::mutex> lock(mutex);
        socket.reset();
    }
}

bool SdrppServerSourceClient::isOpen() const {
    if (!connected.load()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex);
    return socket && socket->isOpen();
}

bool SdrppServerSourceClient::setFrequency(
    uint32_t frequencyHz) {
    currentFrequency.store(frequencyHz);
    const double frequency =
        static_cast<double>(frequencyHz);
    return sendCommand(
        kServerCommandSetFrequency,
        &frequency,
        sizeof(frequency));
}

uint32_t SdrppServerSourceClient::sampleRate() const {
    return currentSampleRate.load();
}

std::string SdrppServerSourceClient::lastError() const {
    std::lock_guard<std::mutex> lock(mutex);
    return error;
}

bool SdrppServerSourceClient::sendCommand(
    uint32_t command,
    const void* data,
    std::size_t bytes) {
    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
    }
    if (!current || !current->isOpen()) {
        return false;
    }

    ServerPacketHeader packet{};
    ServerCommandHeader commandHeader{};
    packet.type = kServerPacketCommand;
    packet.size = static_cast<uint32_t>(
        sizeof(packet) + sizeof(commandHeader) + bytes);
    commandHeader.command = command;

    std::vector<uint8_t> buffer(packet.size);
    std::memcpy(buffer.data(), &packet, sizeof(packet));
    std::memcpy(
        buffer.data() + sizeof(packet),
        &commandHeader,
        sizeof(commandHeader));
    if (bytes > 0 && data) {
        std::memcpy(
            buffer.data() + sizeof(packet) + sizeof(commandHeader),
            data,
            bytes);
    }
    return sendAll(current, buffer.data(), buffer.size());
}

bool SdrppServerSourceClient::readPacket(
    uint32_t& type,
    std::string& payload,
    int timeoutMs) {
    std::shared_ptr<net::Socket> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = socket;
    }
    if (!current || !current->isOpen()) {
        return false;
    }

    ServerPacketHeader header{};
    const int headerBytes = current->recv(
        reinterpret_cast<uint8_t*>(&header),
        sizeof(header),
        true,
        timeoutMs);
    if (headerBytes != static_cast<int>(sizeof(header))) {
        return false;
    }
    if (header.size < sizeof(header) ||
        header.size > 16u * 1024u * 1024u) {
        setError("Invalid SDR++ Server packet size");
        return false;
    }

    const std::size_t payloadSize =
        header.size - sizeof(header);
    payload.resize(payloadSize);
    if (payloadSize > 0) {
        const int read = current->recv(
            reinterpret_cast<uint8_t*>(payload.data()),
            payloadSize,
            true,
            timeoutMs);
        if (read != static_cast<int>(payloadSize)) {
            return false;
        }
    }

    type = header.type;
    return true;
}

bool SdrppServerSourceClient::awaitUi() {
    if (!sendCommand(kServerCommandGetUi, nullptr, 0)) {
        setError("Could not request SDR++ Server source UI");
        return false;
    }

    for (int attempt = 0; attempt < 32; ++attempt) {
        uint32_t type = 0;
        std::string payload;
        if (!readPacket(type, payload, 10000)) {
            setError("Timed out waiting for SDR++ Server");
            return false;
        }

        if (type == kServerPacketCommand) {
            handleCommand(
                reinterpret_cast<const uint8_t*>(payload.data()),
                payload.size());
            continue;
        }

        if (type == kServerPacketCommandAck &&
            payload.size() >= sizeof(ServerCommandHeader)) {
            ServerCommandHeader header{};
            std::memcpy(
                &header,
                payload.data(),
                sizeof(header));
            if (header.command == kServerCommandGetUi) {
                return true;
            }
        }

        if (type == kServerPacketError) {
            setError("SDR++ Server rejected the connection");
            return false;
        }
    }

    setError("SDR++ Server UI handshake did not complete");
    return false;
}

void SdrppServerSourceClient::worker() {
    while (running.load()) {
        uint32_t type = 0;
        std::string payload;
        if (!readPacket(type, payload, 5000)) {
            break;
        }

        if (type == kServerPacketCommand) {
            handleCommand(
                reinterpret_cast<const uint8_t*>(payload.data()),
                payload.size());
        }
        else if (type == kServerPacketBaseband) {
            handleBaseband(
                reinterpret_cast<const uint8_t*>(payload.data()),
                payload.size());
        }
        else if (type == kServerPacketBasebandCompressed) {
            // Compression is explicitly disabled during setup. Receiving this
            // indicates a server that ignored the negotiated setting.
            setError(
                "SDR++ Server sent compressed baseband after compression was disabled");
        }
        else if (type == kServerPacketError) {
            setError("SDR++ Server reported a protocol error");
        }
    }

    connected.store(false);
    running.store(false);
}

void SdrppServerSourceClient::handleCommand(
    const uint8_t* data,
    std::size_t size) {
    if (!data || size < sizeof(ServerCommandHeader)) {
        return;
    }

    ServerCommandHeader header{};
    std::memcpy(&header, data, sizeof(header));
    const uint8_t* body = data + sizeof(header);
    const std::size_t bodySize =
        size - sizeof(header);

    if (header.command == kServerCommandSetSampleRate &&
        bodySize >= sizeof(double)) {
        double rate = 0.0;
        std::memcpy(&rate, body, sizeof(rate));
        if (std::isfinite(rate) && rate >= 1000.0) {
            currentSampleRate.store(
                static_cast<uint32_t>(std::llround(rate)));
        }
    }
    else if (header.command == kServerCommandDisconnect) {
        setError("SDR++ Server is busy or requested disconnect");
        connected.store(false);
        running.store(false);
    }
}

void SdrppServerSourceClient::handleBaseband(
    const uint8_t* data,
    std::size_t size) {
    if (!data || size <= 8u || !output) {
        return;
    }

    uint16_t sampleType = 0;
    float scaler = 1.0f;
    std::memcpy(&sampleType, data + 2, sizeof(sampleType));
    std::memcpy(&scaler, data + 4, sizeof(scaler));
    if (!std::isfinite(scaler) || scaler == 0.0f) {
        scaler = 1.0f;
    }

    const uint8_t* samples = data + 8u;
    const std::size_t sampleBytes = size - 8u;
    std::size_t count = 0;
    if (sampleType == kPcmF32) {
        count = sampleBytes / sizeof(dsp::complex_t);
    }
    else if (sampleType == kPcmI16) {
        count = sampleBytes / (sizeof(int16_t) * 2u);
    }
    else if (sampleType == kPcmI8) {
        count = sampleBytes / (sizeof(int8_t) * 2u);
    }
    else {
        return;
    }

    std::size_t offset = 0;
    while (offset < count && running.load()) {
        const std::size_t chunk = std::min<std::size_t>(
            count - offset,
            STREAM_BUFFER_SIZE);

        if (sampleType == kPcmF32) {
            const auto* in =
                reinterpret_cast<const dsp::complex_t*>(samples) +
                offset;
            std::memcpy(
                output->writeBuf,
                in,
                chunk * sizeof(dsp::complex_t));
        }
        else if (sampleType == kPcmI16) {
            const auto* in =
                reinterpret_cast<const int16_t*>(samples) +
                offset * 2u;
            const float scale = scaler / 32768.0f;
            for (std::size_t i = 0; i < chunk; ++i) {
                output->writeBuf[i].re =
                    static_cast<float>(in[i * 2u]) * scale;
                output->writeBuf[i].im =
                    static_cast<float>(in[i * 2u + 1u]) * scale;
            }
        }
        else {
            const auto* in =
                reinterpret_cast<const int8_t*>(samples) +
                offset * 2u;
            const float scale = scaler / 128.0f;
            for (std::size_t i = 0; i < chunk; ++i) {
                output->writeBuf[i].re =
                    static_cast<float>(in[i * 2u]) * scale;
                output->writeBuf[i].im =
                    static_cast<float>(in[i * 2u + 1u]) * scale;
            }
        }

        if (!output->swap(static_cast<int>(chunk))) {
            break;
        }
        offset += chunk;
    }
}

void SdrppServerSourceClient::pushComplex(
    const dsp::complex_t* data,
    std::size_t count) {
    if (!data || !output) {
        return;
    }
    std::size_t offset = 0;
    while (offset < count && running.load()) {
        const std::size_t chunk =
            std::min<std::size_t>(
                count - offset,
                STREAM_BUFFER_SIZE);
        std::memcpy(
            output->writeBuf,
            data + offset,
            chunk * sizeof(dsp::complex_t));
        if (!output->swap(static_cast<int>(chunk))) {
            break;
        }
        offset += chunk;
    }
}

void SdrppServerSourceClient::setError(
    const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    error = value;
}

} // namespace mobile
