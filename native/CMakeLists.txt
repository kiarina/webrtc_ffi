# One shared library, webrtc_ffi: libdatachannel (with media), libsrtp,
# usrsctp, libjuice and Mbed TLS, plus the shim (shim.c).
#
# Configured by hook/build.dart. By hand:
#   cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/native --config Release --target webrtc_ffi
cmake_minimum_required(VERSION 3.21) # libsrtp needs 3.21
project(webrtc_ffi_native C CXX)

set(THIRD_PARTY ${CMAKE_CURRENT_LIST_DIR}/../third_party)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5) # usrsctp/plog declare old minimums
if(MSVC)
  # One C runtime for every part, linked statically: nothing to install.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Mbed TLS is static and ends up inside the one library.
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_SKIP_INSTALL_RULES ON) # nothing here is installed

# --- Mbed TLS ---
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(MBEDTLS_USER_CONFIG ${CMAKE_CURRENT_LIST_DIR}/mbedtls_user_config.h)
add_compile_definitions(MBEDTLS_USER_CONFIG_FILE="${MBEDTLS_USER_CONFIG}")
add_subdirectory(${THIRD_PARTY}/mbedtls mbedtls EXCLUDE_FROM_ALL)

# libdatachannel uses MbedTLS::MbedTLS when it exists; libsrtp calls
# find_package(MbedTLS), answered by native/cmake/MbedTLSConfig.cmake.
add_library(MbedTLS::MbedTLS INTERFACE IMPORTED GLOBAL)
target_link_libraries(MbedTLS::MbedTLS INTERFACE mbedtls mbedx509 mbedcrypto)
set(WEBRTC_FFI_MBEDTLS_INCLUDE ${THIRD_PARTY}/mbedtls/include)
set(CMAKE_FIND_PACKAGE_PREFER_CONFIG ON)
set(MbedTLS_DIR ${CMAKE_CURRENT_LIST_DIR}/cmake CACHE PATH "" FORCE)

# --- libdatachannel ---
set(USE_MBEDTLS ON CACHE BOOL "" FORCE)
set(NO_MEDIA OFF CACHE BOOL "" FORCE)
set(NO_WEBSOCKET ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(LIBSRTP_TEST_APPS OFF CACHE BOOL "" FORCE)
# Shared datachannel; libdatachannel builds its own deps static
# (BUILD_SHARED_DEPS_LIBS stays off).
set(BUILD_SHARED_LIBS ON)
add_subdirectory(${THIRD_PARTY}/libdatachannel libdatachannel EXCLUDE_FROM_ALL)

# --- the library Dart loads ---
# libdatachannel's own shared library, with the shim added and renamed so it
# cannot collide with another package that bundles a libdatachannel.
target_sources(datachannel PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/shim.c
  ${CMAKE_CURRENT_LIST_DIR}/dart/dart_api_dl.c) # Dart_PostCObject, from the Dart SDK
target_include_directories(datachannel PRIVATE ${CMAKE_CURRENT_LIST_DIR})
set_target_properties(datachannel PROPERTIES OUTPUT_NAME webrtc_ffi)
# One unversioned file: bundlers copy files, not version symlinks.
set_property(TARGET datachannel PROPERTY VERSION)
set_property(TARGET datachannel PROPERTY SOVERSION)
# Export only the C API: Mbed TLS, libsrtp, usrsctp and libjuice stay
# private, so they cannot clash with another copy in the same process.
if(APPLE)
  target_link_options(datachannel PRIVATE
    "LINKER:-exported_symbols_list,${CMAKE_CURRENT_LIST_DIR}/exports.txt")
elseif(UNIX)
  target_link_options(datachannel PRIVATE "LINKER:--exclude-libs,ALL")
endif()

# What the hook builds. A top-level target: the Visual Studio generator only
# finds --target projects in this directory.
add_custom_target(webrtc_ffi ALL DEPENDS datachannel)
