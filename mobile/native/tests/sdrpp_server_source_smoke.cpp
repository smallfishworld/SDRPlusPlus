#include "../include/sdrpp_mobile_api.h"

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kPacketCommand = 0;
constexpr uint32_t kPacketCommandAck = 1;
constexpr uint32_t kPacketBaseband = 2;

constexpr uint32_t kCommandGetUi = 0x00;
constexpr uint32_t kCommandStart = 0x02;
constexpr uint32_t kCommandSetSampleRate = 0x80;

#pragma pack(push, 1)
struct PacketHeader {
    uint32_t type;
    uint32_t size;
};

struct CommandHeader {
    uint32_t command;
};
#pragma pack(pop)

bool recvAll(int fd, void* data, std::size_t size) {
    auto* out = static_cast<uint8_t*>(data);
    std::size_t offset = 0;
    while (offset < size) {
        const ssize_t n = ::recv(fd, out + offset, size - offset, 0);
        if (n <= 0) {
            return false;
        }
        offset += static_cast<std::size_t>(n);
    }
    return true;
}

bool sendAll(int fd, const void* data, std::size_t size) {
    const auto* in = static_cast<const uint8_t*>(data);
    std::size_t offset = 0;
    while (offset < size) {
        const ssize_t n = ::send(
            fd,
            in + offset,
            size - offset,
            MSG_NOSIGNAL);
        if (n <= 0) {
            return false;
        }
        offset += static_cast<std::size_t>(n);
    }
    return true;
}

bool recvPacket(
    int client,
    uint32_t& type,
    std::vector<uint8_t>& payload) {
    PacketHeader header{};
    if (!recvAll(client, &header, sizeof(header))) {
        return false;
    }
    if (header.size < sizeof(header) ||
        header.size > 16u * 1024u * 1024u) {
        return false;
    }
    type = header.type;
    payload.resize(header.size - sizeof(header));
    if (!payload.empty() &&
        !recvAll(client, payload.data(), payload.size())) {
        return false;
    }
    return true;
}

bool sendCommandPacket(
    int client,
    uint32_t packetType,
    uint32_t command,
    const void* body,
    std::size_t bodySize) {
    PacketHeader packet{};
    CommandHeader cmd{};
    packet.type = packetType;
    packet.size = static_cast<uint32_t>(
        sizeof(packet) + sizeof(cmd) + bodySize);
    cmd.command = command;

    std::vector<uint8_t> bytes(packet.size);
    std::memcpy(bytes.data(), &packet, sizeof(packet));
    std::memcpy(
        bytes.data() + sizeof(packet),
        &cmd,
        sizeof(cmd));
    if (bodySize > 0 && body) {
        std::memcpy(
            bytes.data() + sizeof(packet) + sizeof(cmd),
            body,
            bodySize);
    }
    return sendAll(client, bytes.data(), bytes.size());
}

struct LocalSdrppServer {
    int listenFd = -1;
    uint16_t port = 0;
    std::thread worker;
    std::atomic<bool> running{true};

    bool start() {
        listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd < 0) {
            return false;
        }

        int reuse = 1;
        setsockopt(
            listenFd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            sizeof(reuse));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;

        if (::bind(
                listenFd,
                reinterpret_cast<sockaddr*>(&addr),
                sizeof(addr)) != 0) {
            return false;
        }

        socklen_t len = sizeof(addr);
        if (::getsockname(
                listenFd,
                reinterpret_cast<sockaddr*>(&addr),
                &len) != 0) {
            return false;
        }
        port = ntohs(addr.sin_port);

        if (::listen(listenFd, 1) != 0) {
            return false;
        }

