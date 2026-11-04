"""Cliente serie de la Debug Unit: envía comandos y recibe respuestas.

Uso típico:

    from serial_link import DebugLink, read_hex

    with DebugLink("COM5") as link:          # en Linux: "/dev/ttyUSB1"
        link.load(read_hex("programs/suma.hex"))
        d = link.step()
        print(hex(d.pc), d.regs[1])
        d = link.run()                       # bloquea hasta HALT
        print(link.read_dmem(0, 4))

Para probar sin placa se le pasa un FakeSerial (fake_serial.py):

    link = DebugLink(ser=FakeSerial())

Timeouts (protocolo_uart.md, sección 4): 500 ms por respuesta; en LOAD se
suma el tiempo de transferencia; RUN espera sin límite salvo que se indique.
Reintentos: solo en comandos idempotentes (PING, RESET, LOAD, DUMP,
READ_DMEM), cuando no llega respuesta o la FPGA responde NACK por TIMEOUT o
UART_ERR. STEP, RUN y STOP no se reintentan: repetirlos cambiaría el estado.
Mientras el core está en RUN la librería solo deja enviar STOP (D12).

Issue: SW-2 (#17).
"""

import time
from typing import List, Optional, Sequence

import protocol as P

DEFAULT_BAUD = 115200       # D9
RESPONSE_TIMEOUT = 0.5      # s, protocolo_uart.md sección 4


class LinkError(Exception):
    """Error de comunicación con la placa (puerto, timeout, carga corrupta)."""


class ResponseTimeout(LinkError):
    """No llegó una respuesta completa a tiempo."""


# --------------------------------------------------------------------------
# Puerto serie
# --------------------------------------------------------------------------

def open_serial(port: str, baud: int = DEFAULT_BAUD):
    """Abre el puerto real con pyserial (8N1) o explica por qué no se pudo."""
    try:
        import serial
        from serial.tools import list_ports
    except ImportError as e:
        raise LinkError("Falta pyserial: pip install -r requirements.txt") from e
    try:
        return serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1,
                             timeout=RESPONSE_TIMEOUT)
    except (serial.SerialException, ValueError, OSError) as e:
        ports = ", ".join(p.device for p in list_ports.comports()) or "ninguno"
        raise LinkError(
            f"No se pudo abrir el puerto {port!r}: {e}\n"
            f"¿Está conectada la Basys 3 por USB? Puertos disponibles: {ports}"
        ) from e


def read_frame(ser, timeout: Optional[float]) -> P.Frame:
    """Lee una trama [SOF][tipo][len][payload], descartando basura antes del SOF.

    timeout=None espera sin límite (para RUN), en tramos cortos para que
    Ctrl+C funcione.
    """
    deadline = None if timeout is None else time.monotonic() + timeout
    pending = bytearray()       # bytes leídos que hay que volver a mirar

    def read_exact(n: int) -> bytes:
        buf = pending[:n]
        del pending[:n]
        while len(buf) < n:
            if deadline is None:
                ser.timeout = 0.1
            else:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ResponseTimeout(f"sin respuesta completa en {timeout:.3f} s")
                ser.timeout = remaining
            buf += ser.read(n - len(buf))
        return bytes(buf)

    while True:
        if read_exact(1)[0] != P.SOF:
            continue                            # resincronización
        hdr = read_exact(3)
        ftype, length = hdr[0], hdr[1] | (hdr[2] << 8)
        if ftype not in (P.T_ACK, P.T_NACK, P.T_DUMP, P.T_DMEM):
            # El 0xAA era basura: el SOF verdadero puede estar en estos 3 bytes
            pending[:0] = hdr
            continue
        return P.Frame(ftype, read_exact(length))


def read_hex(path: str) -> List[int]:
    """Lee un programa .hex: una palabra de 32 bits en hexa por línea.

    Ignora líneas vacías y comentarios (// o #).
    """
    words = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.split("//")[0].split("#")[0].strip()
            if not line:
                continue
            try:
                words.append(int(line, 16))
            except ValueError as e:
                raise ValueError(f"{path}:{n}: palabra inválida {line!r}") from e
    P.check_program(words)
    return words


# --------------------------------------------------------------------------
# Cliente
# --------------------------------------------------------------------------

