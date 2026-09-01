#!/usr/bin/env python3
import argparse
import socket

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("drain", "ready"))
parser.add_argument("--socket", default="/srv/applications/apps/edge/runtime/admin.sock")
args = parser.parse_args()
state = "maint" if args.command == "drain" else "ready"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.settimeout(5)
    connection.connect(args.socket)
    connection.sendall(f"set server forgejo_http/forgejo state {state}\n".encode())
    connection.shutdown(socket.SHUT_WR)
    response = connection.recv(4096)
if response.strip():
    raise SystemExit(response.decode(errors="replace").strip())
