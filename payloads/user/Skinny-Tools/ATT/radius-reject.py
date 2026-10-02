#!/usr/bin/env python3
"""
Tiny RADIUS server for the ATT-Hotspot2-Tracker v25.3 payload.

Listens on UDP/1812 and answers every Access-Request with a configurable
reply. Default mode is Access-Reject, which is the iPhone-retry
behavior we want for the "continuous RSSI stream" test path described
in PASSPOINT_BEHAVIOR_DEEP_DIVE.md §3b.2 and §6.

This is a stdlib-only implementation. We don't depend on `pyrad`
because that package is not on the Pager and we want the smallest
possible footprint.

RFC 2865 packet layout:
  +-----------+---------------+---------------+--------------+
  |  Code (1) | Identifier(1) |   Length (2)  |              |
  +-----------+---------------+---------------+              |
  |                                                               |
  |                     Authenticator (16)                        |
  |                                                               |
  |                                                               |
  +---------------------------------------------------------------+
  |  Attributes ...                                               |
  +---------------------------------------------------------------+

  Attribute TLV:
  +-----------+---------------+---------------+
  |  Type (1) |   Length (1)  |     Value     |
  +-----------+---------------+---------------+

Response Authenticator:
  ResponseAuth = MD5(Code || Identifier || Length ||
                     RequestAuthenticator || Attributes || Secret)

Usage:
  radius-reject.py [--bind HOST] [--port PORT] [--secret S]
                   [--mode {reject,accept,log-only,sweep}]
                   [--sweep-interval N]
                   [--log FILE] [--quiet] [--debug]

Modes:
  reject              Access-Reject (Code 3)  [default]
  accept              Access-Accept (Code 2)
  log-only            no reply packet; just print the decoded request
  sweep               alternate reject/accept every --sweep-interval
                      requests (5 by default) for A/B comparison

Debug:
  --debug         hex-dump every received packet; full attribute
                  table; full EAP decode; reply packet construction
                  trace. Highly recommended when you want to watch
                  the hostapd <-> RADIUS exchange live.

Notes:
  - Designed to be launched by ATT/payload.sh as a background child
    and killed on payload shutdown.
  - The 16-byte request authenticator is verified for length only;
    we do not validate it against a known client secret (we are the
    only client, on 127.0.0.1, talking to ourselves).
  - Listens on 127.0.0.1 by default so it cannot be reached from
    the WLAN. Override with --bind 0.0.0.0 for an interface test.
"""

import argparse
import hashlib
import os
import signal
import socket
import struct
import sys
import threading
import time

# ---- RADIUS codes (RFC 2865) ----------------------------------------------

CODE_ACCESS_REQUEST  = 1
CODE_ACCESS_ACCEPT   = 2
CODE_ACCESS_REJECT   = 3
CODE_ACCESS_CHALLENGE = 11
CODE_ACCOUNTING_REQUEST = 4
CODE_ACCOUNTING_RESPONSE = 5
CODE_DISCONNECT_REQUEST = 40
CODE_DISCONNECT_ACK     = 41
CODE_DISCONNECT_NAK     = 42
CODE_COA_REQUEST        = 43
CODE_COA_ACK            = 44
CODE_COA_NAK            = 45

CODE_NAMES = {
    1:  "Access-Request",
    2:  "Access-Accept",
    3:  "Access-Reject",
    4:  "Accounting-Request",
    5:  "Accounting-Response",
    11: "Access-Challenge",
    40: "Disconnect-Request",
    41: "Disconnect-ACK",
    42: "Disconnect-NAK",
    43: "CoA-Request",
    44: "CoA-ACK",
    45: "CoA-NAK",
}

# ---- attribute types we care about for logging ----------------------------

