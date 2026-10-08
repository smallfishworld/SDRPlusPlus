cmake_minimum_required(VERSION 3.18)

project(sdrpp_mobile_native LANGUAGES CXX)

add_library(sdrpp_mobile SHARED
    sdrpp_mobile_dsp.cpp
    sdrpp_mobile_source.cpp
    remote_sources.cpp
    rtl_sdr_direct.cpp
    ../../decoder_modules/radio/src/rds.cpp
    ../../source_modules/rtl_tcp_source/src/rtl_tcp_client.cpp
    ../../source_modules/rfspace_source/src/rfspace_client.cpp
    ../../source_modules/hermes_source/src/hermes.cpp
    ../../source_modules/spectran_http_source/src/spectran_http_client.cpp
    ../../core/src/utils/net.cpp
    ../../core/src/utils/proto/http.cpp
)

target_compile_features(sdrpp_mobile PRIVATE cxx_std_17)

find_package(Threads REQUIRED)
target_link_libraries(sdrpp_mobile PRIVATE Threads::Threads)
if(UNIX AND NOT APPLE)
    target_link_libraries(sdrpp_mobile PRIVATE dl)
endif()

# The compatibility include must come before SDR++ core/src so <volk/volk.h>
# resolves to the portable bridge shim. The actual DSP implementation is
# directly compiled from SDR++'s official header-only DSP blocks.
target_include_directories(sdrpp_mobile PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/compat
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../core/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../decoder_modules/radio/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/rtl_tcp_source/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/file_source/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/spyserver_source/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/rfspace_source/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/hermes_source/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/spectran_http_source/src
)

if(MSVC)
    target_compile_options(sdrpp_mobile PRIVATE /O2 /EHsc)
else()
    target_compile_options(sdrpp_mobile PRIVATE -O3 -fvisibility=hidden)
endif()

if(ANDROID)
    target_link_libraries(sdrpp_mobile PRIVATE log)
endif()

if(WIN32)
    target_link_libraries(sdrpp_mobile PRIVATE ws2_32 iphlpapi)
endif()

set_target_properties(sdrpp_mobile PROPERTIES
    OUTPUT_NAME "sdrpp_mobile"
)


include(CTest)
if(BUILD_TESTING AND NOT ANDROID)
    add_executable(sdrpp_mobile_ctcss_smoke
        tests/ctcss_smoke.cpp
    )
    target_compile_features(sdrpp_mobile_ctcss_smoke PRIVATE cxx_std_17)
    target_include_directories(sdrpp_mobile_ctcss_smoke PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
    target_link_libraries(sdrpp_mobile_ctcss_smoke PRIVATE sdrpp_mobile)
    add_test(
        NAME sdrpp_mobile_ctcss_smoke
        COMMAND sdrpp_mobile_ctcss_smoke
    )

    add_executable(sdrpp_mobile_fm_ifnr_smoke
        tests/fm_ifnr_smoke.cpp
    )
    target_compile_features(sdrpp_mobile_fm_ifnr_smoke PRIVATE cxx_std_17)
    target_include_directories(sdrpp_mobile_fm_ifnr_smoke PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
    target_link_libraries(sdrpp_mobile_fm_ifnr_smoke PRIVATE sdrpp_mobile)
    add_test(
        NAME sdrpp_mobile_fm_ifnr_smoke
        COMMAND sdrpp_mobile_fm_ifnr_smoke
    )

    if(NOT WIN32)
        add_executable(sdrpp_mobile_rtl_tcp_source_smoke
            tests/rtl_tcp_source_smoke.cpp
        )
        target_compile_features(
            sdrpp_mobile_rtl_tcp_source_smoke
            PRIVATE cxx_std_17
        )
        target_include_directories(
            sdrpp_mobile_rtl_tcp_source_smoke
            PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
        target_link_libraries(
            sdrpp_mobile_rtl_tcp_source_smoke
            PRIVATE sdrpp_mobile Threads::Threads
        )
        add_test(
            NAME sdrpp_mobile_rtl_tcp_source_smoke
            COMMAND sdrpp_mobile_rtl_tcp_source_smoke
        )

        add_executable(sdrpp_mobile_file_source_smoke
            tests/file_source_smoke.cpp
        )
        target_compile_features(
            sdrpp_mobile_file_source_smoke
            PRIVATE cxx_std_17
        )
        target_include_directories(
            sdrpp_mobile_file_source_smoke
            PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
        target_link_libraries(
            sdrpp_mobile_file_source_smoke
            PRIVATE sdrpp_mobile Threads::Threads
        )
        add_test(
            NAME sdrpp_mobile_file_source_smoke
            COMMAND sdrpp_mobile_file_source_smoke
        )

        add_executable(sdrpp_mobile_network_source_smoke
            tests/network_source_smoke.cpp
        )
        target_compile_features(
            sdrpp_mobile_network_source_smoke
            PRIVATE cxx_std_17
        )
        target_include_directories(
            sdrpp_mobile_network_source_smoke
            PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
        target_link_libraries(
            sdrpp_mobile_network_source_smoke
            PRIVATE sdrpp_mobile Threads::Threads
        )
        add_test(
            NAME sdrpp_mobile_network_source_smoke
            COMMAND sdrpp_mobile_network_source_smoke
        )

        add_executable(sdrpp_mobile_spyserver_source_smoke
            tests/spyserver_source_smoke.cpp
        )
        target_compile_features(
            sdrpp_mobile_spyserver_source_smoke
            PRIVATE cxx_std_17
        )
        target_include_directories(
            sdrpp_mobile_spyserver_source_smoke
            PRIVATE
                ${CMAKE_CURRENT_SOURCE_DIR}/include
                ${CMAKE_CURRENT_SOURCE_DIR}/../../source_modules/spyserver_source/src
        )
        target_link_libraries(
            sdrpp_mobile_spyserver_source_smoke
            PRIVATE sdrpp_mobile Threads::Threads
        )
        add_test(
            NAME sdrpp_mobile_spyserver_source_smoke
            COMMAND sdrpp_mobile_spyserver_source_smoke
        )

        add_executable(sdrpp_mobile_sdrpp_server_source_smoke
            tests/sdrpp_server_source_smoke.cpp
        )
        target_compile_features(
            sdrpp_mobile_sdrpp_server_source_smoke
            PRIVATE cxx_std_17
        )
        target_include_directories(
            sdrpp_mobile_sdrpp_server_source_smoke
            PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
        target_link_libraries(
            sdrpp_mobile_sdrpp_server_source_smoke
            PRIVATE sdrpp_mobile Threads::Threads
        )
        add_test(
            NAME sdrpp_mobile_sdrpp_server_source_smoke
            COMMAND sdrpp_mobile_sdrpp_server_source_smoke
        )
    endif()
endif()
