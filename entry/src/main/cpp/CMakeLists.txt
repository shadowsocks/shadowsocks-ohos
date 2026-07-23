cmake_minimum_required(VERSION 3.16)
project(shadowsocks_harmony)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

# NAPI module exposed to ArkTS as `libsslocal.so`
add_library(sslocal SHARED napi_init.cpp)

# Rust core built by ../../../native/build-ohos.sh into entry/libs/<abi>/
set(SSLOCAL_CORE_LIB ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libsslocal_core.a)
if(NOT EXISTS ${SSLOCAL_CORE_LIB})
    message(FATAL_ERROR
        "libsslocal_core.a not found for ${OHOS_ARCH}. "
        "Run harmony/native/build-ohos.sh first.")
endif()

target_link_libraries(sslocal PUBLIC libace_napi.z.so ${SSLOCAL_CORE_LIB})
