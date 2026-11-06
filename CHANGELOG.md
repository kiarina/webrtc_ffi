## 0.1.0-dev

- Peer connections with trickle ICE, STUN/TURN, and auto or manual negotiation.
- Data channels: text and binary, ordered or unordered, reliable or partially reliable, negotiated, back-pressure.
- Media tracks: packetizers (H.264, H.265, AV1, Opus, PCMU, PCMA, AAC, G.722), RTCP sender and receiver reports, NACK,
  PLI and REMB; RTP parsing, and H.264 and audio depacketizers.
- Native: libdatachannel v0.24.6 with media, libsrtp, usrsctp, libjuice and Mbed TLS v3.6.7, built from source by the
  build hook on macOS, Linux and Windows.
