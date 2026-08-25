#!/usr/bin/env python3
"""Send one minimal DNS query and require a successful answer."""

import argparse
import socket
import struct

QUERY_ID = 0xB10C
QNAME = "healthcheck.blocky."


def encode_name(name: str) -> bytes:
    return b"".join(bytes((len(label),)) + label.encode("ascii") for label in name.rstrip(".").split(".")) + b"\0"


def build_query() -> bytes:
    header = struct.pack("!HHHHHH", QUERY_ID, 0x0100, 1, 0, 0, 0)
    question = encode_name(QNAME) + struct.pack("!HH", 1, 1)
    return header + question


def check_response(response: bytes) -> None:
    if len(response) < 12:
        raise RuntimeError("DNS response is shorter than its header")

    query_id, flags, questions, _, _, _ = struct.unpack("!HHHHHH", response[:12])
    if query_id != QUERY_ID:
        raise RuntimeError(f"unexpected DNS transaction ID: {query_id:#x}")
    if flags & 0x8000 == 0:
        raise RuntimeError("DNS response bit is not set")
    if flags & 0x000F != 0:
        raise RuntimeError(f"DNS response code is {flags & 0x000F}, expected NOERROR")
    if questions != 1:
        raise RuntimeError(f"unexpected DNS question count: {questions}")


def query_udp(host: str, port: int, payload: bytes) -> bytes:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(payload, (host, port))
        return sock.recvfrom(4096)[0]


def recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        chunk = sock.recv(length - len(chunks))
        if not chunk:
            raise RuntimeError("DNS TCP connection closed before the response completed")
        chunks.extend(chunk)
    return bytes(chunks)


def query_tcp(host: str, port: int, payload: bytes) -> bytes:
    with socket.create_connection((host, port), timeout=5) as sock:
        sock.sendall(struct.pack("!H", len(payload)) + payload)
        response_length = struct.unpack("!H", recv_exact(sock, 2))[0]
        return recv_exact(sock, response_length)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("protocol", choices=("udp", "tcp"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=53)
    args = parser.parse_args()

    payload = build_query()
    response = query_udp(args.host, args.port, payload) if args.protocol == "udp" else query_tcp(args.host, args.port, payload)
    check_response(response)
    print(f"{args.protocol.upper()} DNS health query succeeded")


if __name__ == "__main__":
    main()
