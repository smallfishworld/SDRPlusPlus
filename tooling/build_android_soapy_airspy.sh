#!/usr/bin/env bash
set -euxo pipefail

: "${NDK:?NDK is required}"
: "${DEPS:?DEPS is required}"
: "${SOAPY_PREFIX:?SOAPY_PREFIX is required}"
: "${JNI:?JNI is required}"
: "${LIBUSB_SO:?LIBUSB_SO is required}"

cd "$DEPS"

rm -rf airspy airspy-build soapy-airspy soapy-airspy-build

git clone --depth 1 https://github.com/airspy/airspyone_host.git airspy

python3 - <<'PY'
from pathlib import Path

p = Path("airspy/libairspy/src/CMakeLists.txt")
text = p.read_text()
text = text.replace(
    "set_target_properties(airspy PROPERTIES VERSION ${AIRSPY_VER_MAJOR}.${AIRSPY_VER_MINOR}.${AIRSPY_VER_REVISION})",
    "# Android APK packages the unversioned shared library",
)
text = text.replace(
    "set_target_properties(airspy PROPERTIES SOVERSION 0)",
    "# Android APK packages the unversioned shared library",
)
p.write_text(text)
PY

cmake \
  -S airspy/libairspy \
  -B airspy-build \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SOAPY_PREFIX" \
  -DTHREADS_HAVE_PTHREAD_ARG=TRUE \
  -DTHREADS_PTHREAD_ARG=2 \
  -DLIBUSB_INCLUDE_DIR="$DEPS/libusb/libusb" \
  -DLIBUSB_LIBRARIES="$LIBUSB_SO"
cmake --build airspy-build --parallel 2
cmake --install airspy-build

AIRSPY_SO="$(find "$SOAPY_PREFIX" -name 'libairspy.so' -type f | head -n 1)"
test -f "$AIRSPY_SO"

git clone --depth 1 https://github.com/pothosware/SoapyAirspy.git soapy-airspy

python3 - <<'PY'
from pathlib import Path

p = Path("soapy-airspy/Settings.cpp")
text = p.read_text()
old = '''    if (args.count("serial") != 0)
    {
        try {
            serial = std::stoull(args.at("serial"), nullptr, 16);
        } catch (const std::invalid_argument &) {
            throw std::runtime_error("serial is not a hex number");
        } catch (const std::out_of_range &) {
            throw std::runtime_error("serial value of out range");
        }
        serialstr << std::hex << serial;
        if (airspy_open_sn(&dev, serial) != AIRSPY_SUCCESS) {
            throw std::runtime_error("Unable to open AirSpy device with serial " + serialstr.str());
        }
        SoapySDR_logf(SOAPY_SDR_DEBUG, "Found AirSpy device: serial = %" PRIx64, serial);
    }
    else
    {
        if (airspy_open(&dev) != AIRSPY_SUCCESS) {
            throw std::runtime_error("Unable to open AirSpy device");
        }
    }
'''
new = '''    if (args.count("fd") != 0)
    {
        const int fd = std::stoi(args.at("fd"));
        if (airspy_open_fd(&dev, fd) != AIRSPY_SUCCESS) {
            throw std::runtime_error("Unable to open AirSpy Android USB descriptor");
        }
        SoapySDR_logf(SOAPY_SDR_DEBUG, "Opened AirSpy from Android USB fd %d", fd);
    }
    else if (args.count("serial") != 0)
    {
        try {
            serial = std::stoull(args.at("serial"), nullptr, 16);
        } catch (const std::invalid_argument &) {
            throw std::runtime_error("serial is not a hex number");
        } catch (const std::out_of_range &) {
            throw std::runtime_error("serial value of out range");
        }
        serialstr << std::hex << serial;
        if (airspy_open_sn(&dev, serial) != AIRSPY_SUCCESS) {
            throw std::runtime_error("Unable to open AirSpy device with serial " + serialstr.str());
        }
        SoapySDR_logf(SOAPY_SDR_DEBUG, "Found AirSpy device: serial = %" PRIx64, serial);
    }
    else
    {
        if (airspy_open(&dev) != AIRSPY_SUCCESS) {
            throw std::runtime_error("Unable to open AirSpy device");
        }
    }
'''
if old not in text:
    raise SystemExit("SoapyAirspy constructor patch marker not found")
p.write_text(text.replace(old, new))
PY

cmake \
  -S soapy-airspy \
  -B soapy-airspy-build \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SOAPY_PREFIX" \
  -DSoapySDR_DIR="$SOAPY_PREFIX/share/cmake/SoapySDR" \
  -DLibAIRSPY_INCLUDE_DIRS="$SOAPY_PREFIX/include" \
  -DLibAIRSPY_LIBRARIES="$AIRSPY_SO"
cmake --build soapy-airspy-build --parallel 2
cmake --install soapy-airspy-build

AIRSPY_MODULE="$(find "$SOAPY_PREFIX" -name 'libairspySupport.so' -type f | head -n 1)"
test -f "$AIRSPY_MODULE"

cp "$AIRSPY_SO" "$JNI/libairspy.so"
cp "$AIRSPY_MODULE" "$JNI/libairspySupport.so"

file "$JNI/libairspy.so" "$JNI/libairspySupport.so"
readelf -d "$JNI/libairspySupport.so" | grep NEEDED || true