ATTR_USER_NAME              = 1
ATTR_USER_PASSWORD          = 2
ATTR_CHAP_PASSWORD          = 3
ATTR_NAS_IP_ADDRESS         = 4
ATTR_NAS_PORT               = 5
ATTR_NAS_PORT_TYPE          = 61
ATTR_CONNECT_INFO           = 77
ATTR_EAP_MESSAGE            = 79
ATTR_MESSAGE_AUTHENTICATOR  = 80
ATTR_REPLY_MESSAGE          = 18
ATTR_STATE                  = 24
ATTR_CLASS                  = 25
ATTR_SESSION_TIMEOUT        = 27
ATTR_CALLING_STATION_ID     = 31
ATTR_CALLED_STATION_ID      = 30
ATTR_ACCT_SESSION_ID        = 44
ATTR_VENDOR_SPECIFIC        = 26
ATTR_NAS_IDENTIFIER         = 32
ATTR_EAP_SESSION_KEY        = 16   # MSK, RFC 2548 / 3579

ATTR_NAMES = {
    1:  "User-Name",
    2:  "User-Password",
    3:  "CHAP-Password",
    4:  "NAS-IP-Address",
    5:  "NAS-Port",
    6:  "Service-Type",
    7:  "Framed-Protocol",
    8:  "Framed-IP-Address",
    18: "Reply-Message",
    24: "State",
    25: "Class",
    26: "Vendor-Specific",
    27: "Session-Timeout",
    30: "Called-Station-Id",
    31: "Calling-Station-Id",
    32: "NAS-Identifier",
    44: "Acct-Session-Id",
    61: "NAS-Port-Type",
    77: "Connect-Info",
    79: "EAP-Message",
    80: "Message-Authenticator",
}

NAS_PORT_TYPE_NAMES = {
    0:  "Async",
    1:  "Sync",
    2:  "ISDN",
    3:  "ISDN-Async",
    4:  "ISDN-Sync",
    5:  "Digital",
    6:  "Digital-Async",
    7:  "Digital-Sync",
    15: "Ethernet",
    16: "Cable",
    17: "Wireless-Other",
    18: "Wireless-IEEE-802.11",
    19: "Token-Ring",
}

# ---- EAP codes and types (RFC 3748) --------------------------------------

EAP_CODE_REQUEST  = 1
EAP_CODE_RESPONSE = 2
EAP_CODE_SUCCESS  = 3
EAP_CODE_FAILURE  = 4

EAP_TYPE_IDENTITY      = 1
EAP_TYPE_NOTIFICATION  = 2
EAP_TYPE_NAK           = 3
EAP_TYPE_MD5           = 4
EAP_TYPE_TLS           = 13
EAP_TYPE_SIM           = 18
EAP_TYPE_TTLS          = 21
EAP_TYPE_AKA           = 23
EAP_TYPE_PEAP          = 25
EAP_TYPE_FAST          = 43
EAP_TYPE_AKA_PRIME     = 50

EAP_TYPE_NAMES = {
    1:  "Identity",
    2:  "Notification",
    3:  "Nak",
    4:  "MD5-Challenge",
    13: "TLS",
    18: "SIM",
    21: "TTLS",
    23: "AKA",
    25: "PEAP",
    43: "FAST",
    50: "AKA'",
}

EAP_CODE_NAMES = {
    1: "Request", 2: "Response", 3: "Success", 4: "Failure",
}

# ---- EAP-AKA / AKA' sub-attributes (RFC 4187 / RFC 5448) -----------------
# These are wrapped inside the EAP-Message attribute as AT_xxx TLVs.

AKA_AT_RES               = 1
AKA_AT_AUTS              = 2
AKA_AT_RAND              = 3
AKA_AT_AUTN              = 4
AKA_AT_NEXT_REAUTH_ID    = 5
AKA_AT_CHECKCODE         = 6
AKA_AT_IV                = 7
AKA_AT_ENCR_DATA         = 8
AKA_AT_PADDING           = 9
AKA_AT_VERSION_LIST      = 10
AKA_AT_SELECTED_VERSION  = 11
AKA_AT_FULLAUTH_ID_REQ   = 12
AKA_AT_PERMANENT_ID_REQ  = 13
AKA_AT_MAC               = 14
AKA_AT_COUNTER           = 15
AKA_AT_COUNTER_TOO_SMALL = 16
AKA_AT_NONCE_S           = 17
AKA_AT_SESSION_ID        = 18
AKA_AT_TAG               = 19
AKA_AT_CLIENT_ERROR_CODE = 20
AKA_AT_KDF_INPUT         = 23
AKA_AT_KDF               = 24

