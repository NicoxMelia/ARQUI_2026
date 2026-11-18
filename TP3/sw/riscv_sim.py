"""Simulador funcional de referencia del subconjunto RV32I (doc/isa.md).

No modela el pipeline: ejecuta una instrucción por paso. Sirve como modelo
dorado para verificar los .expected.json de programs/ y para detectar
dependencias que el pipeline sin forwarding (hito M2) no resuelve.

Sigue las decisiones del core:
  - imem de 1024 palabras; lo que no cargó el programa vale 0 (D10);
  - ebreak detiene; una palabra que no es una de las 32 instrucciones
    (incluida 0x00000000) detiene y levanta illegal (D3);
  - un PC fuera de la imem se busca como 0x00000000 (interfaz_core.md);
  - dmem de 4 KB direccionada por byte, little-endian; dmem_hwm = mayor
    dirección escrita + 1 (D11). Un acceso desalineado o fuera de rango es
    un error del programa (D4 lo deja sin especificar) y lanza SimError.

Issue: TEST-1 (#18).
"""

from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

import isa_table as T

IMEM_WORDS = 1024
DMEM_BYTES = 4096
MASK = 0xFFFFFFFF


class SimError(Exception):
    """El programa hizo algo que el core no define (acceso desalineado, etc.)."""


def _sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def _signed(v: int) -> int:
    return _sext(v, 32)


# (opcode, funct3, funct7 o None) -> mnemónico. funct7 None = no se mira.
_DECODE = {}
for _m, (_fmt, _op, _f3, _f7) in T.ISA.items():
    if _fmt == "R" or _m in T.SHIFT_IMM:
        _DECODE[(_op, _f3, _f7)] = _m
    else:
        _DECODE[(_op, _f3, None)] = _m


@dataclass
class Instr:
    mnem: str               # "ebreak" o "illegal" para las especiales
    rd: int = 0
    rs1: int = 0
    rs2: int = 0
    imm: int = 0            # ya extendido con signo (U: valor << 12)

    def reads(self) -> Tuple[int, ...]:
        """Registros que lee (para detectar dependencias)."""
        if self.mnem in ("ebreak", "illegal", "lui", "jal"):
            return ()
        fmt = T.ISA[self.mnem][0]
        return (self.rs1, self.rs2) if fmt in ("R", "S", "B") else (self.rs1,)

    def writes(self) -> int:
        """Registro que escribe (0 = ninguno)."""
        if self.mnem in ("ebreak", "illegal"):
            return 0
        return self.rd if T.ISA[self.mnem][0] not in ("S", "B") else 0


