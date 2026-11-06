// The small C layer between libdatachannel and Dart.
//
// libdatachannel calls back on its own threads. Every event is posted to the
// Dart port of the isolate that owns the connection (Dart_PostCObject), as
// [kind, id, a, text1, text2]: the VM copies the strings, and a port whose
// isolate has ended only makes the post fail. Message data is never posted:
// an "available" event tells Dart to pull the messages with
// rtcReceiveMessage.
//
// The functions taking libdatachannel's structs are wrapped here too, so the
// Dart side never depends on their layout.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dart/dart_api_dl.h"
#include "rtc/rtc.h"

#if defined(_WIN32)
#include <windows.h>
static SRWLOCK g_lock = SRWLOCK_INIT;
#define LOCK() AcquireSRWLockExclusive(&g_lock)
#define UNLOCK() ReleaseSRWLockExclusive(&g_lock)
#else
#include <pthread.h>
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&g_lock)
#define UNLOCK() pthread_mutex_unlock(&g_lock)
#endif

#if defined(_WIN32)
#define WEBRTC_FFI_EXPORT __declspec(dllexport)
#else
#define WEBRTC_FFI_EXPORT __attribute__((visibility("default")))
#endif

// Event kinds; keep in step with lib/src/native.dart.
enum {
	EV_LOCAL_DESCRIPTION = 1, // id=pc, text1=type, text2=sdp
	EV_LOCAL_CANDIDATE = 2,   // id=pc, text1=mid, text2=candidate
	EV_STATE = 3,             // id=pc, a=rtcState
	EV_ICE_STATE = 4,         // id=pc, a=rtcIceState
	EV_GATHERING_STATE = 5,   // id=pc, a=rtcGatheringState
	EV_SIGNALING_STATE = 6,   // id=pc, a=rtcSignalingState
	EV_DATA_CHANNEL = 7,      // id=pc, a=dc (opened by the remote peer)
	EV_TRACK = 8,             // id=pc, a=tr (added by the remote description)
	EV_OPEN = 10,             // id=dc|tr
	EV_CLOSED = 11,           // id=dc|tr
	EV_ERROR = 12,            // id=dc|tr, text1=error
	EV_AVAILABLE = 13,        // id=dc|tr: messages wait for rtcReceiveMessage
	EV_BUFFERED_LOW = 14,     // id=dc|tr
	EV_PLI = 15,              // id=tr: the remote peer asked for a keyframe
	EV_REMB = 16,             // id=tr, a=bitrate the remote peer estimates
	EV_LOG = 20,              // id=0, a=rtcLogLevel, text1=message
};

// --- ports ---
// libdatachannel's user pointer of each object is an index (+1) into this
// table of Dart ports, one per isolate that made a connection. Entries are
// only appended (under the lock, from isolates), so callbacks read unlocked.
#define MAX_PORTS 1024
static Dart_Port g_ports[MAX_PORTS];
static volatile int g_port_count = 0;
static volatile Dart_Port g_log_port = ILLEGAL_PORT;

static void *port_ref(Dart_Port port) {
	void *ref = NULL;
	LOCK();
	for (int i = 0; i < g_port_count && !ref; i++)
		if (g_ports[i] == port)
			ref = (void *)(intptr_t)(i + 1);
	if (!ref && g_port_count < MAX_PORTS) {
		g_ports[g_port_count] = port;
		g_port_count++;
		ref = (void *)(intptr_t)g_port_count;
	}
	UNLOCK();
	return ref;
}

static Dart_Port port_of(void *ref) {
	intptr_t i = (intptr_t)ref;
	return (i > 0 && i <= g_port_count) ? g_ports[i - 1] : ILLEGAL_PORT;
}

