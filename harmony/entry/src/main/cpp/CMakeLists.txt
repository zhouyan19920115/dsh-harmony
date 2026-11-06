# The native module of the phone side seal.
#
# `libseal.so` exposes the AES-256-GCM of the system crypto framework to the ArkTS side
# (`common/NativeSeal.ets`). The crypto core (`seal_core.c`) is plain C so that the very same
# code can be linked into the cross platform interop program (`test/seal_interop.c`).

cmake_minimum_required(VERSION 3.5.0)
project(seal)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(seal SHARED
    napi_init.cpp
    seal_core.c
)

target_include_directories(seal PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# The crypto framework headers live in the NDK sysroot; the toolchain already puts them on the
# include path, this is only a safety net for a build that does not use the OHOS toolchain file.
if (DEFINED OHOS_NDK_HOME AND EXISTS "${OHOS_NDK_HOME}/sysroot/usr/include")
    target_include_directories(seal PRIVATE "${OHOS_NDK_HOME}/sysroot/usr/include")
endif()

target_compile_options(seal PRIVATE
    -Wall
    -Wextra
    -fexceptions
)

# The napi runtime and the system crypto framework (`libohcrypto.so` carries the native
# CryptoArchitectureKit: the AES-256-GCM and the HKDF).
target_link_libraries(seal PUBLIC
    libace_napi.z.so
    libohcrypto.so
    libhilog_ndk.z.so
)