AKA_AT_NAMES = {
    1:  "AT_RES",
    2:  "AT_AUTS",
    3:  "AT_RAND",
    4:  "AT_AUTN",
    5:  "AT_NEXT_REAUTH_ID",
    6:  "AT_CHECKCODE",
    7:  "AT_IV",
    8:  "AT_ENCR_DATA",
    9:  "AT_PADDING",
    10: "AT_VERSION_LIST",
    11: "AT_SELECTED_VERSION",
    12: "AT_FULLAUTH_ID_REQ",
    13: "AT_PERMANENT_ID_REQ",
    14: "AT_MAC",
    15: "AT_COUNTER",
    16: "AT_COUNTER_TOO_SMALL",
    17: "AT_NONCE_S",
    18: "AT_SESSION_ID",
    19: "AT_TAG",
    20: "AT_CLIENT_ERROR_CODE",
    23: "AT_KDF_INPUT",
    24: "AT_KDF",
}

# ---- global state --------------------------------------------------------

_running = True
_total_requests = 0
_total_replies   = 0
_total_bytes_rx  = 0
_total_bytes_tx  = 0
_sweep_count     = [0]   # list for mutability in nested scopes
_start_ts = time.time()
_log_fp = None
_log_lock = threading.Lock()
_debug = False


def _ts():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _log(line):
    """Mirror to stdout and to --log file (if set). Thread-safe."""
    with _log_lock:
        print(line, flush=True)
        if _log_fp is not None:
            _log_fp.write(line + "\n")
            _log_fp.flush()


def _dbg(line):
    if _debug:
        _log(line)


def _hexdump(data, width=16):
    """Multi-line hex+ASCII dump. Used by --debug."""
    out = []
    for i in range(0, len(data), width):
        chunk = data[i:i+width]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        asci = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        out.append(f"        {i:04x}  {hexs:<{width*3}}  {asci}")
    return "\n".join(out)


# ---- packet parser --------------------------------------------------------

def parse_radius_packet(data):
    """Parse a RADIUS UDP datagram. Returns dict or raises ValueError."""
    if len(data) < 20:
        raise ValueError(f"packet too short: {len(data)} bytes")
    code, ident, length, authenticator = struct.unpack("!BBH16s", data[:20])
    if length != len(data):
        raise ValueError(
            f"length field {length} != actual {len(data)}"
        )
    attrs = []
    i = 20
    while i < length:
        if i + 2 > length:
            raise ValueError(f"truncated attribute header at {i}")
        atype, alen = struct.unpack("!BB", data[i:i+2])
        if alen < 2 or i + alen > length:
            raise ValueError(f"bad attribute length {alen} at {i}")
        avalue = data[i+2:i+alen]
        attrs.append((atype, alen, avalue))
        i += alen
    return {
        "code": code,
        "ident": ident,
        "length": length,
        "authenticator": authenticator,
        "attributes": attrs,
    }


# ---- attribute decoders ---------------------------------------------------