static void post(Dart_Port port, int kind, int id, int64_t a, const char *t1, const char *t2) {
	if (port == ILLEGAL_PORT || Dart_PostCObject_DL == NULL)
		return;
	Dart_CObject v[5];
	Dart_CObject *items[5] = {&v[0], &v[1], &v[2], &v[3], &v[4]};
	v[0].type = Dart_CObject_kInt32;
	v[0].value.as_int32 = kind;
	v[1].type = Dart_CObject_kInt32;
	v[1].value.as_int32 = id;
	v[2].type = Dart_CObject_kInt64;
	v[2].value.as_int64 = a;
	const char *t[2] = {t1, t2};
	for (int i = 0; i < 2; i++) {
		if (t[i]) {
			v[3 + i].type = Dart_CObject_kString;
			v[3 + i].value.as_string = (char *)t[i];
		} else {
			v[3 + i].type = Dart_CObject_kNull;
		}
	}
	Dart_CObject msg;
	msg.type = Dart_CObject_kArray;
	msg.value.as_array.length = 5;
	msg.value.as_array.values = items;
	Dart_PostCObject_DL(port, &msg);
}

#define EMIT(ptr, kind, id, a, t1, t2) post(port_of(ptr), kind, id, a, t1, t2)

// --- callbacks ---

static void RTC_API on_description(int pc, const char *sdp, const char *type, void *p) {
	EMIT(p, EV_LOCAL_DESCRIPTION, pc, 0, type, sdp);
}
static void RTC_API on_candidate(int pc, const char *cand, const char *mid, void *p) {
	EMIT(p, EV_LOCAL_CANDIDATE, pc, 0, mid, cand);
}
static void RTC_API on_state(int pc, rtcState s, void *p) { EMIT(p, EV_STATE, pc, s, NULL, NULL); }
static void RTC_API on_ice_state(int pc, rtcIceState s, void *p) {
	EMIT(p, EV_ICE_STATE, pc, s, NULL, NULL);
}
static void RTC_API on_gathering_state(int pc, rtcGatheringState s, void *p) {
	EMIT(p, EV_GATHERING_STATE, pc, s, NULL, NULL);
}
static void RTC_API on_signaling_state(int pc, rtcSignalingState s, void *p) {
	EMIT(p, EV_SIGNALING_STATE, pc, s, NULL, NULL);
}
static void RTC_API on_open(int id, void *p) { EMIT(p, EV_OPEN, id, 0, NULL, NULL); }
static void RTC_API on_closed(int id, void *p) { EMIT(p, EV_CLOSED, id, 0, NULL, NULL); }
static void RTC_API on_error(int id, const char *error, void *p) {
	EMIT(p, EV_ERROR, id, 0, error ? error : "", NULL);
}
static void RTC_API on_available(int id, void *p) { EMIT(p, EV_AVAILABLE, id, 0, NULL, NULL); }
static void RTC_API on_buffered_low(int id, void *p) { EMIT(p, EV_BUFFERED_LOW, id, 0, NULL, NULL); }
static void RTC_API on_pli(int tr, void *p) { EMIT(p, EV_PLI, tr, 0, NULL, NULL); }
static void RTC_API on_remb(int tr, unsigned int bitrate, void *p) {
	EMIT(p, EV_REMB, tr, bitrate, NULL, NULL);
}
static void RTC_API on_log(rtcLogLevel level, const char *message) {
	post(g_log_port, EV_LOG, 0, level, message, NULL);
}

static int attach_channel(int id, void *ref) {
	int r;
	rtcSetUserPointer(id, ref);
	if ((r = rtcSetOpenCallback(id, on_open)) < 0)
		return r;
	if ((r = rtcSetClosedCallback(id, on_closed)) < 0)
		return r;
	if ((r = rtcSetErrorCallback(id, on_error)) < 0)
		return r;
	if ((r = rtcSetBufferedAmountLowCallback(id, on_buffered_low)) < 0)
		return r;
	return rtcSetAvailableCallback(id, on_available);
}

