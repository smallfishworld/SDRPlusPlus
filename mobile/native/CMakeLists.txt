cmake_minimum_required(VERSION 3.18)

project(sdrpp_mobile_native LANGUAGES CXX)

add_library(sdrpp_mobile SHARED
    sdrpp_mobile_dsp.cpp
    ../../decoder_modules/radio/src/rds.cpp
)

target_compile_features(sdrpp_mobile PRIVATE cxx_std_17)

# The compatibility include must come before SDR++ core/src so <volk/volk.h>
# resolves to the portable bridge shim. The actual DSP implementation is
# directly compiled from SDR++'s official header-only DSP blocks.
target_include_directories(sdrpp_mobile PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/compat
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../core/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../decoder_modules/radio/src
)

if(MSVC)
    target_compile_options(sdrpp_mobile PRIVATE /O2 /EHsc)
else()
    target_compile_options(sdrpp_mobile PRIVATE -O3 -fvisibility=hidden)
endif()

if(ANDROID)
    target_link_libraries(sdrpp_mobile PRIVATE log)
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
endif()