def decode_attr(atype, value):
    """Return a human-readable string for an attribute value."""
    name = ATTR_NAMES.get(atype, f"Type={atype}")
    try:
        if atype == ATTR_USER_NAME:
            return f"\"{value.decode('utf-8','replace')}\""
        if atype == ATTR_USER_PASSWORD:
            return f"<encrypted, {len(value)} bytes>"
        if atype == ATTR_NAS_IP_ADDRESS and len(value) == 4:
            return socket.inet_ntoa(value)
        if atype == ATTR_NAS_PORT and len(value) == 4:
            return str(struct.unpack("!I", value)[0])
        if atype == ATTR_NAS_PORT_TYPE and len(value) == 4:
            return f"{struct.unpack('!I', value)[0]} ({NAS_PORT_TYPE_NAMES.get(struct.unpack('!I', value)[0], '?')})"
        if atype == ATTR_CALLING_STATION_ID:
            return f"\"{value.decode('utf-8','replace')}\" (MAC of supplicant)"
        if atype == ATTR_CALLED_STATION_ID:
            return f"\"{value.decode('utf-8','replace')}\" (BSSID-SSID of AP)"
        if atype == ATTR_NAS_IDENTIFIER:
            return f"\"{value.decode('utf-8','replace')}\""
        if atype == ATTR_REPLY_MESSAGE:
            return f"\"{value.decode('utf-8','replace')}\""
        if atype == ATTR_STATE:
            return f"<{len(value)} bytes> hex={value.hex()}"
        if atype == ATTR_EAP_MESSAGE:
            return decode_eap(value)
        if atype == ATTR_MESSAGE_AUTHENTICATOR:
            return f"<{len(value)} bytes> hex={value.hex()}"
        if atype == ATTR_VENDOR_SPECIFIC and len(value) >= 4:
            vendor_id = struct.unpack("!I", value[:4])[0]
            return f"vendor_id=0x{vendor_id:08x} data={value[4:].hex()}"
        if atype == ATTR_SESSION_TIMEOUT and len(value) == 4:
            return f"{struct.unpack('!I', value)[0]}s"
        if atype == ATTR_CHAP_PASSWORD:
            return f"chap-id={value[0]} chap-response={value[1:].hex()}"
    except Exception as e:
        return f"<decode error: {e}>"
    return value.hex()


def decode_eap(data):
    """Decode an EAP-Message attribute value into the EAP header + payload."""
    if len(data) < 4:
        return f"<short EAP, {len(data)} bytes> hex={data.hex()}"
    code = data[0]
    ident = data[1]
    length = struct.unpack("!H", data[2:4])[0]
    type_ = data[4] if len(data) > 4 else None
    code_name = EAP_CODE_NAMES.get(code, f"?{code}")
    base = f"code={code_name} ident={ident} length={length}"

    if code in (EAP_CODE_SUCCESS, EAP_CODE_FAILURE):
        return f"EAP {code_name} ({base})"

    if type_ is None:
        return f"EAP ({base})"

    type_name = EAP_TYPE_NAMES.get(type_, f"?{type_}")
    base += f" type={type_name}({type_})"

    if type_ in (EAP_TYPE_AKA, EAP_TYPE_AKA_PRIME):
        sub = decode_aka_subattrs(data[5:length])
        if sub:
            return f"EAP {base}\n        " + sub
        return f"EAP {base}"
    if type_ == EAP_TYPE_SIM:
        return f"EAP {base} (sub-attrs in EAP-SIM format)"
    if type_ == EAP_TYPE_IDENTITY:
        ident_str = data[5:length].decode("utf-8", "replace")
        return f"EAP {base} identity=\"{ident_str}\""
    if type_ == EAP_TYPE_NAK:
        nak_list = ", ".join(
            EAP_TYPE_NAMES.get(b, f"?{b}")
            for b in data[5:length]
        )
        return f"EAP {base} preferred={nak_list}"
    return f"EAP {base} payload={data[5:length].hex()}"


