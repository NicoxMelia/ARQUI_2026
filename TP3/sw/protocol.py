"""Protocolo PC <-> Debug Unit: armado de comandos y parseo de respuestas.

Implementa el contrato de doc/protocolo_uart.md (tramas, códigos de NACK) y
el formato del volcado de doc/interfaz_core.md (181 B: status, PC, x0..x31 y
los latches IF/ID, ID/EX, EX/MEM, MEM/WB). No sabe nada del puerto serie: eso
está en serial_link.py.

Issue: SW-2 (#17).
"""

from dataclasses import dataclass, field
from typing import List, Sequence

# --------------------------------------------------------------------------
# Constantes del protocolo (protocolo_uart.md, secciones 2 a 4)
# --------------------------------------------------------------------------

CMD_PING = 0x01
CMD_LOAD = 0x02
CMD_RESET = 0x03
CMD_STEP = 0x04
CMD_RUN = 0x05
CMD_STOP = 0x06
CMD_DUMP = 0x07
CMD_READ_DMEM = 0x08

CMD_NAMES = {
    CMD_PING: "PING",
    CMD_LOAD: "LOAD",
    CMD_RESET: "RESET",
    CMD_STEP: "STEP",
    CMD_RUN: "RUN",
    CMD_STOP: "STOP",
    CMD_DUMP: "DUMP",
    CMD_READ_DMEM: "READ_DMEM",
}

SOF = 0xAA
T_ACK = 0x10
T_NACK = 0x11
T_DUMP = 0x20
T_DMEM = 0x21

E_UNKNOWN_CMD = 0x01
E_TIMEOUT = 0x02
E_BAD_ARG = 0x03
E_BUSY = 0x04
E_UART_ERR = 0x05

NACK_NAMES = {
    E_UNKNOWN_CMD: "UNKNOWN_CMD",
    E_TIMEOUT: "TIMEOUT",
    E_BAD_ARG: "BAD_ARG",
    E_BUSY: "BUSY",
    E_UART_ERR: "UART_ERR",
}

IMEM_WORDS = 1024           # palabras de la memoria de programa
DMEM_BYTES = 4096           # bytes de la memoria de datos
DUMP_LEN = 181              # payload del DUMP (interfaz_core.md, sección 4)
NUM_REGS = 32


class ProtocolError(Exception):
    """Trama mal formada o respuesta que no corresponde al comando."""


class NackError(ProtocolError):
    """La Debug Unit respondió NACK."""

    def __init__(self, cmd: int, code: int):
        self.cmd = cmd
        self.code = code
        cmd_name = CMD_NAMES.get(cmd, f"0x{cmd:02X}")
        code_name = NACK_NAMES.get(code, f"0x{code:02X}")
        super().__init__(f"NACK a {cmd_name}: {code_name} (0x{code:02X})")


# --------------------------------------------------------------------------
# Comandos PC -> FPGA
# --------------------------------------------------------------------------

def _u16(v: int) -> bytes:
    return bytes((v & 0xFF, (v >> 8) & 0xFF))


def _u32(v: int) -> bytes:
    return v.to_bytes(4, "little")


def check_program(words: Sequence[int]) -> None:
    """Valida un programa para LOAD: 1..1024 palabras de 32 bits."""
    if not 1 <= len(words) <= IMEM_WORDS:
        raise ValueError(f"el programa tiene {len(words)} palabras; tiene que tener entre 1 y {IMEM_WORDS}")
    for i, w in enumerate(words):
        if not 0 <= w <= 0xFFFFFFFF:
            raise ValueError(f"palabra {i} fuera de rango: {w!r}")


def check_dmem_range(addr: int, count: int) -> None:
    """Valida el rango de READ_DMEM (dirección de byte alineada, count en palabras)."""
    if addr % 4 != 0:
        raise ValueError(f"addr tiene que estar alineada a palabra: 0x{addr:X}")
    if addr < 0 or count < 0 or addr + 4 * count > DMEM_BYTES or addr >= DMEM_BYTES:
        raise ValueError(f"rango fuera de la dmem: addr=0x{addr:X}, count={count}")


def encode_simple(cmd: int) -> bytes:
    """Comando sin argumentos (PING, RESET, STEP, RUN, STOP, DUMP)."""
    return bytes((cmd,))


def encode_load(words: Sequence[int]) -> bytes:
    """LOAD: [0x02][len 2 B][len palabras little-endian]."""
    check_program(words)
    return bytes((CMD_LOAD,)) + _u16(len(words)) + b"".join(_u32(w) for w in words)


