#!/usr/bin/env bash
set -euxo pipefail

: "${NDK:?NDK is required}"
: "${DEPS:?DEPS is required}"
: "${SOAPY_PREFIX:?SOAPY_PREFIX is required}"
: "${JNI:?JNI is required}"
: "${LIBUSB_SO:?LIBUSB_SO is required}"

cd "$DEPS"
rm -rf hackrf hackrf-build soapy-hackrf soapy-hackrf-build

git clone --depth 1 https://github.com/greatscottgadgets/hackrf.git hackrf

python3 - <<'PY'
from pathlib import Path

src = Path("hackrf/host/libhackrf/src/hackrf.c")
text = src.read_text()

old_init = """int ADDCALL hackrf_init(void)
{
	int libusb_error;
	if (g_libusb_context != NULL) {
		return HACKRF_SUCCESS;
	}

	libusb_error = libusb_init(&g_libusb_context);
"""
new_init = """int ADDCALL hackrf_init(void)
{
	int libusb_error;
	if (g_libusb_context != NULL) {
		return HACKRF_SUCCESS;
	}

#ifdef __ANDROID__
	/* Android UsbManager owns discovery and permission. Native code receives
	 * an already-open descriptor and wraps it with libusb. */
	libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY, NULL);
#endif

	libusb_error = libusb_init(&g_libusb_context);
"""
if old_init not in text:
    raise SystemExit("hackrf_init patch marker not found")
text = text.replace(old_init, new_init)

open_marker = """int ADDCALL hackrf_open(hackrf_device** device)
{
"""
fd_impl = """int ADDCALL hackrf_open_fd(int fd, hackrf_device** device)
{
	libusb_device_handle* usb_device = NULL;
	int result;

	if (device == NULL || fd < 0) {
		return HACKRF_ERROR_INVALID_PARAM;
	}

	if (g_libusb_context == NULL) {
		result = hackrf_init();
		if (result != HACKRF_SUCCESS) {
			return result;
		}
	}

	result = libusb_wrap_sys_device(
		g_libusb_context,
		(intptr_t) fd,
		&usb_device);
	if (result != LIBUSB_SUCCESS || usb_device == NULL) {
		last_libusb_error = result;
		return HACKRF_ERROR_LIBUSB;
	}

	return hackrf_open_setup(usb_device, device);
}

"""
if open_marker not in text:
    raise SystemExit("hackrf_open implementation marker not found")
text = text.replace(open_marker, fd_impl + open_marker, 1)
src.write_text(text)

hdr = Path("hackrf/host/libhackrf/src/hackrf.h")
text = hdr.read_text()
proto_marker = """extern ADDAPI int ADDCALL hackrf_open(hackrf_device** device);
"""
proto = """/**
 * Open a HackRF using an already-authorized Android UsbManager file descriptor.
 * The descriptor remains owned by the Android UsbDeviceConnection.
 */
extern ADDAPI int ADDCALL hackrf_open_fd(int fd, hackrf_device** device);

extern ADDAPI int ADDCALL hackrf_open(hackrf_device** device);
"""
if proto_marker not in text:
    raise SystemExit("hackrf_open header marker not found")
text = text.replace(proto_marker, proto, 1)
hdr.write_text(text)

cmake = Path("hackrf/host/libhackrf/src/CMakeLists.txt")
text = cmake.read_text()
text = text.replace(
    """  set_target_properties(hackrf PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR})
""",
    """  # Android APK packages the unversioned shared library.
""",
)
cmake.write_text(text)
PY

cmake \
  -S hackrf/host/libhackrf \
  -B hackrf-build \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SOAPY_PREFIX" \
  -DENABLE_SHARED_LIB=ON \
  -DENABLE_STATIC_LIB=OFF \
  -DINSTALL_UDEV_RULES=OFF \
  -DLIBUSB_INCLUDE_DIR="$DEPS/libusb/libusb" \
  -DLIBUSB_LIBRARIES="$LIBUSB_SO"
cmake --build hackrf-build --parallel 2
cmake --install hackrf-build

HACKRF_SO="$(find "$SOAPY_PREFIX" -name 'libhackrf.so' -type f | head -n 1)"
test -f "$HACKRF_SO"

git clone --depth 1 https://github.com/pothosware/SoapyHackRF.git soapy-hackrf

python3 - <<'PY'
from pathlib import Path

p = Path("soapy-hackrf/HackRF_Settings.cpp")
text = p.read_text()

old = """	if (args.count("serial") == 0)
		throw std::runtime_error("no hackrf device matches");
	_serial = args.at("serial");

	_current_amp = 0;

	_current_frequency = 0;

	_current_samplerate = 0;

	_current_bandwidth=0;

	int ret = hackrf_open_by_serial(_serial.c_str(), &_dev);
	if ( ret != HACKRF_SUCCESS )
	{
		SoapySDR_logf( SOAPY_SDR_INFO, "Could not Open HackRF Device" );
		throw std::runtime_error("hackrf open failed");
	}

	HackRF_getClaimedSerials().insert(_serial);
"""
new = """	const bool hasFd = args.count("fd") != 0;
	if (!hasFd && args.count("serial") == 0)
		throw std::runtime_error("no hackrf device matches");
	_serial = hasFd
		? (std::string("android-fd-") + args.at("fd"))
		: args.at("serial");

	_current_amp = 0;

	_current_frequency = 0;

	_current_samplerate = 0;

	_current_bandwidth=0;

	int ret = hasFd
		? hackrf_open_fd(std::stoi(args.at("fd")), &_dev)
		: hackrf_open_by_serial(_serial.c_str(), &_dev);
	if ( ret != HACKRF_SUCCESS )
	{
		SoapySDR_logf( SOAPY_SDR_INFO, "Could not Open HackRF Device" );
		throw std::runtime_error("hackrf open failed");
	}

	HackRF_getClaimedSerials().insert(_serial);
"""
if old not in text:
    raise SystemExit("SoapyHackRF constructor patch marker not found")
p.write_text(text.replace(old, new))
PY

cmake \
  -S soapy-hackrf \
  -B soapy-hackrf-build \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SOAPY_PREFIX" \
  -DSoapySDR_DIR="$SOAPY_PREFIX/share/cmake/SoapySDR" \
  -DLIBHACKRF_INCLUDE_DIR="$SOAPY_PREFIX/include/libhackrf" \
  -DLIBHACKRF_LIBRARY="$HACKRF_SO"
cmake --build soapy-hackrf-build --parallel 2
cmake --install soapy-hackrf-build

HACKRF_MODULE="$(find "$SOAPY_PREFIX" -name 'libHackRFSupport.so' -type f | head -n 1)"
test -f "$HACKRF_MODULE"

cp "$HACKRF_SO" "$JNI/libhackrf.so"
cp "$HACKRF_MODULE" "$JNI/libHackRFSupport.so"

file "$JNI/libhackrf.so" "$JNI/libHackRFSupport.so"
readelf -d "$JNI/libHackRFSupport.so" | grep NEEDED || true
