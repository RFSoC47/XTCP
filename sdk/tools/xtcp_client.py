"""Test the XTCP reference application using the Python 3 standard library."""
import argparse
import contextlib
import hashlib
from functools import lru_cache
import ipaddress
import json
import socket
import struct
import threading
import time

CHUNK = 256 * 1024
PATTERN = bytes(range(1, 256)) * ((CHUNK + 510) // 255)

@lru_cache(maxsize=16)
def echo_page(index):
    # Position-dependent bytes expose stale data, page swaps and multiples of 255.
    return hashlib.shake_256(b"XTCP echo v1" + index.to_bytes(8,"big")).digest(65536)

def echo_payload(offset, length):
    result=bytearray()
    while length:
        page, pos=divmod(offset,65536)
        take=min(length,65536-pos)
        result.extend(echo_page(page)[pos:pos+take])
        offset+=take
        length-=take
    return bytes(result)

class Control:
    def __init__(self, host, port, bind=None, timeout=0.6):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if bind:
            self.sock.bind((bind, 0))
        self.sock.connect((host, port))
        self.timeout = timeout
        self.tag = 0

    def close(self):
        self.sock.close()

    def transact(self, address, count, payload=None):
        if not 1 <= count <= 255 or not 0 <= address <= (1 << 32) - count:
            raise ValueError("Invalid byte address or length")
        command = 0xC0 if payload is None else 0x80
        self.tag = (self.tag + 1) & 255
        packet = struct.pack("!BBBBI", 255, command, self.tag, count, address)
        for _ in range(3):
            self.sock.send(packet + (payload or b""))
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                self.sock.settimeout(max(0.001, deadline - time.monotonic()))
                try:
                    reply = self.sock.recv(264)
                except socket.timeout:
                    break
                if len(reply) < 8:
                    raise ValueError("Truncated control response")
                v, ack, rid, size, addr = struct.unpack("!BBBBI", reply[:8])
                if rid != self.tag:
                    continue
                if (v, ack, size, addr, len(reply)) != (255, command | 8, count, address, count + 8):
                    raise ValueError(f"Control response mismatch at 0x{address:08x}: {reply[:8].hex()}")
                return reply[8:]
        raise TimeoutError(f"Control request timed out at 0x{address:08x}")

    def read(self, address, count):
        return self.transact(address, count)

    def write(self, address, payload):
        return self.transact(address, len(payload), payload)

    def identity(self):
        magic, mac, ip, tcp, udp = struct.unpack("!4s6s4sHH", self.read(0x40, 18))
        if magic != b"XTCP":
            raise ValueError("Reference application signature mismatch")
        return dict(profile=self.read(0x104, 1)[0], mac=mac.hex(":"), ip=socket.inet_ntoa(ip),
                    tcp=tcp, udp=udp, phy=int.from_bytes(self.read(0x106, 2), "big"))

    def snapshot(self):
        self.write(0x108, b"\x01")
        values = struct.unpack("!QQQQIIIHH", self.read(0x110, 48))
        return dict(zip(("tx", "rx", "afull_cycles", "cycles", "sessions", "sequence",
                         "reserved", "sticky_phy", "phy"), values))

    def wait_idle(self):
        deadline = time.monotonic() + 5
        while self.read(0x105, 1)[0] & 1:
            if time.monotonic() >= deadline:
                raise TimeoutError("TCP session still established")
            time.sleep(0.02)

def transfer(control, host, tcp, bind, mode, count, rate=None, verify=True, source_port=0):
    """Transfer exactly count bytes. Echo drains the receive socket while transmitting."""
    if count < 1 or count >= 1 << 64:
        raise ValueError("Byte count out of range")
    if control.read(0x105, 1)[0] & 1:
        raise RuntimeError("Endpoint already has an active TCP session")
    initial = [(address, control.read(address, length)) for address, length in [(4, 1), (16, 1), (24, 8)]]
    before = control.snapshot()
    expected_tx = count if mode in ("receive", "echo") else 0
    expected_rx = count if mode in ("send", "echo") else 0
    errors = []
    block = memoryview(PATTERN)

    def send_all(sock):
        try:
            sent = 0
            while sent < count:
                n = min(CHUNK, count - sent)
                i = sent % 255
                sock.sendall(echo_payload(sent,n) if mode=="echo" else block[i:i+n])
                sent += n
        except Exception as exc:
            errors.append(exc)
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    try:
        control.write(24, count.to_bytes(8, "big"))
        if rate is not None:
            control.write(16, bytes([rate]))
        control.write(4, bytes([{"receive": 1, "send": 0, "echo": 0x40}[mode]]))
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            if bind or source_port:
                sock.bind((bind or "", source_port))
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(8)
            sock.connect((host, tcp))
            start = time.monotonic_ns()
            cpu_start = time.process_time_ns()
            worker = None
            if mode == "send":
                send_all(sock)
            elif mode == "echo":
                worker = threading.Thread(target=send_all, args=(sock,), daemon=True)
                worker.start()
            received = 0
            while received < expected_tx:
                data = sock.recv(min(CHUNK, expected_tx - received))
                if not data:
                    raise EOFError(f"Only {received}/{expected_tx} bytes received")
                offset = received % 255
                expect = (echo_payload(received,len(data)) if mode=="echo" else PATTERN[offset:offset+len(data)]) if verify else None
                if verify and data != expect:
                    index = next(i for i, v in enumerate(data) if v != expect[i])
                    raise ValueError(f"TCP byte mismatch at {received+index}")
                received += len(data)
            if worker:
                worker.join(9)
                if worker.is_alive():
                    raise TimeoutError("Echo writer timed out")
            if errors:
                raise errors[0]
            if mode == "send":
                # sendall may return while data is in the host's send buffer.
                # Time the remote consumption as well, without counting TCP teardown.
                deadline = time.monotonic() + 8
                while control.snapshot()["rx"] - before["rx"] < expected_rx:
                    if time.monotonic() > deadline:
                        raise TimeoutError("FPGA did not consume the complete send")
                    time.sleep(0.0005)
            elapsed = time.monotonic_ns() - start
            cpu = time.process_time_ns() - cpu_start
            mss = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG)
        control.wait_idle()
        after = control.snapshot()
        delta_tx = (after["tx"] - before["tx"]) % (1 << 64)
        delta_rx = (after["rx"] - before["rx"]) % (1 << 64)
        if (delta_tx, delta_rx) != (expected_tx, expected_rx):
            raise ValueError(f"Byte counters {delta_tx}/{delta_rx}, expected {expected_tx}/{expected_rx}")
        return dict(mode=mode, bytes=count, seconds=elapsed/1e9, payload_Gbps=count*8/elapsed,
                    process_cpu_one_core_pct=100*cpu/elapsed, tcp_mss=mss,
                    compared_bytes=received if verify else 0, fpga_tx=delta_tx, fpga_rx=delta_rx)
    finally:
        control.wait_idle()
        for addr, value in reversed(initial):
            control.write(addr, value)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["probe", "send", "receive", "echo"])
    ap.add_argument("host", type=str)
    ap.add_argument("--bind")
    ap.add_argument("--tcp", type=int, default=24)
    ap.add_argument("--udp", type=int, default=4660)
    ap.add_argument("--bytes", type=int, default=65539)
    ap.add_argument("--rate", type=int, choices=range(1, 251), metavar="1..250")
    args = ap.parse_args()
    host = str(ipaddress.IPv4Address(args.host))
    with contextlib.closing(Control(host, args.udp, args.bind)) as control:
        info = control.identity()
        if (info["ip"], info["tcp"], info["udp"]) != (host, args.tcp, args.udp):
            raise ValueError(f"Compiled network identity differs from requested values: {info}")
        result = {"identity": info}
        if args.mode != "probe":
            result["transfer"] = transfer(control, host, args.tcp, args.bind, args.mode, args.bytes, args.rate)
        print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