def encode_read_dmem(addr: int, count: int) -> bytes:
    """READ_DMEM: [0x08][addr 2 B][count 2 B]. count = 0 pide hasta dmem_hwm."""
    check_dmem_range(addr, count)
    return bytes((CMD_READ_DMEM,)) + _u16(addr) + _u16(count)


def load_checksum(words: Sequence[int]) -> int:
    """XOR de todos los bytes de datos de un LOAD (lo que devuelve el ACK)."""
    x = 0
    for w in words:
        for b in _u32(w):
            x ^= b
    return x


def load_bytes(words: Sequence[int]) -> int:
    """Bytes que ocupa la trama de LOAD (para calcular el timeout)."""
    return 3 + 4 * len(words)


# --------------------------------------------------------------------------
# Respuestas FPGA -> PC
# --------------------------------------------------------------------------

@dataclass
class Frame:
    """Trama de respuesta: [SOF][type][len 2 B][payload]."""
    type: int
    payload: bytes

    def encode(self) -> bytes:
        return bytes((SOF, self.type)) + _u16(len(self.payload)) + self.payload


def frame_ack(cmd: int) -> Frame:
    return Frame(T_ACK, bytes((cmd,)))


def frame_load_ack(words: int, xor: int) -> Frame:
    return Frame(T_ACK, bytes((CMD_LOAD,)) + _u16(words) + bytes((xor,)))


def frame_nack(cmd: int, code: int) -> Frame:
    return Frame(T_NACK, bytes((cmd, code)))


def raise_if_nack(frame: Frame) -> None:
    if frame.type == T_NACK:
        if len(frame.payload) != 2:
            raise ProtocolError(f"NACK con payload de {len(frame.payload)} B")
        raise NackError(frame.payload[0], frame.payload[1])


def parse_ack(frame: Frame, cmd: int) -> None:
    """Verifica que la trama sea ACK [cmd]."""
    raise_if_nack(frame)
    if frame.type != T_ACK or frame.payload != bytes((cmd,)):
        raise ProtocolError(f"se esperaba ACK a {CMD_NAMES.get(cmd, cmd)}, llegó {frame}")


def parse_load_ack(frame: Frame):
    """ACK de LOAD -> (words, xor)."""
    raise_if_nack(frame)
    p = frame.payload
    if frame.type != T_ACK or len(p) != 4 or p[0] != CMD_LOAD:
        raise ProtocolError(f"se esperaba ACK de LOAD, llegó {frame}")
    return p[1] | (p[2] << 8), p[3]


# --------------------------------------------------------------------------
# Volcado (interfaz_core.md, secciones 3 y 4)
# --------------------------------------------------------------------------

def _bits(v: int, lo: int, width: int) -> int:
    return (v >> lo) & ((1 << width) - 1)


@dataclass
class Status:
    halted: bool
    illegal: bool
    pipeline_empty: bool
    valid: List[bool]           # [IF/ID, ID/EX, EX/MEM, MEM/WB]

    @classmethod
    def from_byte(cls, b: int) -> "Status":
        return cls(
            halted=bool(b & 0x01),
            illegal=bool(b & 0x02),
            pipeline_empty=bool(b & 0x04),
            valid=[bool(b & (1 << (3 + i))) for i in range(4)],
        )

    def to_byte(self) -> int:
        b = int(self.halted) | (int(self.illegal) << 1) | (int(self.pipeline_empty) << 2)
        for i, v in enumerate(self.valid):
            b |= int(v) << (3 + i)
        return b


@dataclass
class IfId:
    pc: int
    instr: int

    @classmethod
    def from_int(cls, v: int) -> "IfId":
        return cls(pc=_bits(v, 0, 32), instr=_bits(v, 32, 32))


@dataclass
class IdEx:
    pc: int
    rs1_val: int
    rs2_val: int
    imm: int
    rs1: int
    rs2: int
    rd: int
    funct3: int
    alu_op: int                 # {funct7[5], funct3}
    reg_write: bool
    mem_read: bool
    mem_write: bool
    branch: bool
    jal: bool
    jalr: bool
    alu_src_imm: bool

    @classmethod
    def from_int(cls, v: int) -> "IdEx":
        return cls(
            pc=_bits(v, 0, 32),
            rs1_val=_bits(v, 32, 32),
            rs2_val=_bits(v, 64, 32),
            imm=_bits(v, 96, 32),
            rs1=_bits(v, 128, 5),
            rs2=_bits(v, 133, 5),
            rd=_bits(v, 138, 5),
            funct3=_bits(v, 143, 3),
            alu_op=_bits(v, 146, 4),
            reg_write=bool(_bits(v, 150, 1)),
            mem_read=bool(_bits(v, 151, 1)),
            mem_write=bool(_bits(v, 152, 1)),
            branch=bool(_bits(v, 153, 1)),
            jal=bool(_bits(v, 154, 1)),
            jalr=bool(_bits(v, 155, 1)),
            alu_src_imm=bool(_bits(v, 156, 1)),
        )


