# Third-party notices

The package ships these sources, unmodified, and builds them into its native library. `third_party/` comes from
`tool/vendor.sh`, which removes tests, examples and documentation. `native/dart/` is copied from the Dart SDK. Each
component keeps its own license; the full texts are at the locations below.

| Component | Version | License | Location |
|---|---|---|---|
| [libdatachannel](https://github.com/paullouisageneau/libdatachannel) | v0.24.6 | MPL-2.0 | `third_party/libdatachannel/LICENSE` |
| [libjuice](https://github.com/paullouisageneau/libjuice) (ICE) | as pinned by libdatachannel | MPL-2.0 | `third_party/libdatachannel/deps/libjuice/LICENSE` |
| [usrsctp](https://github.com/sctplab/usrsctp) (SCTP) | as pinned by libdatachannel | BSD-3-Clause | `third_party/libdatachannel/deps/usrsctp/LICENSE.md` |
| [libsrtp](https://github.com/cisco/libsrtp) (SRTP) | as pinned by libdatachannel | BSD-3-Clause | `third_party/libdatachannel/deps/libsrtp/LICENSE` |
| [plog](https://github.com/SergiusTheBest/plog) (logging) | as pinned by libdatachannel | MIT | `third_party/libdatachannel/deps/plog/LICENSE` |
| [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (DTLS) | v3.6.7 | Apache-2.0 OR GPL-2.0-or-later (used under Apache-2.0) | `third_party/mbedtls/LICENSE` |
| Dart SDK `dart_api_dl` | 3.13.2 | BSD-3-Clause | `native/dart/LICENSE` |

`third_party/VERSIONS.txt` lists the exact commits of the submodules.

MPL-2.0 is a file-level copyleft: the source of those files, including any changes to them, must stay available. This
package ships them as source and does not change them.