def decode(w: int) -> Instr:
    if w == T.HALT:
        return Instr("ebreak")
    op, rd, f3 = w & 0x7F, (w >> 7) & 0x1F, (w >> 12) & 0x7
    rs1, rs2, f7 = (w >> 15) & 0x1F, (w >> 20) & 0x1F, w >> 25
    if op == T.OP_LUI:
        return Instr("lui", rd=rd, imm=w & 0xFFFFF000)
    if op == T.OP_JAL:
        imm = (((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) \
            | (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1)
        return Instr("jal", rd=rd, imm=_sext(imm, 21))
    mnem = _DECODE.get((op, f3, f7)) or _DECODE.get((op, f3, None))
    if mnem is None:
        return Instr("illegal")
    fmt = T.ISA[mnem][0]
    if fmt == "R":
        return Instr(mnem, rd=rd, rs1=rs1, rs2=rs2)
    if mnem in T.SHIFT_IMM:
        return Instr(mnem, rd=rd, rs1=rs1, imm=rs2)         # shamt = imm[4:0]
    if fmt == "I":
        return Instr(mnem, rd=rd, rs1=rs1, imm=_sext(w >> 20, 12))
    if fmt == "S":
        return Instr(mnem, rs1=rs1, rs2=rs2, imm=_sext(((w >> 25) << 5) | rd, 12))
    if fmt == "B":
        imm = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) \
            | (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1)
        return Instr(mnem, rs1=rs1, rs2=rs2, imm=_sext(imm, 13))
    raise AssertionError(mnem)


_ALU = {
    "add":  lambda a, b: a + b,
    "sub":  lambda a, b: a - b,
    "sll":  lambda a, b: a << (b & 31),
    "slt":  lambda a, b: int(_signed(a) < _signed(b)),
    "sltu": lambda a, b: int(a < b),
    "xor":  lambda a, b: a ^ b,
    "srl":  lambda a, b: a >> (b & 31),
    "sra":  lambda a, b: _signed(a) >> (b & 31),
    "or":   lambda a, b: a | b,
    "and":  lambda a, b: a & b,
}
_ALU_IMM = {"addi": "add", "slti": "slt", "sltiu": "sltu", "xori": "xor", "ori": "or",
            "andi": "and", "slli": "sll", "srli": "srl", "srai": "sra"}
_LOAD = {"lb": (1, True), "lh": (2, True), "lw": (4, False), "lbu": (1, False), "lhu": (2, False)}
_STORE = {"sb": 1, "sh": 2, "sw": 4}


@dataclass
class State:
    imem: List[int]
    regs: List[int] = field(default_factory=lambda: [0] * 32)
    dmem: bytearray = field(default_factory=lambda: bytearray(DMEM_BYTES))
    pc: int = 0
    halted: bool = False
    illegal: bool = False
    dmem_hwm: int = 0
    steps: int = 0

    def dmem_word(self, addr: int) -> int:
        return int.from_bytes(self.dmem[addr:addr + 4], "little")

    def dmem_words(self) -> List[int]:
        """Palabras de la dmem desde 0 hasta dmem_hwm (lo que da READ_DMEM con count=0)."""
        return [self.dmem_word(4 * i) for i in range((self.dmem_hwm + 3) // 4)]

    def _mem_addr(self, mnem: str, addr: int, size: int) -> int:
        if addr % size or not 0 <= addr <= DMEM_BYTES - size:
            raise SimError(f"{mnem} en pc=0x{self.pc:X}: acceso a 0x{addr:X} desalineado o fuera de la dmem")
        return addr

    def step(self) -> None:
        if self.halted:
            return
        word = self.imem[self.pc >> 2] if self.pc < 4 * IMEM_WORDS else 0
        i = decode(word)
        self.steps += 1
        if i.mnem in ("ebreak", "illegal"):
            self.halted = True
            self.illegal = i.mnem == "illegal"
            return

        x = self.regs
        next_pc = (self.pc + 4) & MASK
        result: Optional[int] = None
        m = i.mnem
        if m in _ALU:
            result = _ALU[m](x[i.rs1], x[i.rs2])
        elif m in _ALU_IMM:
            result = _ALU[_ALU_IMM[m]](x[i.rs1], i.imm & MASK)
        elif m == "lui":
            result = i.imm
        elif m in _LOAD:
            size, signed = _LOAD[m]
            a = self._mem_addr(m, (x[i.rs1] + i.imm) & MASK, size)
            v = int.from_bytes(self.dmem[a:a + size], "little")
            result = _sext(v, 8 * size) if signed else v
        elif m in _STORE:
            size = _STORE[m]
            a = self._mem_addr(m, (x[i.rs1] + i.imm) & MASK, size)
            self.dmem[a:a + size] = (x[i.rs2] & ((1 << 8 * size) - 1)).to_bytes(size, "little")
            self.dmem_hwm = max(self.dmem_hwm, a + size)
        elif m in ("beq", "bne"):
            if (x[i.rs1] == x[i.rs2]) == (m == "beq"):
                next_pc = (self.pc + i.imm) & MASK
        elif m == "jal":
            result = self.pc + 4
            next_pc = (self.pc + i.imm) & MASK
        elif m == "jalr":
            result = self.pc + 4
            next_pc = (x[i.rs1] + i.imm) & MASK & ~1
        else:
            raise AssertionError(m)

        if result is not None and i.rd != 0:
            x[i.rd] = result & MASK
        self.pc = next_pc


def run(words: Sequence[int], max_steps: int = 100_000) -> State:
    """Carga el programa (resto de la imem en 0) y ejecuta hasta HALT."""
    if len(words) > IMEM_WORDS:
        raise ValueError(f"el programa tiene {len(words)} palabras, la imem {IMEM_WORDS}")
    s = State(imem=list(words) + [0] * (IMEM_WORDS - len(words)))
    while not s.halted:
        if s.steps >= max_steps:
            raise SimError(f"no llegó a HALT en {max_steps} pasos (pc=0x{s.pc:X})")
        s.step()
    return s


def raw_hazards(words: Sequence[int], distance: int = 3) -> List[Tuple[int, int, int]]:
    """Dependencias RAW que un pipeline sin forwarding no resuelve.

    Con el bypass del banco de registros (D6), una instrucción puede leer
    lo que escribió otra que está `distance` (= 3) o más posiciones antes.
    Analiza el código en orden (sin seguir saltos) y devuelve
    (índice del productor, índice del consumidor, registro). x0 no cuenta.
    """
    instrs = [decode(w) for w in words]
    out = []
    for j, ins in enumerate(instrs):
        if ins.mnem in ("ebreak", "illegal"):
            break
        for i in range(max(0, j - distance + 1), j):
            rd = instrs[i].writes()
            if rd and rd in ins.reads():
                out.append((i, j, rd))
    return out