def decode_aka_subattrs(data):
    """Decode AT_xxx sub-attributes from an EAP-AKA / AKA' payload.

    The data starts AFTER the EAP type byte, so the first byte is the
    AKA subtype (1=Challenge, 2=Auth-Reject, 4=Notification, etc.) and
    AT_xxx sub-attributes follow.
    """
    out = []
    if len(data) < 1:
        return ""
    subtype = data[0]
    subtype_names = {
        0: "reserved", 1: "AKA-Challenge", 2: "AKA-Authentication-Reject",
        3: "AKA-Synchronization-Failure", 4: "AKA-Notification",
        5: "AKA-Reauthentication", 6: "AKA-Client-Error",
        7: "AKA-Identity", 8: "AKA-Start",
    }
    out.append(f"subtype={subtype_names.get(subtype, f'?{subtype}')}({subtype})")
    i = 1
    while i + 1 < len(data):
        atype, alen = data[i], data[i+1]
        if alen < 2 or i + alen > len(data):
            out.append(f"  AT_?? truncated at offset {i}")
            break
        aval = data[i+2:i+alen]
        name = AKA_AT_NAMES.get(atype, f"AT_?{atype}")
        if atype in (AKA_AT_RES, AKA_AT_RAND, AKA_AT_AUTN):
            out.append(f"  {name}: {aval.hex()}")
        elif atype == AKA_AT_AUTS:
            out.append(f"  {name}: {aval.hex()}  (sync failure)")
        elif atype == AKA_AT_VERSION_LIST:
            # list of 16-bit version numbers
            vs = ", ".join(str(struct.unpack("!H", aval[j:j+2])[0])
                            for j in range(0, len(aval), 2))
            out.append(f"  {name}: versions={vs}")
        elif atype == AKA_AT_SELECTED_VERSION:
            if len(aval) >= 2:
                out.append(f"  {name}: version={struct.unpack('!H', aval[:2])[0]}")
        elif atype in (AKA_AT_FULLAUTH_ID_REQ, AKA_AT_PERMANENT_ID_REQ):
            out.append(f"  {name}: <request flag, {len(aval)} bytes>")
        elif atype == AKA_AT_CLIENT_ERROR_CODE:
            if len(aval) >= 1:
                out.append(f"  {name}: code={aval[0]}")
        elif atype == AKA_AT_COUNTER:
            if len(aval) >= 2:
                out.append(f"  {name}: counter={struct.unpack('!H', aval[:2])[0]}")
        elif atype == AKA_AT_MAC:
            out.append(f"  {name}: <MAC, {len(aval)} bytes>")
        else:
            out.append(f"  {name}: {aval.hex()}")
        i += alen
    return "\n        ".join(out)


def get_string(attrs, atype):
    """First matching string attribute (text/utf-8), stripped."""
    for t, _l, v in attrs:
        if t == atype:
            try:
                return v.decode("utf-8", "replace").strip("\x00").strip()
            except Exception:
                return ""
    return ""


# ---- reply builder --------------------------------------------------------

def build_reply(code, ident, req_authenticator, secret, extra_attrs=()):
    """Build a RADIUS reply packet. Returns bytes ready to send."""
    if code == CODE_ACCESS_ACCEPT:
        body = b""
        # Inject a deterministic fake MSK (64 bytes) so hostapd can
        # derive a PMK for the 4-way handshake. The iPhone cannot
        # derive the same PMK (it needs Ki), so MIC will fail — but
        # we will at least see hostapd attempt Msg1, which is the
        # whole point of the v27 EAP-Success experiment.
        import hashlib as _hl
        fake_msk = _hl.sha256(
            b"v27-fake-msk-" + req_authenticator
        ).digest() * 2   # 64 bytes
        body += struct.pack("!BB", ATTR_EAP_SESSION_KEY, 2 + 64) + fake_msk
    elif code == CODE_ACCESS_REJECT:
        # Reply-Message is OPTIONAL in RADIUS (RFC 2865 §5.18). Drop it
        # entirely to avoid length-mismatch bugs that make hostapd
        # reject our Access-Reject as "RADIUS: Parsing incoming frame
        # failed". The previous bug: declared len=2+14 (16) but shipped
        # only 12 bytes of value, so the packet's overall length was off
        # by 2 and hostapd dropped it — the iPhone would just time out
        # and retry instead of getting a clean EAP-Failure.
        body = b""
    else:
        body = b""

    # Append any extras
    for t, v in extra_attrs:
        if len(v) > 253:
            continue
        body += struct.pack("!BB", t, 2 + len(v)) + v

    length = 20 + len(body)
    header = struct.pack("!BBH", code, ident, length) + b"\x00" * 16
    resp_auth = hashlib.md5(
        header + req_authenticator + body + secret.encode("utf-8")
    ).digest()
    return header[:4] + resp_auth + body


