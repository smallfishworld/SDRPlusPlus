#include "../include/sdrpp_mobile_api.h"
#include "../../../source_modules/spyserver_source/src/spyserver_protocol.h"

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

struct LocalSpyServer {
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

    void sendMessage(
        int client,
        uint32_t type,
        const void* body,
        std::size_t bodySize) {
        SpyServerMessageHeader header{};
        header.ProtocolID = SPYSERVER_PROTOCOL_VERSION;
        header.MessageType = type;
        header.StreamType = SPYSERVER_STREAM_TYPE_STATUS;
        header.SequenceNumber = 0;
        header.BodySize = static_cast<uint32_t>(bodySize);
        sendAll(client, &header, sizeof(header));
        if (bodySize > 0) {
            sendAll(client, body, bodySize);
        }
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

        SpyServerCommandHeader hello{};
        if (!recvAll(client, &hello, sizeof(hello))) {
            ::close(client);
            return;
        }
        std::vector<uint8_t> helloBody(hello.BodySize);
        if (hello.BodySize > 0 &&
            !recvAll(client, helloBody.data(), helloBody.size())) {
            ::close(client);
            return;
        }

        SpyServerDeviceInfo info{};
        info.DeviceType = SPYSERVER_DEVICE_RTLSDR;
        info.MaximumSampleRate = 2048000;
        info.MaximumBandwidth = 2048000;
        info.DecimationStageCount = 3;
        info.GainStageCount = 1;
        info.MaximumGainIndex = 29;
        info.MinimumFrequency = 24000000;
        info.MaximumFrequency = 1766000000;
        info.Resolution = 1;
        info.MinimumIQDecimation = 0;
        info.ForcedIQFormat = 0;
        sendMessage(
            client,
            SPYSERVER_MSG_TYPE_DEVICE_INFO,
            &info,
            sizeof(info));

        bool streaming = false;
        while (running.load() && !streaming) {
            SpyServerCommandHeader command{};
            if (!recvAll(client, &command, sizeof(command))) {
                break;
            }
            std::vector<uint8_t> body(command.BodySize);
            if (command.BodySize > 0 &&
                !recvAll(client, body.data(), body.size())) {
                break;
            }

            if (command.CommandType == SPYSERVER_CMD_SET_SETTING &&
                body.size() >= sizeof(SpyServerSettingTarget)) {
                SpyServerSettingTarget target{};
                std::memcpy(&target, body.data(), sizeof(target));
                if (target.Setting ==
                        SPYSERVER_SETTING_STREAMING_ENABLED &&
                    target.Value != 0) {
                    streaming = true;
                }
            }
        }

        constexpr double pi = 3.14159265358979323846;
        constexpr double sampleRate = 1024000.0;
        constexpr double audioHz = 1000.0;
        constexpr double deviationHz = 2500.0;
        constexpr std::size_t complexPerBlock = 8192;

        std::vector<int16_t> iq(complexPerBlock * 2);
        double phase = 0.0;
        uint64_t sampleIndex = 0;

        for (int block = 0;
             block < 160 && running.load() && streaming;
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
                    std::lround(26000.0 * std::cos(phase)));
                iq[i * 2 + 1] = static_cast<int16_t>(
                    std::lround(26000.0 * std::sin(phase)));
            }

            SpyServerMessageHeader header{};
            header.ProtocolID = SPYSERVER_PROTOCOL_VERSION;
            header.MessageType = SPYSERVER_MSG_TYPE_INT16_IQ;
            header.StreamType = SPYSERVER_STREAM_TYPE_IQ;
            header.SequenceNumber = static_cast<uint32_t>(block);
            header.BodySize =
                static_cast<uint32_t>(
                    iq.size() * sizeof(int16_t));

            if (!sendAll(client, &header, sizeof(header)) ||
                !sendAll(
                    client,
                    iq.data(),
                    iq.size() * sizeof(int16_t))) {
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

    ~LocalSpyServer() {
        stop();
    }
};

} // namespace

int main() {
    LocalSpyServer server;
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

    if (sdrpp_source_connect_spyserver(
            source,
            "127.0.0.1",
            server.port,
            1024000,
            145100000) != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(
            source,
            error,
            sizeof(error));
        std::fprintf(stderr, "SpyServer connect failed: %s\n", error);
        return 4;
    }

    if (sdrpp_source_get_kind(source) != 5) {
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
        "native SpyServer: sr=%u pcm=%zu spectrum=%zu\n",
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