// Channels and tracks the remote peer creates get their callbacks (and the
// connection's port) before Dart hears of them, so no event is lost.
static void RTC_API on_data_channel(int pc, int dc, void *p) {
	attach_channel(dc, p);
	EMIT(p, EV_DATA_CHANNEL, pc, dc, NULL, NULL);
}
static void RTC_API on_track(int pc, int tr, void *p) {
	attach_channel(tr, p);
	EMIT(p, EV_TRACK, pc, tr, NULL, NULL);
}

// --- API ---

// Dart_InitializeApiDL with NativeApi.initializeApiDLData; 0 on success.
WEBRTC_FFI_EXPORT intptr_t webrtc_ffi_init(void *data) { return Dart_InitializeApiDL(data); }

// rtcInitLogger, with messages posted to [port]. libdatachannel takes the
// level from the first call only; later calls just move the messages.
WEBRTC_FFI_EXPORT void webrtc_ffi_init_logger(int level, Dart_Port port) {
	g_log_port = port;
	rtcInitLogger((rtcLogLevel)level, on_log);
}

// rtcCreatePeerConnection with every callback posting to [port].
// flags: 1 relay only, 2 enable ICE-TCP, 4 disable auto negotiation,
// 8 force media transport, 16 RSA certificate.
WEBRTC_FFI_EXPORT int webrtc_ffi_create_peer_connection(Dart_Port port, const char **ice_servers,
                                                         int count, const char *bind_address,
                                                         int port_begin, int port_end, int mtu,
                                                         int max_message_size, int flags) {
	void *ref = port_ref(port);
	if (!ref)
		return RTC_ERR_FAILURE;
	rtcConfiguration c;
	memset(&c, 0, sizeof(c));
	c.iceServers = ice_servers;
	c.iceServersCount = count;
	c.bindAddress = bind_address;
	c.iceTransportPolicy = (flags & 1) ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL;
	c.enableIceTcp = (flags & 2) != 0;
	c.disableAutoNegotiation = (flags & 4) != 0;
	c.forceMediaTransport = (flags & 8) != 0;
	c.certificateType = (flags & 16) ? RTC_CERTIFICATE_RSA : RTC_CERTIFICATE_DEFAULT;
	c.portRangeBegin = (uint16_t)port_begin;
	c.portRangeEnd = (uint16_t)port_end;
	c.mtu = mtu;
	c.maxMessageSize = max_message_size;
	int pc = rtcCreatePeerConnection(&c);
	if (pc < 0)
		return pc;
	rtcSetUserPointer(pc, ref);
	rtcSetLocalDescriptionCallback(pc, on_description);
	rtcSetLocalCandidateCallback(pc, on_candidate);
	rtcSetStateChangeCallback(pc, on_state);
	rtcSetIceStateChangeCallback(pc, on_ice_state);
	rtcSetGatheringStateChangeCallback(pc, on_gathering_state);
	rtcSetSignalingStateChangeCallback(pc, on_signaling_state);
	rtcSetDataChannelCallback(pc, on_data_channel);
	rtcSetTrackCallback(pc, on_track);
	return pc;
}

// rtcCreateDataChannelEx. max_retransmits / max_packet_life_time < 0 mean
// unset; setting either makes the channel unreliable. stream < 0 lets the
// library choose.
WEBRTC_FFI_EXPORT int webrtc_ffi_create_data_channel(Dart_Port port, int pc, const char *label,
                                                      const char *protocol, int unordered,
                                                      int max_retransmits, int max_packet_life_time,
                                                      int negotiated, int stream) {
	rtcDataChannelInit init;
	memset(&init, 0, sizeof(init));
	init.reliability.unordered = unordered != 0;
	if (max_retransmits >= 0) {
		init.reliability.unreliable = true;
		init.reliability.maxRetransmits = (unsigned int)max_retransmits;
	} else if (max_packet_life_time >= 0) {
		init.reliability.unreliable = true;
		init.reliability.maxPacketLifeTime = (unsigned int)max_packet_life_time;
	}
	init.protocol = protocol;
	init.negotiated = negotiated != 0;
	if (stream >= 0) {
		init.manualStream = true;
		init.stream = (uint16_t)stream;
	}
	int dc = rtcCreateDataChannelEx(pc, label, &init);
	if (dc >= 0)
		attach_channel(dc, port_ref(port));
	return dc;
}

