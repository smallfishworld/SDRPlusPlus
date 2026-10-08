#include "../include/sdrpp_mobile_api.h"

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <netinet/in.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

struct RawIqServer {
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

        constexpr double pi = 3.14159265358979323846;
        constexpr double sampleRate = 1024000.0;
        constexpr double audioHz = 1000.0;
        constexpr double deviationHz = 2500.0;
        constexpr std::size_t complexPerBlock = 16384;

        std::vector<int16_t> iq(complexPerBlock * 2);
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

                iq[i * 2] = static_cast<int16_t>(
                    std::lround(
                        26000.0 * std::cos(phase)));
                iq[i * 2 + 1] = static_cast<int16_t>(
                    std::lround(
                        26000.0 * std::sin(phase)));
            }

            const auto* bytes =
                reinterpret_cast<const uint8_t*>(iq.data());
            const std::size_t byteCount =
                iq.size() * sizeof(int16_t);
            std::size_t offset = 0;

            while (offset < byteCount && running.load()) {
                const ssize_t sent = ::send(
                    client,
                    bytes + offset,
                    byteCount - offset,
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

    ~RawIqServer() {
        stop();
    }
};

} // namespace

int main() {
    RawIqServer server;
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

    if (sdrpp_source_connect_network(
            source,
            "127.0.0.1",
            server.port,
            1024000,
            0,
            1,
            145100000) != 0) {
        char error[256]{};
        sdrpp_source_get_last_error(
            source,
            error,
            sizeof(error));
        std::fprintf(
            stderr,
            "Network Source connect failed: %s\n",
            error);
        return 4;
    }

    if (sdrpp_source_get_kind(source) != 3) {
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
        "native Network Source: pcm=%zu spectrum=%zu\n",
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