def build_reply_with_ma(code, ident, req_authenticator, secret, extra_attrs=()):
    """Build a RADIUS reply with RFC 3579 Message-Authenticator attribute.

    hostapd-wolfssl REQUIRES Message-Authenticator on every reply to an
    Access-Request that contained one (RFC 3579 §3.2). Without it,
    hostapd logs "Incoming RADIUS packet did not have correct
    Message-Authenticator - dropped" and the iPhone never gets
    EAP-Failure. With it, the Access-Reject flows back through hostapd
    and the iPhone retries cleanly every 30-60s.

    Message-Authenticator = HMAC-MD5(secret, code || id || length ||
                                       req_auth || attrs_with_ma_filled)
    The MA attribute is included in attrs with 16 zero bytes; the HMAC
    is computed over the entire packet (including those zero bytes) and
    then patched into the MA attribute's value field.
    """
    import hmac as _hmac

    # 1. Build the body (without MA yet)
    if code == CODE_ACCESS_ACCEPT:
        body = b""
        fake_msk = hashlib.sha256(
            b"v27-fake-msk-" + req_authenticator
        ).digest() * 2
        body += struct.pack("!BB", ATTR_EAP_SESSION_KEY, 2 + 64) + fake_msk
    else:
        body = b""
    for t, v in extra_attrs:
        if len(v) > 253:
            continue
        body += struct.pack("!BB", t, 2 + len(v)) + v

    # 2. Append Message-Authenticator placeholder (16 zero bytes)
    body += struct.pack("!BB", ATTR_MESSAGE_AUTHENTICATOR, 2 + 16) + b"\x00" * 16

    # 3. Build header (placeholder authenticator) and compute HMAC over
    # code||ident||length||req_auth||attrs (with MA zero). RFC 3579 §3.2:
    # the HMAC input is the 4-byte RADIUS header + request authenticator +
    # the attribute list (with MA's 16-byte value still zero). We do NOT
    # include the response authenticator placeholder in the HMAC input.
    length = 20 + len(body)
    header_prefix = struct.pack("!BBH", code, ident, length)
    ma = _hmac.new(
        secret.encode("utf-8"),
        header_prefix + req_authenticator + body,
        hashlib.md5,
    ).digest()
    # 4. Patch the MA value into the body (it's at the end)
    body = body[:-16] + ma

    # 5. Build the full packet (header with zero auth) and compute
    # Response Authenticator (RFC 2865 §3): MD5(packet-with-zero-auth || secret)
    header = header_prefix + b"\x00" * 16
    resp_auth = hashlib.md5(
        header + req_authenticator + body + secret.encode("utf-8")
    ).digest()
    return header[:4] + resp_auth + body


# ---- main loop ------------------------------------------------------------

