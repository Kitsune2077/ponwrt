#!/usr/bin/env python3
"""XMODEM-1K (1024 byte, CRC16) sender for the AN758x BL2 recovery prompt.

Linux / macOS counterpart of docs/unbrick/xmodem_send.ps1 - no third-party
modules required (only termios, which ships with CPython).

Why this exists
---------------
When BL2 cannot read the FIP volume from NAND (typical cause: the stock boot
chain wrote the flash with 8-bit BCH ECC while the released BL2 decodes with
ECC4/512 on Winbond W29N02KVSIAF), it prints

    Press x to load BL31 + U-Boot FIP via XMODEM

and waits on the 3.3V UART console.  This script drives that prompt:

    wait for the prompt -> send 'x' -> wait for the 'C' handshake
    -> send N x 1024-byte CRC packets -> EOT -> keep printing the U-Boot log

The FIP loaded this way lives in RAM only: once U-Boot's web recovery is up you
must rebuild UBI and write BL2 + FIP + sysupgrade, otherwise the next reboot
lands on the same BL2 prompt again.  See docs/UNBRICK.md.

Usage
-----
    python3 xmodem_send.py --self-test
    python3 xmodem_send.py -d /dev/ttyUSB0 --dry-run
    python3 xmodem_send.py -d /dev/ttyUSB0
    python3 xmodem_send.py -d /dev/ttyUSB0 --send-x-after 3   # board already waiting

The classic alternative with lrzsz is::

    picocom -b 115200 --send-cmd "sx -k" /dev/ttyUSB0
"""

import argparse
import os
import select
import sys
import time

try:
    import termios
    import tty
except ImportError:  # Windows: only --self-test / --dry-run are usable there
    termios = None
    tty = None

BAUD = 115200
SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
SUB = 0x1A
CRC_CHAR = 0x43  # 'C'


# --------------------------------------------------------------------------- #
# protocol helpers
# --------------------------------------------------------------------------- #
def crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_packets(image: bytes):
    packets = []
    for offset in range(0, len(image), 1024):
        chunk = image[offset:offset + 1024]
        if len(chunk) < 1024:
            chunk += bytes([SUB]) * (1024 - len(chunk))
        seq = (len(packets) + 1) & 0xFF
        header = bytes([STX, seq, 0xFF - seq])
        packets.append(header + chunk + crc16(chunk).to_bytes(2, "big"))
    return packets


# --------------------------------------------------------------------------- #
# serial port
# --------------------------------------------------------------------------- #
class Serial:
    def __init__(self, device: str):
        if termios is None:
            raise RuntimeError("termios is unavailable on this platform; use xmodem_send.ps1 on Windows")
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = termios.tcgetattr(self.fd)
        cflag &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
        cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL
        iflag &= ~(termios.IXON | termios.IXOFF | termios.IXANY | termios.ICRNL |
                   termios.INLCR | termios.IGNCR | termios.INPCK | termios.ISTRIP)
        oflag &= ~termios.OPOST
        lflag &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
        termios.tcsetattr(self.fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, termios.B115200, termios.B115200, cc])
        termios.tcflush(self.fd, termios.TCIFLUSH)

    def read(self, timeout=0.1) -> bytes:
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return b""
        try:
            return os.read(self.fd, 65536)
        except BlockingIOError:
            return b""

    def write(self, data: bytes) -> None:
        view = memoryview(data)
        while view:
            try:
                written = os.write(self.fd, view)
                view = view[written:]
            except BlockingIOError:
                time.sleep(0.001)

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# console plumbing (bare 'C' detection + NAND flood collapsing)
# --------------------------------------------------------------------------- #
NOISY = ("nand_read(", "UBI: Bad EC magic in block", "UBI: scanning [",
         "VID header offset", "PEB size:", "LEB size:")


