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

struct LocalRtlTcpServer {
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

        // Standard rtl_tcp 12-byte tuner header. The upstream SDR++ client
        // tolerates this short prefix before steady-state IQ data.
        const uint8_t header[12] = {
            'R', 'T', 'L', '0',
            0, 0, 0, 6,
            0, 0, 0, 29,
        };
        ::send(client, header, sizeof(header), MSG_NOSIGNAL);

        constexpr double pi = 3.14159265358979323846;
        constexpr double sampleRate = 1024000.0;
        constexpr double audioHz = 1000.0;
        constexpr double deviationHz = 2500.0;
        constexpr std::size_t complexPerBlock = 16384;

        std::vector<uint8_t> iq(complexPerBlock * 2);
        double phase = 0.0;
        uint64_t sampleIndex = 0;

        for (int block = 0; block < 100 && running.load(); ++block) {
            for (std::size_t i = 0; i < complexPerBlock; ++i) {
                const double t =
                    static_cast<double>(sampleIndex + i) /
                    sampleRate;
                const double mod =
                    std::sin(2.0 * pi * audioHz * t);
                phase +=
                    2.0 * pi * deviationHz * mod /
                    sampleRate;

                iq[i * 2] = static_cast<uint8_t>(
                    std::lround(
                        127.5 + 100.0 * std::cos(phase)));
                iq[i * 2 + 1] = static_cast<uint8_t>(
                    std::lround(
                        127.5 + 100.0 * std::sin(phase)));
            }

            std::size_t offset = 0;
            while (offset < iq.size() && running.load()) {
                const ssize_t sent = ::send(
                    client,
                    iq.data() + offset,
                    iq.size() - offset,
                    MSG_NOSIGNAL);
                if (sent <= 0) {
                    running.store(false);
                    break;
                }
                offset += static_cast<std::size_t>(sent);
            }

            sampleIndex += complexPerBlock;
            std::this_thread::sleep_for(
                std::chrono::milliseconds(8));
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

    ~LocalRtlTcpServer() {
        stop();
    }
};

} // namespace

int main() {
    LocalRtlTcpServer server;
    if (!server.start()) {
        std::fprintf(stderr, "failed to start local rtl_tcp server\n");
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

    const int connected =
        sdrpp_source_connect_rtl_tcp(
            source,
            "127.0.0.1",
            server.port,
            1024000,
            145100000);
    if (connected != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(
            source,
            error,
            sizeof(error));
        std::fprintf(
            stderr,
            "native rtl_tcp connect failed: %s\n",
            error);
        sdrpp_source_destroy(source);
        sdrpp_dsp_destroy(engine);
        return 4;
    }

    std::vector<int16_t> pcm(48000 * 2);
    std::vector<float> spectrum(256);
    std::size_t totalPcm = 0;
    std::size_t spectrumBins = 0;

    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::seconds(4);

    while (std::chrono::steady_clock::now() < deadline) {
        totalPcm += sdrpp_source_read_audio(
            source,
            pcm.data(),
            pcm.size());
        const auto bins = sdrpp_source_read_spectrum(
            source,
            spectrum.data(),
            spectrum.size());
        if (bins > 0) {
            spectrumBins = bins;
        }

        if (totalPcm > 4000 && spectrumBins == 256) {
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(20));
    }

    std::printf(
        "native RTL-TCP: connected=%d pcm=%zu spectrum=%zu\n",
        sdrpp_source_is_connected(source),
        totalPcm,
        spectrumBins);

    sdrpp_source_disconnect(source);
    sdrpp_source_destroy(source);
    sdrpp_dsp_destroy(engine);
    server.stop();

    if (totalPcm <= 4000) {
        std::fprintf(stderr, "native RTL-TCP produced no audio\n");
        return 5;
    }
    if (spectrumBins != 256) {
        std::fprintf(stderr, "native RTL-TCP produced no spectrum\n");
        return 6;
    }
    return 0;
}