        worker = std::thread([this] { serve(); });
        return true;
    }

    void serve() {
        sockaddr_in clientAddr{};
        socklen_t clientLen = sizeof(clientAddr);
        const int client = ::accept(
            listenFd,
            reinterpret_cast<sockaddr*>(&clientAddr),
            &clientLen);
        if (client < 0) {
            return;
        }

        uint32_t type = 0;
        std::vector<uint8_t> payload;
        if (!recvPacket(client, type, payload) ||
            type != kPacketCommand ||
            payload.size() < sizeof(CommandHeader)) {
            ::close(client);
            return;
        }

        CommandHeader first{};
        std::memcpy(&first, payload.data(), sizeof(first));
        if (first.command != kCommandGetUi) {
            ::close(client);
            return;
        }

        if (!sendCommandPacket(
                client,
                kPacketCommandAck,
                kCommandGetUi,
                nullptr,
                0)) {
            ::close(client);
            return;
        }

        const double sampleRate = 1024000.0;
        sendCommandPacket(
            client,
            kPacketCommand,
            kCommandSetSampleRate,
            &sampleRate,
            sizeof(sampleRate));

        bool started = false;
        for (int i = 0; i < 8 && running.load(); ++i) {
            if (!recvPacket(client, type, payload)) {
                break;
            }
            if (type == kPacketCommand &&
                payload.size() >= sizeof(CommandHeader)) {
                CommandHeader cmd{};
                std::memcpy(&cmd, payload.data(), sizeof(cmd));
                if (cmd.command == kCommandStart) {
                    started = true;
                    break;
                }
            }
        }

        if (!started) {
            ::close(client);
            return;
        }

        constexpr double pi = 3.14159265358979323846;
        constexpr double audioHz = 1000.0;
        constexpr double deviationHz = 2500.0;
        constexpr std::size_t complexPerBlock = 8192;

        std::vector<uint8_t> body(
            8u + complexPerBlock * sizeof(int16_t) * 2u);
        uint16_t compression = 0;
        uint16_t sampleType = 1;
        float scaler = 0.9f;
        std::memcpy(body.data(), &compression, sizeof(compression));
        std::memcpy(body.data() + 2, &sampleType, sizeof(sampleType));
        std::memcpy(body.data() + 4, &scaler, sizeof(scaler));
        auto* iq =
            reinterpret_cast<int16_t*>(body.data() + 8u);

        double phase = 0.0;
        uint64_t sampleIndex = 0;

        for (int block = 0;
             block < 160 && running.load();
             ++block) {
            for (std::size_t i = 0; i < complexPerBlock; ++i) {
                const double t =
                    static_cast<double>(sampleIndex + i) /
                    sampleRate;
                const double mod =
                    std::sin(2.0 * pi * audioHz * t);
                phase +=
                    2.0 * pi * deviationHz * mod /
                    sampleRate;

                iq[i * 2] = static_cast<int16_t>(
                    std::lround(
                        28000.0 * std::cos(phase)));
                iq[i * 2 + 1] = static_cast<int16_t>(
                    std::lround(
                        28000.0 * std::sin(phase)));
            }

            PacketHeader packet{};
            packet.type = kPacketBaseband;
            packet.size = static_cast<uint32_t>(
                sizeof(packet) + body.size());
            if (!sendAll(client, &packet, sizeof(packet)) ||
                !sendAll(client, body.data(), body.size())) {
                break;
            }

            sampleIndex += complexPerBlock;
            std::this_thread::sleep_for(
                std::chrono::milliseconds(6));
        }

        ::shutdown(client, SHUT_RDWR);
        ::close(client);
    }

    void stop() {
        running.store(false);
        if (listenFd >= 0) {
            ::shutdown(listenFd, SHUT_RDWR);
            ::close(listenFd);
            listenFd = -1;
        }
        if (worker.joinable()) {
            worker.join();
        }
    }

    ~LocalSdrppServer() {
        stop();
    }
};

} // namespace

int main() {
    LocalSdrppServer server;
    if (!server.start()) {
        return 1;
    }

    sdrpp_engine_t engine =
        sdrpp_dsp_create(
            1024000,
            SDRPP_MODE_NFM,
            12500.0f);
    if (!engine) {
        return 2;
    }

    sdrpp_source_t source = sdrpp_source_create(engine);
    if (!source) {
        sdrpp_dsp_destroy(engine);
        return 3;
    }

    if (sdrpp_source_connect_sdrpp_server(
            source,
            "127.0.0.1",
            server.port,
            145100000) != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(
            source,
            error,
            sizeof(error));
        std::fprintf(
            stderr,
            "SDR++ Server connect failed: %s\n",
            error);
        return 4;
    }

    if (sdrpp_source_get_kind(source) != 4) {
        return 5;
    }

    std::vector<int16_t> pcm(48000 * 2);
    std::vector<float> spectrum(256);
    std::size_t totalPcm = 0;
    std::size_t bins = 0;

    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::seconds(4);

    while (std::chrono::steady_clock::now() < deadline) {
        totalPcm += sdrpp_source_read_audio(
            source,
            pcm.data(),
            pcm.size());
        const auto n = sdrpp_source_read_spectrum(
            source,
            spectrum.data(),
            spectrum.size());
        if (n > 0) {
            bins = n;
        }

        if (totalPcm > 4000 && bins == 256) {
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(20));
    }

    std::printf(
        "native SDR++ Server: sr=%u pcm=%zu spectrum=%zu\n",
        sdrpp_source_get_sample_rate(source),
        totalPcm,
        bins);

    sdrpp_source_disconnect(source);
    sdrpp_source_destroy(source);
    sdrpp_dsp_destroy(engine);
    server.stop();

    if (totalPcm <= 4000) {
        return 6;
    }
    if (bins != 256) {
        return 7;
    }
    return 0;
}