class Console:
    def __init__(self, log_path: str, verbose: bool = False):
        self.log = open(log_path, "wb", buffering=0)
        self.partial = ""
        self.text = ""
        self.bare_c = 0
        self.rx = 0
        self.suppressed = 0
        self.verbose = verbose
        self.last_beat = time.time()

    def feed(self, chunk: bytes) -> None:
        self.rx += len(chunk)
        self.log.write(chunk)
        if len(chunk) == 1 and chunk[0] == CRC_CHAR:
            self.bare_c += 1
        text = chunk.decode("ascii", "replace")
        self.text += text
        if self.verbose:
            sys.stdout.write(text)
        for char in text:
            if char == "\n":
                line = self.partial.rstrip("\r")
                self.partial = ""
                if line:
                    self._line(line)
            else:
                self.partial += char
        # XMODEM handshake bytes arrive alone: the partial line is then just 'C's.
        stripped = self.partial.strip()
        if stripped and not stripped.strip("C"):
            self.bare_c += len(stripped)  # over-counting is harmless
        now = time.time()
        if now - self.last_beat >= 15:
            self.last_beat = now
            sys.stdout.write("\n[... rx=%d bytes, suppressed=%d lines]\n" % (self.rx, self.suppressed))
            sys.stdout.flush()

    def _line(self, line: str) -> None:
        if any(marker in line for marker in NOISY):
            self.suppressed += 1
            if self.suppressed % 500 == 0:
                sys.stdout.write("\n   ... %d NAND-scan lines suppressed (full log: %s)\n"
                                 % (self.suppressed, self.log.name))
                sys.stdout.flush()
            return
        sys.stdout.write("\n" + line)
        sys.stdout.flush()

    def close(self) -> None:
        try:
            self.log.close()
        except OSError:
            pass


def wait_for(console: Console, port: Serial, timeout: float, needle=None, byte=None):
    """Return 'text' / 'byte' / None while pumping the serial port."""
    end = time.time() + timeout
    while time.time() < end:
        chunk = port.read(0.12)
        if chunk:
            console.feed(chunk)
        if needle and needle in console.text:
            return "text"
        if byte is not None and console.bare_c:
            return "byte"
    return None


def wait_response(console: Console, port: Serial, timeout: float) -> str:
    """Return ACK / NAK / CAN / C / TIMEOUT for the packet we just sent."""
    end = time.time() + timeout
    while time.time() < end:
        chunk = port.read(0.12)
        if chunk:
            console.feed(chunk)
        data = console.text
        console.text = ""
        for name, value in (("ACK", ACK), ("NAK", NAK), ("CAN", CAN), ("C", CRC_CHAR)):
            if chr(value) in data:
                return name
    return "TIMEOUT"


def open_session(console: Console, port: Serial, poll_x: bool, poll_seconds: int,
                 no_poll: bool, banner_timeout: float = 900.0) -> bool:
    print("\nwaiting for the BL2 XMODEM session (banner or bare 'C'), polling 'x' every %ds"
          % poll_seconds, flush=True)
    end = time.time() + banner_timeout
    last_x = 0.0
    saw_press = False
    while time.time() < end:
        chunk = port.read(0.15)
        if chunk:
            console.feed(chunk)
            if "Press x" in console.text and not saw_press:
                saw_press = True
                print("\n'Press x' banner seen", flush=True)
        if console.bare_c >= 2 or (saw_press and console.bare_c >= 1):
            console.bare_c = 0
            print("\nXMODEM handshake detected", flush=True)
            return True
        if poll_x and not no_poll and time.time() - last_x >= poll_seconds:
            port.write(b"x")
            last_x = time.time()
            print("\n-> sent 'x'", flush=True)
        if len(console.text) > 8192:
            console.text = ""
    return False


# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(description="XMODEM-1K FIP sender for AN758x BL2 recovery")
    parser.add_argument("-d", "--device", default="/dev/ttyUSB0", help="serial device (default: /dev/ttyUSB0)")
    parser.add_argument("-f", "--file", default="an7581-fiberhome-hg5382a-bl31-u-boot.fip",
                        help="FIP image to upload (default: ./an7581-fiberhome-hg5382a-bl31-u-boot.fip)")
    parser.add_argument("--log", default="xmodem_log.txt", help="raw log file (default: ./xmodem_log.txt)")
    parser.add_argument("--packet-timeout", type=float, default=10.0, help="per-packet ACK timeout (default 10s)")
    parser.add_argument("--retries", type=int, default=5, help="retries per packet before re-handshaking")
    parser.add_argument("--restarts", type=int, default=3, help="whole-image restarts (default 3)")
    parser.add_argument("--poll-x", type=int, default=5, help="seconds between polled 'x' bytes")
    parser.add_argument("--no-poll-x", action="store_true", help="never send 'x' proactively")
    parser.add_argument("--send-x-after", type=float, default=0.0,
                        help="send 'x' after N seconds instead of waiting for the banner")
    parser.add_argument("--log-seconds", type=int, default=120, help="seconds of U-Boot log to show after EOT")
    parser.add_argument("--verbose", action="store_true", help="do not collapse console output")
    parser.add_argument("--self-test", action="store_true", help="check CRC16 test vector and packet layout")
    parser.add_argument("--dry-run", action="store_true", help="validate the image without opening the port")
    args = parser.parse_args()

    if args.self_test:
        vector = crc16(b"123456789")
        print("CRC16('123456789') = 0x%04X (expect 0x31C3) -> %s"
              % (vector, "PASS" if vector == 0x31C3 else "FAIL"))
        packet = build_packets(bytes(1024))[0]
        print("packet length=%d STX=0x%02X seq=%d nseq=0x%02X"
              % (len(packet), packet[0], packet[1], packet[2]))
        return 0

    try:
        image = open(args.file, "rb").read()
    except OSError as exc:
        print("cannot read image %s: %s" % (args.file, exc))
        return 1

    packets = build_packets(image)
    import hashlib
    print("image  : %s" % args.file)
    print("size   : %d bytes -> %d packets of 1024" % (len(image), len(packets)))
    print("sha256 : %s" % hashlib.sha256(image).hexdigest())
    print("device : %s at 115200 8N1" % args.device)

    if args.dry_run:
        print("DRY RUN ok")
        return 0

    port = Serial(args.device)
    console = Console(args.log, args.verbose)
    try:
        ready = False
        if args.send_x_after > 0:
            print("\n--send-x-after %.0f: sending 'x' now" % args.send_x_after, flush=True)
            time.sleep(args.send_x_after)
            port.write(b"x")
            print("initial 'x' -> %s" % wait_response(console, port, 20.0), flush=True)
            ready = console.bare_c > 0
            console.bare_c = 0

        if not ready and not open_session(console, port, args.poll_x, args.poll_x, args.no_poll_x):
            print("no XMODEM session; giving up")
            return 1

        attempts = 0
        while attempts <= args.restarts:
            print("\nstarting transfer attempt %d/%d" % (attempts + 1, args.restarts + 1), flush=True)
            index = 0
            stalled = False
            start = time.time()
            last_report = 0.0
            while index < len(packets):
                acked = False
                for attempt in range(1, args.retries + 1):
                    port.write(packets[index])
                    response = wait_response(console, port, args.packet_timeout)
                    if response == "ACK":
                        acked = True
                        break
                    if response in ("C", "CAN"):
                        print("\n%s received -> restarting image" % response, flush=True)
                        stalled = True
                        break
                    print("\npacket %d -> %s (try %d)" % (index + 1, response, attempt), flush=True)
                if stalled:
                    break
                if not acked:
                    print("\npacket %d failed %d times -> re-handshake" % (index + 1, args.retries), flush=True)
                    stalled = True
                    break
                index += 1
                if time.time() - last_report >= 2:
                    last_report = time.time()
                    print("\r>> %d/%d packets (%d%%), %.0fs elapsed"
                          % (index, len(packets), index * 100 // len(packets), time.time() - start),
                          end="", flush=True)

            if not stalled:
                print("\nall %d packets ACKed in %.0fs -> sending EOT"
                      % (len(packets), time.time() - start), flush=True)
                for _ in range(5):
                    port.write(bytes([EOT]))
                    response = wait_response(console, port, 5.0)
                    print("EOT -> %s" % response, flush=True)
                    if response == "ACK":
                        print("\nFIP accepted. Forwarding device output for %ds ...\n" % args.log_seconds,
                              flush=True)
                        end = time.time() + args.log_seconds
                        while time.time() < end:
                            chunk = port.read(0.2)
                            if chunk:
                                console.feed(chunk)
                        return 0
                print("EOT never acknowledged", flush=True)

            attempts += 1
            if attempts > args.restarts:
                break
            print("\nrestart #%d: re-opening the XMODEM session" % attempts, flush=True)
            console.text = ""
            console.bare_c = 0
            if not open_session(console, port, args.poll_x, args.poll_x, args.no_poll_x):
                print("no session on restart; giving up")
                break
        return 1
    finally:
        port.close()
        console.close()
        print("\nserial port released. raw log (%d bytes) -> %s" % (console.rx, args.log))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted by user")
        sys.exit(130)