class DebugLink:
    """Cliente del protocolo de la Debug Unit.

    port: puerto serie ("COM5", "/dev/ttyUSB1"). ser: objeto ya abierto con
    la interfaz de pyserial (read/write/reset_input_buffer/timeout), por
    ejemplo un FakeSerial. Con check=True hace PING al conectar para dar un
    error claro si no hay placa.
    """

    def __init__(self, port: Optional[str] = None, baud: int = DEFAULT_BAUD, *,
                 ser=None, timeout: float = RESPONSE_TIMEOUT, retries: int = 2,
                 check: bool = True):
        if ser is None:
            if port is None:
                raise LinkError("Hace falta un puerto serie (port) o un objeto ser")
            ser = open_serial(port, baud)
        self.ser = ser
        self.port = port or type(ser).__name__
        self.baud = baud
        self.timeout = timeout
        self.retries = retries
        self.running = False
        if check:
            try:
                self.ping()
            except LinkError as e:
                raise LinkError(
                    f"La placa no responde en {self.port}: {e}\n"
                    "¿Está programado el bitstream y es el puerto correcto?"
                ) from e

    # --- contexto ---
    def close(self) -> None:
        self.ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # --- internos ---
    def _byte_time(self) -> float:
        return 10.0 / self.baud

    def _check_idle(self, name: str) -> None:
        if self.running:
            raise LinkError(f"El core está en RUN: no se puede enviar {name}, solo STOP")

    def _send(self, data: bytes) -> None:
        self.ser.reset_input_buffer()
        self.ser.write(data)
        if hasattr(self.ser, "flush"):
            self.ser.flush()

    def _transact(self, data: bytes, timeout: float, retry: bool, check=None):
        """Envía data y devuelve lo que devuelva check(frame).

        Con retry, reintenta ante falta de respuesta, NACK por TIMEOUT o
        UART_ERR, o si check lanza LinkError (por ejemplo, carga corrupta).
        """
        name = P.CMD_NAMES.get(data[0], f"0x{data[0]:02X}")
        attempts = 1 + (self.retries if retry else 0)
        last = None
        for _ in range(attempts):
            self._send(data)
            try:
                frame = read_frame(self.ser, timeout)
                return check(frame) if check else frame
            except ResponseTimeout as e:
                last = e
            except P.NackError as e:
                if e.code not in (P.E_TIMEOUT, P.E_UART_ERR):
                    raise
                last = e
            except LinkError as e:
                last = e
        if isinstance(last, ResponseTimeout):
            raise ResponseTimeout(f"{name}: {last} (intentos: {attempts})")
        if isinstance(last, P.NackError):
            raise last
        raise LinkError(f"{name}: {last} (intentos: {attempts})")

    # --- comandos ---
    def ping(self) -> None:
        self._check_idle("PING")
        self._transact(P.encode_simple(P.CMD_PING), self.timeout, True,
                       lambda f: P.parse_ack(f, P.CMD_PING))

    def reset(self) -> None:
        """PC=0, pipeline vacío, registros y dmem en cero. No toca la imem."""
        self._check_idle("RESET")
        self._transact(P.encode_simple(P.CMD_RESET), self.timeout, True,
                       lambda f: P.parse_ack(f, P.CMD_RESET))

    def load(self, program: Sequence[int]) -> None:
        """Carga el programa (reset completo antes, D10) y verifica words y xor."""
        self._check_idle("LOAD")
        words = list(program)
        data = P.encode_load(words)
        exp_xor = P.load_checksum(words)
        timeout = self.timeout + P.load_bytes(words) * self._byte_time()

        def check(frame):
            n, x = P.parse_load_ack(frame)
            if n != len(words) or x != exp_xor:
                raise LinkError(f"carga corrupta: la placa recibió {n} palabras con xor 0x{x:02X}, "
                                f"se enviaron {len(words)} con xor 0x{exp_xor:02X}")

        self._transact(data, timeout, True, check)

    def step(self) -> P.Dump:
        """Avanza un ciclo y devuelve el volcado."""
        self._check_idle("STEP")
        return self._transact(P.encode_simple(P.CMD_STEP), self.timeout, False, P.parse_dump)

    def dump(self) -> P.Dump:
        self._check_idle("DUMP")
        return self._transact(P.encode_simple(P.CMD_DUMP), self.timeout, True, P.parse_dump)

    def read_dmem(self, addr: int, n: int) -> List[int]:
        """Lee n palabras de la dmem desde la dirección de byte addr.

        n = 0 pide desde addr hasta la mayor dirección escrita (dmem_hwm, D11).
        """
        self._check_idle("READ_DMEM")
        data = P.encode_read_dmem(addr, n)
        timeout = self.timeout + (8 + 4 * (n or P.DMEM_BYTES // 4)) * self._byte_time()

        def check(frame):
            d = P.parse_dmem(frame)
            if d.addr != addr or (n and len(d.words) != n):
                raise P.ProtocolError(f"DMEM con addr=0x{d.addr:X} y {len(d.words)} palabras, "
                                      f"se pidieron addr=0x{addr:X} y {n}")
            return d.words

        return self._transact(data, timeout, True, check)

    def start_run(self) -> None:
        """Arranca RUN sin esperar. Después: wait_run() o stop()."""
        self._check_idle("RUN")
        self._send(P.encode_simple(P.CMD_RUN))
        self.running = True

    def wait_run(self, timeout: Optional[float] = None) -> P.Dump:
        """Espera el DUMP con que termina RUN (HALT). timeout=None: sin límite.

        Si vence el timeout el core sigue corriendo: se puede llamar a stop().
        """
        if not self.running:
            raise LinkError("No hay un RUN en curso")
        frame = read_frame(self.ser, timeout)
        self.running = False
        return P.parse_dump(frame)

    def run(self, timeout: Optional[float] = None) -> P.Dump:
        """RUN hasta HALT y devuelve el volcado."""
        self.start_run()
        return self.wait_run(timeout)

    def stop(self) -> Optional[P.Dump]:
        """Detiene un RUN y devuelve el volcado; fuera de RUN devuelve None."""
        if not self.running:
            self._transact(P.encode_simple(P.CMD_STOP), self.timeout, False,
                           lambda f: P.parse_ack(f, P.CMD_STOP))
            return None
        # Sin reset_input_buffer: el DUMP de un HALT puede estar ya en camino
        self.ser.write(P.encode_simple(P.CMD_STOP))
        frame = read_frame(self.ser, self.timeout + (P.DUMP_LEN + 4) * self._byte_time())
        self.running = False
        dump = P.parse_dump(frame)
        # Si el HALT llegó justo antes que el STOP, la FPGA ya estaba en IDLE y
        # responde ACK al STOP: se descarta para no confundir al comando siguiente.
        try:
            stray = read_frame(self.ser, 20 * self._byte_time() + 0.01)
            if stray != P.frame_ack(P.CMD_STOP):
                raise P.ProtocolError(f"respuesta inesperada después de STOP: {stray}")
        except ResponseTimeout:
            pass
        return dump