// rtcAddTrackEx.
WEBRTC_FFI_EXPORT int webrtc_ffi_add_track(Dart_Port port, int pc, int direction, int codec,
                                            int payload_type, uint32_t ssrc, const char *mid,
                                            const char *name, const char *msid,
                                            const char *track_id, const char *profile) {
	rtcTrackInit init;
	memset(&init, 0, sizeof(init));
	init.direction = (rtcDirection)direction;
	init.codec = (rtcCodec)codec;
	init.payloadType = payload_type;
	init.ssrc = ssrc;
	init.mid = mid;
	// Without a name libdatachannel writes "a=ssrc:<n>" alone, which
	// libwebrtc rejects; it is the CNAME.
	init.name = (name || !ssrc) ? name : "webrtc_ffi";
	init.msid = msid;
	init.trackId = track_id;
	init.profile = profile;
	int tr = rtcAddTrackEx(pc, &init);
	if (tr >= 0)
		attach_channel(tr, port_ref(port));
	return tr;
}

// rtcAddTrack with a whole media description (an m= section).
WEBRTC_FFI_EXPORT int webrtc_ffi_add_track_sdp(Dart_Port port, int pc, const char *media_description) {
	int tr = rtcAddTrack(pc, media_description);
	if (tr >= 0)
		attach_channel(tr, port_ref(port));
	return tr;
}

// One of the rtcSet*Packetizer, by codec (rtcCodec). Frames sent on the track
// afterwards are split into RTP packets. nal_separator / obu_packetization
// only matter for H264/H265 and AV1.
WEBRTC_FFI_EXPORT int webrtc_ffi_set_packetizer(int tr, int codec, uint32_t ssrc, const char *cname,
                                                 int payload_type, uint32_t clock_rate,
                                                 int max_fragment_size, int nal_separator,
                                                 int obu_packetization, uint32_t sequence_number,
                                                 uint32_t timestamp) {
	rtcPacketizerInit init;
	memset(&init, 0, sizeof(init));
	init.ssrc = ssrc;
	init.cname = cname;
	init.payloadType = (uint8_t)payload_type;
	init.clockRate = clock_rate;
	init.sequenceNumber = (uint16_t)sequence_number;
	init.timestamp = timestamp;
	init.maxFragmentSize = (uint16_t)max_fragment_size;
	init.nalSeparator = (rtcNalUnitSeparator)nal_separator;
	init.obuPacketization = (rtcObuPacketization)obu_packetization;
	switch (codec) {
	case RTC_CODEC_H264:
		return rtcSetH264Packetizer(tr, &init);
	case RTC_CODEC_H265:
		return rtcSetH265Packetizer(tr, &init);
	case RTC_CODEC_AV1:
		return rtcSetAV1Packetizer(tr, &init);
	case RTC_CODEC_OPUS:
		return rtcSetOpusPacketizer(tr, &init);
	case RTC_CODEC_PCMU:
		return rtcSetPCMUPacketizer(tr, &init);
	case RTC_CODEC_PCMA:
		return rtcSetPCMAPacketizer(tr, &init);
	case RTC_CODEC_AAC:
		return rtcSetAACPacketizer(tr, &init);
	case RTC_CODEC_G722:
		return rtcSetG722Packetizer(tr, &init);
	default:
		return RTC_ERR_INVALID;
	}
}

WEBRTC_FFI_EXPORT int webrtc_ffi_chain_pli_handler(int tr) { return rtcChainPliHandler(tr, on_pli); }
WEBRTC_FFI_EXPORT int webrtc_ffi_chain_remb_handler(int tr) { return rtcChainRembHandler(tr, on_remb); }