def handle_request(data, addr, args, sock, secret):
    global _total_requests, _total_replies, _total_bytes_rx, _total_bytes_tx
    _total_bytes_rx += len(data)

    try:
        pkt = parse_radius_packet(data)
    except ValueError as e:
        _log(f"[{_ts()}] PARSE-ERR  src={addr[0]}:{addr[1]}  {e}")
        return

    _total_requests += 1

    code_name = CODE_NAMES.get(pkt["code"], f"code={pkt['code']}")
    username  = get_string(pkt["attributes"], ATTR_USER_NAME)
    calling   = get_string(pkt["attributes"], ATTR_CALLING_STATION_ID)
    called    = get_string(pkt["attributes"], ATTR_CALLED_STATION_ID)
    nas_id    = get_string(pkt["attributes"], ATTR_NAS_IDENTIFIER)
    state_hex = next((v.hex() for t, _, v in pkt["attributes"] if t == ATTR_STATE), "")
    has_eap   = any(t == ATTR_EAP_MESSAGE for t, _, _ in pkt["attributes"])

    summary = (
        f"[{_ts()}] RECV     code={code_name:<18} ident={pkt['ident']:>3}  "
        f"src={addr[0]}:{addr[1]}  len={pkt['length']:>4}  "
        f"attrs={len(pkt['attributes']):>2}  eap={'Y' if has_eap else 'N'}  "
        f"username={username!r}"
    )
    if calling:
        summary += f"  mac={calling}"
    if called:
        summary += f"  ap={called}"
    if nas_id:
        summary += f"  nas={nas_id}"
    if state_hex:
        summary += f"  state=0x{state_hex[:16]}"
    _log(summary)

    if _debug:
        _dbg(f"[{_ts()}]   raw packet ({pkt['length']} bytes):")
        _dbg(_hexdump(data))
        _dbg(f"[{_ts()}]   request authenticator: {pkt['authenticator'].hex()}")
        _dbg(f"[{_ts()}]   full attribute table:")
        for i, (t, l, v) in enumerate(pkt["attributes"]):
            tname = ATTR_NAMES.get(t, f"Type={t}")
            decoded = decode_attr(t, v)
            # multi-line decodes (EAP) need indentation
            indent = "        "
            if "\n" in decoded:
                _dbg(f"{indent}{i:>2}. {tname} ({l}B):\n{indent}     "
                     + decoded.replace("\n", f"\n{indent}     "))
            else:
                _dbg(f"{indent}{i:>2}. {tname} ({l}B): {decoded}")

    if args.mode == "log-only":
        _log(f"[{_ts()}] LOG-ONLY  no reply sent (mode=log-only)")
        return

    if args.mode == "broken":
        # INTENTIONALLY send a malformed Access-Reject (Length field claims
        # 200 bytes, but only 20 bytes actually sent). hostapd logs
        # "Incoming RADIUS packet did not have correct Message-Authenticator"
        # OR "Parsing incoming frame failed", drops the reply, and the
        # iPhone's EAP exchange stalls. iPhone times out, retries every
        # 5-10s.
        #
        # Empirically (run-20260719-220641, 146s): 28 RECV events at
        # ~11.5/min. Compare to clean EAP-Failure: 2 RECV events at
        # ~1/min (then iPhone backs off 30-60s). Compare to log-only:
        # ~4 RECV/min.
        #
        # Why this works: the iPhone never gets a clean EAP-Failure,
        # so its BSSID blacklist counter never increments, and auto-join
        # stays enabled indefinitely. The circle-spinner UI state on
        # the iPhone means it's perpetually in "trying to authenticate,
        # waiting for response" — exactly what we want for dense RSSI
        # + pseudonym capture.
        bad_reply = struct.pack(
            "!BBH", CODE_ACCESS_REJECT, pkt["ident"], 200
        ) + b"\x00" * 16  # claim 200 bytes, only send 20 (header + 16-byte auth placeholder)
        try:
            sock.sendto(bad_reply, addr)
            _log(f"[{_ts()}] BROKEN    code=Access-Reject      "
                 f"ident={pkt['ident']:>3}  sent MALFORMED 20B "
                 f"(claimed 200) to {addr[0]}:{addr[1]}")
        except OSError as e:
            _log(f"[{_ts()}] SEND-ERR  {e}")
        return

    if pkt["code"] != CODE_ACCESS_REQUEST:
        _log(f"[{_ts()}] SKIP      non-Access-Request packet, no reply")
        return

    if args.mode == "accept":
        reply_code = CODE_ACCESS_ACCEPT
        action = "ACCEPT"
    elif args.mode == "sweep":
        # Alternate reject/accept every args.sweep_interval requests.
        # Used for A/B comparison: half the time the phone gets
        # Access-Reject (continue retry loop), half Access-Accept.
        _sweep_count[0] = _sweep_count[0] + 1
        if _sweep_count[0] % (args.sweep_interval * 2) < args.sweep_interval:
            reply_code = CODE_ACCESS_REJECT
            action = "REJECT(sweep)"
        else:
            reply_code = CODE_ACCESS_ACCEPT
            action = "ACCEPT(sweep)"
    else:
        reply_code = CODE_ACCESS_REJECT
        action = "REJECT"

    reply = build_reply_with_ma(
        reply_code, pkt["ident"], pkt["authenticator"], secret
    )
    _total_bytes_tx += len(reply)
    try:
        sock.sendto(reply, addr)
        _total_replies += 1
        _log(f"[{_ts()}] {action}    code={CODE_NAMES[reply_code]:<18} "
             f"ident={pkt['ident']:>3}  sent {len(reply)}B to {addr[0]}:{addr[1]}")
        if _debug:
            _dbg(f"[{_ts()}]   reply packet ({len(reply)} bytes):")
            _dbg(_hexdump(reply))
            # The reply's "Response Authenticator" 16 bytes are NOT an
            # attribute — they're part of the header. Re-parse by
            # treating the reply as a request (just for attribute dump).
            try:
                # Skip the response auth by stripping the bytes 4-19
                # and feeding the rest to a "header-less" attribute walk.
                # Easier: read attributes from offset 20 of the reply.
                code_r, ident_r, len_r = struct.unpack("!BBH", reply[:4])
                _dbg(f"        {code_r:>2}. Response-Authenticator (16B): "
                     f"{reply[4:20].hex()}")
                # decode the rest as attributes
                i = 20
                n = 0
                while i < len(reply):
                    if i + 2 > len(reply):
                        break
                    atype, alen = struct.unpack("!BB", reply[i:i+2])
                    if alen < 2 or i + alen > len(reply):
                        break
                    aval = reply[i+2:i+alen]
                    tname = ATTR_NAMES.get(atype, f"Type={atype}")
                    decoded = decode_attr(atype, aval)
                    if "\n" in decoded:
                        _dbg(f"        {n:>2}. {tname} ({alen}B):\n        "
                             + decoded.replace("\n", "\n        "))
                    else:
                        _dbg(f"        {n:>2}. {tname} ({alen}B): {decoded}")
                    i += alen
                    n += 1
            except Exception as e:
                _dbg(f"        [decode error: {e}]")
    except OSError as e:
        _log(f"[{_ts()}] SEND-ERR  {e}")


