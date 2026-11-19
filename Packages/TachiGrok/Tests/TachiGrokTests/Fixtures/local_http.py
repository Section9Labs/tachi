#!/usr/bin/env python3
"""Loopback HTTP fixture. Binds 127.0.0.1 and records request lines only."""

import argparse
import signal
import socket
import threading
import time

signal.signal(signal.SIGPIPE, signal.SIG_IGN)


def read_request(conn):
    conn.settimeout(2)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return data, b""
        data += chunk
        if len(data) > 65536:
            break
    head, _, rest = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            try:
                length = int(line.split(b":", 1)[1].strip() or b"0")
            except ValueError:
                length = 0
    length = max(0, min(length, 65536))
    while len(rest) < length:
        chunk = conn.recv(4096)
        if not chunk:
            break
        rest += chunk
    return head, rest


def record(path, lock, head):
    line = head.split(b"\r\n", 1)[0].decode("latin1", "replace")[:180]
    saw_auth = b"\r\nauthorization: bearer " in b"\r\n" + head.lower()
    with lock:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(f"{line} auth={'yes' if saw_auth else 'no'}\n")
            stream.flush()


def serve_connection(conn, args, lock):
    try:
        head, _ = read_request(conn)
        if not head:
            return
        record(args.hit_file, lock, head)
        if args.mode == "silent" or args.mode == "proxy":
            time.sleep(args.hold)
            return
        if args.mode == "continue":
            conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            time.sleep(0.2)
        location = b""
        if args.location:
            location = b"Location: " + args.location.encode("ascii") + b"\r\n"
        message = (
            f"HTTP/1.1 {args.status} OK\r\nContent-Length: 32\r\nConnection: close\r\n".encode("ascii")
            + location
            + b"\r\n"
        )
        conn.sendall(message)
        time.sleep(args.hold)
        try:
            conn.sendall(b"B" * 32)
        except OSError:
            pass
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hit-file", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--mode", choices=("hold", "silent", "proxy", "continue"), required=True)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--hold", type=float, default=5)
    parser.add_argument("--location", default="")
    args = parser.parse_args()
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(16)
    port = server.getsockname()[1]
    with open(args.port_file, "w", encoding="utf-8") as stream:
        stream.write(f"{port}\n")
        stream.flush()
    lock = threading.Lock()
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve_connection, args=(conn, args, lock), daemon=True).start()


if __name__ == "__main__":
    main()
