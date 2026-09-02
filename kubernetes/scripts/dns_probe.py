#!/usr/bin/env python3
import argparse
import ipaddress
import json
import random
import socket
import struct

TYPES = {"A": 1, "TXT": 16}


def encode_name(name: str) -> bytes:
    labels = name.rstrip(".").encode("ascii").split(b".")
    if any(not label or len(label) > 63 for label in labels):
        raise ValueError("invalid DNS name")
    return b"".join(bytes([len(label)]) + label for label in labels) + b"\0"


def decode_name(message: bytes, offset: int) -> tuple[str, int]:
    labels: list[bytes] = []
    next_offset = offset
    jumped = False
    seen: set[int] = set()
    while True:
        if offset >= len(message) or offset in seen:
            raise ValueError("invalid compressed DNS name")
        seen.add(offset)
        length = message[offset]
        if length == 0:
            if not jumped:
                next_offset = offset + 1
            break
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(message):
                raise ValueError("truncated DNS pointer")
            if not jumped:
                next_offset = offset + 2
            offset = ((length & 0x3F) << 8) | message[offset + 1]
            jumped = True
            continue
        if length & 0xC0:
            raise ValueError("invalid DNS label")
        offset += 1
        labels.append(message[offset : offset + length])
        offset += length
        if not jumped:
            next_offset = offset
    return b".".join(labels).decode("ascii") + ".", next_offset


def exchange(server: str, packet: bytes) -> bytes:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        sock.sendto(packet, (server, 53))
        response, peer = sock.recvfrom(65535)
        if peer[0] != server or len(response) < 12 or response[:2] != packet[:2]:
            raise ValueError("invalid DNS response")
        return response
    finally:
        sock.close()


def query(server: str, name: str, record_type: str) -> dict[str, object]:
    identifier = random.SystemRandom().randrange(65536)
    question = encode_name(name) + struct.pack("!HH", TYPES[record_type], 1)
    response = exchange(server, struct.pack("!HHHHHH", identifier, 0, 1, 0, 0, 0) + question)
    _, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", response[:12])
    offset = 12
    for _ in range(qdcount):
        _, offset = decode_name(response, offset)
        offset += 4
    values: list[str] = []
    for _ in range(ancount):
        _, offset = decode_name(response, offset)
        rrtype, rrclass, _, length = struct.unpack("!HHIH", response[offset : offset + 10])
        offset += 10
        rdata = response[offset : offset + length]
        offset += length
        if rrclass != 1 or rrtype != TYPES[record_type]:
            continue
        if record_type == "A" and length == 4:
            values.append(str(ipaddress.ip_address(rdata)))
        elif record_type == "TXT":
            cursor = 0
            parts: list[bytes] = []
            while cursor < len(rdata):
                size = rdata[cursor]
                cursor += 1
                parts.append(rdata[cursor : cursor + size])
                cursor += size
            values.append(b"".join(parts).decode("utf-8"))
    return {"rcode": flags & 0xF, "aa": bool(flags & 0x0400), "values": sorted(values)}


def unsigned_update(server: str, name: str) -> dict[str, object]:
    identifier = random.SystemRandom().randrange(65536)
    zone = encode_name("monosense.io") + struct.pack("!HH", 6, 1)
    update = encode_name(name) + struct.pack("!HHIH", 1, 1, 300, 4) + ipaddress.ip_address("192.0.2.10").packed
    packet = struct.pack("!HHHHHH", identifier, 5 << 11, 1, 0, 1, 0) + zone + update
    response = exchange(server, packet)
    flags = struct.unpack("!H", response[2:4])[0]
    return {"rcode": flags & 0xF}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("server")
    subparsers = parser.add_subparsers(dest="command", required=True)
    query_parser = subparsers.add_parser("query")
    query_parser.add_argument("name")
    query_parser.add_argument("type", choices=sorted(TYPES))
    update_parser = subparsers.add_parser("unsigned-update")
    update_parser.add_argument("name")
    args = parser.parse_args()
    result = query(args.server, args.name, args.type) if args.command == "query" else unsigned_update(args.server, args.name)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
