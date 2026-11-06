# Answers find_package(MbedTLS) inside the dependencies with the Mbed TLS
# built in this tree (native/CMakeLists.txt), instead of a system one.
set(MbedTLS_FOUND ON)
set(MbedTLS_VERSION 3.6.7)
set(MBEDTLS_INCLUDE_DIRS ${WEBRTC_FFI_MBEDTLS_INCLUDE})
set(MbedTLS_INCLUDE_DIR ${WEBRTC_FFI_MBEDTLS_INCLUDE})
set(MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto)
set(MbedTLS_LIBRARIES mbedtls mbedx509 mbedcrypto)
