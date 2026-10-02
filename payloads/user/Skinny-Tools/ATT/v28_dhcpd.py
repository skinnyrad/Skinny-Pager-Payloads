#!/usr/bin/env python3
"""Minimal DHCP server for br-att subnet.

Binds UDP 0.0.0.0:67, answers DHCP DISCOVER with OFFER and REQUEST with ACK
for any client on the 192.168.99.0/24 subnet. Leases are not tracked; the
server always offers 192.168.99.x with a 1-hour lease.

This is a stop-gap because:
- The Pager's dnsmasq was compiled with no-DHCP and binds port 67 anyway
- odhcpd refuses to start its DHCPv4 server ("No default route present")
  and the warning doesn't clear even after the route comes back

Use this in connection mode when nothing else is serving DHCP on br-att.
"""

import socket
import struct
import sys
import time

# Configurable
SUBNET = "192.168.99"
SERVER_IP = "192.168.99.1"
ROUTER_IP = SERVER_IP
DNS_IP = SERVER_IP
LEASE_TIME = 3600
SERVER_NAME = "v27-dhcpd"

BOOTREQUEST = 1
BOOTREPLY = 2
HTYPE_ETHER = 1
HLEN_ETHER = 6

OPT_PAD = 0
OPT_NETMASK = 1
OPT_ROUTER = 3
OPT_DNS = 6
OPT_LEASE = 51
OPT_MSGTYPE = 53
OPT_SERVERID = 54
OPT_PARAMREQ = 55
OPT_END = 255

DHCPDISCOVER = 1
DHCPOFFER = 2
DHCPREQUEST = 3
DHCPACK = 5
DHCPNAK = 6


def build_dhcp_offer(req, msg_type, xid, chaddr, requested_ip=None):
    """Build a DHCP OFFER or ACK packet."""
    yiaddr = requested_ip if requested_ip else ip_for_mac(chaddr)
    pkt = bytearray()
    # BOOTP header
    pkt += struct.pack("!BBB", BOOTREPLY, HTYPE_ETHER, HLEN_ETHER)
    pkt += struct.pack("!B", 0)            # hops
    pkt += struct.pack("!I", xid)           # xid (4-byte int)
    pkt += struct.pack("!HH", 0, 0)        # secs, flags (broadcast)
    pkt += bytes([0, 0, 0, 0])            # ciaddr
    pkt += socket.inet_aton(yiaddr)        # yiaddr
    pkt += socket.inet_aton(SERVER_IP)     # siaddr
    pkt += bytes([0, 0, 0, 0])            # giaddr
    pkt += chaddr.ljust(16, b"\x00")       # chaddr
    pkt += SERVER_NAME.encode().ljust(64, b"\x00")  # sname
    pkt += b"\x00" * 128                    # file
    pkt += struct.pack("!I", 0x63538263)   # magic cookie
    # Options
    pkt += bytes([OPT_MSGTYPE, 1, msg_type])
    pkt += bytes([OPT_SERVERID, 4]) + socket.inet_aton(SERVER_IP)
    pkt += bytes([OPT_LEASE, 4]) + struct.pack("!I", LEASE_TIME)
    pkt += bytes([OPT_NETMASK, 4]) + socket.inet_aton("255.255.255.0")
    pkt += bytes([OPT_ROUTER, 4]) + socket.inet_aton(ROUTER_IP)
    pkt += bytes([OPT_DNS, 4]) + socket.inet_aton(DNS_IP)
    pkt += bytes([OPT_END])
    return bytes(pkt)


def ip_for_mac(chaddr):
    """Deterministic per-MAC IP in the 192.168.99.0/24 range."""
    last_octet = chaddr[5] if len(chaddr) >= 6 else 100
    # Avoid clashing with SERVER_IP (.1) and broadcast (.255)
    if last_octet in (1, 255):
        last_octet = 200
    return f"{SUBNET}.{last_octet}"


def main():
    # Bind to br-att's IP only (not 0.0.0.0) so we don't collide with
    # dnsmasq if it's also bound to 0.0.0.0:67. iOS will DHCP-broadcast
    # to 255.255.255.255, the kernel will deliver to our specific bind.
    if len(sys.argv) > 1:
        bind_ip = sys.argv[1]
    else:
        bind_ip = SERVER_IP
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind((bind_ip, 67))
    print(f"v27-dhcpd listening on {bind_ip}:67 (subnet {SUBNET}.0/24)", flush=True)
    while True:
        try:
            data, addr = sock.recvfrom(1024)
        except KeyboardInterrupt:
            break
        if len(data) < 240:
            continue
        op, htype, hlen, hops, xid, secs, flags, ciaddr, yiaddr, siaddr, giaddr, chaddr = \
            struct.unpack("!BBBBIHH4s4s4s4s16s", data[:44])
        msg_type = None
        requested_ip = None
        i = 240
        while i < len(data) - 1:
            opt = data[i]
            if opt == OPT_END:
                break
            if opt == OPT_PAD:
                i += 1
                continue
            ln = data[i + 1]
            if opt == OPT_MSGTYPE and ln >= 1:
                msg_type = data[i + 2]
            if opt == 50 and ln >= 4:  # requested IP
                requested_ip = socket.inet_ntoa(data[i + 2:i + 6])
            i += 2 + ln
        if msg_type == DHCPDISCOVER:
            resp = build_dhcp_offer(data, DHCPOFFER, xid, chaddr, requested_ip)
        elif msg_type == DHCPREQUEST:
            resp = build_dhcp_offer(data, DHCPACK, xid, chaddr, requested_ip)
        else:
            continue
        sock.sendto(resp, ("255.255.255.255", 68))
        mac_str = ":".join(f"{b:02x}" for b in chaddr[:6])
        print(f"  {mac_str} -> {('OFFER' if msg_type == DHCPDISCOVER else 'ACK')} "
              f"yiaddr={requested_ip or ip_for_mac(chaddr)}", flush=True)


if __name__ == "__main__":
    main()