def serve(args):
    global _log_fp, _debug
    _debug = args.debug
    if args.log:
        try:
            _log_fp = open(args.log, "a", buffering=1)
        except OSError as e:
            print(f"[!] cannot open log file {args.log}: {e}", file=sys.stderr)
            sys.exit(2)

    secret = args.secret
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((args.bind, args.port))
    except OSError as e:
        _log(f"[{_ts()}] FATAL     cannot bind {args.bind}:{args.port}: {e}")
        if _log_fp:
            _log_fp.close()
        sys.exit(1)

    sock.settimeout(1.0)
    _log(
        f"[{_ts()}] LISTEN    udp/{args.bind}:{args.port}  "
        f"mode={args.mode}  secret={'*' * len(secret) if not args.quiet else '<set>'}  "
        f"debug={'on' if _debug else 'off'}"
    )

    def _stop(*_):
        global _running
        _running = False

    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    while _running:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        handle_request(data, addr, args, sock, secret)

    uptime = int(time.time() - _start_ts)
    _log(
        f"[{_ts()}] SHUTDOWN  requests={_total_requests}  "
        f"replies={_total_replies}  rx={_total_bytes_rx}B  "
        f"tx={_total_bytes_tx}B  uptime={uptime}s"
    )
    sock.close()
    if _log_fp:
        _log_fp.close()


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--bind",   default=os.environ.get("RADIUS_BIND", "127.0.0.1"),
                   help="bind address (default 127.0.0.1)")
    p.add_argument("--port",   type=int,
                   default=int(os.environ.get("RADIUS_PORT", "1812")),
                   help="UDP port (default 1812)")
    p.add_argument("--secret", default=os.environ.get("RADIUS_SECRET", "testing123"),
                   help="shared secret (default testing123)")
    p.add_argument("--mode",   default="broken",
                   choices=["broken", "reject", "accept", "log-only", "sweep"],
                   help="reply mode (default broken). "
                        "'broken' = send intentionally malformed Access-"
                        "Reject (hostapd drops it, iPhone stalls, retries "
                        "every 5-10s — best for dense capture, ~11 RECV/min, "
                        "never blacklists, never disables auto-join). "
                        "'log-only' = log Access-Request, send NO reply "
                        "(~4 RECV/min). 'reject' = clean EAP-Failure, "
                        "iPhone backs off 30-60s (~2 RECV/min). "
                        "'sweep' alternates reject/accept.")
    p.add_argument("--sweep-interval", type=int, default=5,
                   help="sweep mode: requests per reject (or accept) "
                        "block before switching (default 5)")
    p.add_argument("--log",    default=None,
                   help="mirror log lines to this file")
    p.add_argument("--quiet",  action="store_true",
                   help="do not print the secret in the LISTEN line")
    p.add_argument("--debug",  action="store_true",
                   help="hex-dump every packet, full attribute table, "
                        "full EAP decode, reply-packet construction trace")
    args = p.parse_args()
    serve(args)


if __name__ == "__main__":
    main()
