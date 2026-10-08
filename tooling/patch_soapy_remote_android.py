#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_soapy_remote_android.py <SoapyRemote source dir>")

root = Path(sys.argv[1]).resolve()

cmake = root / "CMakeLists.txt"
text = cmake.read_text(encoding="utf-8")
text = text.replace("add_subdirectory(server)", "# mobile client only")
text = text.replace(
    'if(CMAKE_SYSTEM_NAME STREQUAL "Linux")\n    add_subdirectory(system)\nendif()',
    '# mobile client: no system service',
)
cmake.write_text(text, encoding="utf-8")

info = root / "common" / "SoapyInfoUtils.in.cpp"
text = info.read_text(encoding="utf-8")
marker = "#endif //_MSC_VER\n"
android = """
#ifndef _MSC_VER
#ifdef __ANDROID__
static unsigned int gethostid(void)
{
    char host[128] = {0};
    if (gethostname(host, sizeof(host) - 1) != 0)
    {
        return 0x534F4150u;
    }

    unsigned int hash = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)host; *p; ++p)
    {
        hash ^= *p;
        hash *= 16777619u;
    }
    return hash;
}
#endif
#endif
"""
if "static unsigned int gethostid(void)" not in text:
    if marker not in text:
        raise SystemExit("SoapyRemote gethostid insertion marker not found")
    text = text.replace(marker, marker + android)
info.write_text(text, encoding="utf-8")

if "static unsigned int gethostid(void)" not in info.read_text(encoding="utf-8"):
    raise SystemExit("Android gethostid compatibility patch was not applied")

print("Patched SoapyRemote for Android client-only build")