@dataclass
class ExMem:
    alu_result: int
    store_data: int
    rd: int
    funct3: int
    reg_write: bool
    mem_read: bool
    mem_write: bool

    @classmethod
    def from_int(cls, v: int) -> "ExMem":
        return cls(
            alu_result=_bits(v, 0, 32),
            store_data=_bits(v, 32, 32),
            rd=_bits(v, 64, 5),
            funct3=_bits(v, 69, 3),
            reg_write=bool(_bits(v, 72, 1)),
            mem_read=bool(_bits(v, 73, 1)),
            mem_write=bool(_bits(v, 74, 1)),
        )


@dataclass
class MemWb:
    rdata: int                  # sin extender (la extensión se hace en WB)
    alu_result: int
    rd: int
    funct3: int
    reg_write: bool
    mem_read: bool

    @classmethod
    def from_int(cls, v: int) -> "MemWb":
        return cls(
            rdata=_bits(v, 0, 32),
            alu_result=_bits(v, 32, 32),
            rd=_bits(v, 64, 5),
            funct3=_bits(v, 69, 3),
            reg_write=bool(_bits(v, 72, 1)),
            mem_read=bool(_bits(v, 73, 1)),
        )


# Offsets del payload del DUMP
OFF_STATUS = 0
OFF_PC = 1
OFF_REGS = 5
OFF_IF_ID = 133
OFF_ID_EX = 141
OFF_EX_MEM = 161
OFF_MEM_WB = 171


@dataclass
class Dump:
    status: Status
    pc: int
    regs: List[int]
    if_id: IfId
    id_ex: IdEx
    ex_mem: ExMem
    mem_wb: MemWb
    raw: bytes = field(repr=False, default=b"")

    @classmethod
    def from_payload(cls, p: bytes) -> "Dump":
        if len(p) != DUMP_LEN:
            raise ProtocolError(f"DUMP de {len(p)} B, se esperaban {DUMP_LEN}")

        def le(a: int, n: int) -> int:
            return int.from_bytes(p[a:a + n], "little")

        return cls(
            status=Status.from_byte(p[OFF_STATUS]),
            pc=le(OFF_PC, 4),
            regs=[le(OFF_REGS + 4 * i, 4) for i in range(NUM_REGS)],
            if_id=IfId.from_int(le(OFF_IF_ID, 8)),
            id_ex=IdEx.from_int(le(OFF_ID_EX, 20)),
            ex_mem=ExMem.from_int(le(OFF_EX_MEM, 10)),
            mem_wb=MemWb.from_int(le(OFF_MEM_WB, 10)),
            raw=bytes(p),
        )


def parse_dump(frame: Frame) -> Dump:
    raise_if_nack(frame)
    if frame.type != T_DUMP:
        raise ProtocolError(f"se esperaba DUMP, llegó {frame}")
    return Dump.from_payload(frame.payload)


def build_dump_payload(status: int, pc: int, regs: Sequence[int],
                       if_id: int = 0, id_ex: int = 0, ex_mem: int = 0, mem_wb: int = 0) -> bytes:
    """Arma un payload de DUMP desde valores crudos (lo usa FakeSerial)."""
    if len(regs) != NUM_REGS:
        raise ValueError("hacen falta 32 registros")
    p = bytes((status,)) + _u32(pc) + b"".join(_u32(r) for r in regs)
    p += if_id.to_bytes(8, "little") + id_ex.to_bytes(20, "little")
    p += ex_mem.to_bytes(10, "little") + mem_wb.to_bytes(10, "little")
    return p


@dataclass
class DmemData:
    addr: int
    words: List[int]


def parse_dmem(frame: Frame) -> DmemData:
    """DMEM: [addr 2 B][count 2 B][count palabras]."""
    raise_if_nack(frame)
    p = frame.payload
    if frame.type != T_DMEM or len(p) < 4:
        raise ProtocolError(f"se esperaba DMEM, llegó {frame}")
    addr = p[0] | (p[1] << 8)
    count = p[2] | (p[3] << 8)
    if len(p) != 4 + 4 * count:
        raise ProtocolError(f"DMEM con count={count} y {len(p) - 4} B de datos")
    words = [int.from_bytes(p[4 + 4 * i:8 + 4 * i], "little") for i in range(count)]
    return DmemData(addr, words)
