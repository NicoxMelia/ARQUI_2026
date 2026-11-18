"""Ensamblador del subconjunto RV32I del TP3 (doc/isa.md).

Uso, desde TP3/:

    python sw/assembler.py programs/suma.s                 # -> programs/suma.hex
    python sw/assembler.py programs/suma.s -o x.hex -l x.lst

Salida: .hex con una palabra de 32 bits por línea (lo que leen $readmemh y
serial_link.read_hex) y, con -l, un listing "dirección  palabra  fuente".

Sintaxis:
  - Comentarios con #, // o ;.
  - Labels "nombre:" (solos o antes de una instrucción).
  - Registros x0..x31 o por nombre ABI (zero, ra, sp, gp, tp, t0-t6,
    s0/fp, s1-s11, a0-a7).
  - Inmediatos en decimal, hexa (0x), binario (0b), con signo opcional.
  - Loads/stores y jalr con "imm(rs1)"; jalr acepta también "rd, rs1, imm".
  - Branches y jal reciben un label o un offset en bytes relativo a la
    instrucción.
  - lui recibe imm[31:12] (0..0xFFFFF), como en el ensamblador de GNU.

Pseudoinstrucciones:
  nop            addi x0, x0, 0
  halt / ebreak  0x00100073
  mv rd, rs      addi rd, rs, 0
  li rd, imm     addi rd, x0, imm si entra en 12 bits; si no, lui + addi
                 (ojo: el addi depende del lui, hace falta forwarding)
  j label        jal x0, label
  jal label      jal ra, label
  jalr rs        jalr ra, 0(rs)
  ret            jalr x0, 0(ra)

La codificación sale de isa_table.encode() (no se duplica acá).

Issue: SW-1 (#16).
"""

import argparse
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import isa_table as T

MAX_WORDS = 1024            # tamaño de la imem


class AsmError(Exception):
    """Error de ensamblado. Lleva la lista de errores con número de línea."""

    def __init__(self, errors: List[str]):
        self.errors = errors
        super().__init__("\n".join(errors))


# --------------------------------------------------------------------------
# Registros e inmediatos
# --------------------------------------------------------------------------

ABI_NAMES = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    **{f"a{i}": 10 + i for i in range(8)},
    **{f"s{i}": 16 + i for i in range(2, 12)},
    **{f"t{i}": 25 + i for i in range(3, 7)},
}


def parse_reg(tok: str) -> int:
    t = tok.strip().lower()
    if t in ABI_NAMES:
        return ABI_NAMES[t]
    m = re.fullmatch(r"x(\d+)", t)
    if m and int(m.group(1)) < 32:
        return int(m.group(1))
    raise ValueError(f"registro inválido {tok.strip()!r}")


def parse_int(tok: str) -> int:
    t = tok.strip().replace("_", "")
    if not re.fullmatch(r"[+-]?(0[xX][0-9a-fA-F]+|0[bB][01]+|\d+)", t):
        raise ValueError(f"número inválido {tok.strip()!r}")
    return int(t, 0)


LABEL_RE = re.compile(r"[A-Za-z_.][A-Za-z0-9_.]*")


def parse_mem(tok: str) -> Tuple[int, int]:
    """'imm(rs1)' o '(rs1)' -> (imm, rs1)."""
    m = re.fullmatch(r"\s*([^()]*?)\s*\(\s*([^()]+?)\s*\)\s*", tok)
    if not m:
        raise ValueError(f"se esperaba imm(rs1), llegó {tok.strip()!r}")
    imm = parse_int(m.group(1)) if m.group(1) else 0
    return imm, parse_reg(m.group(2))


# --------------------------------------------------------------------------
# Sentencias
# --------------------------------------------------------------------------

@dataclass
class Stmt:
    """Una instrucción (real) a codificar, con su origen en el fuente."""
    line: int               # número de línea en el .s
    src: str                # texto de la línea (para el listing)
    mnem: str
    ops: List[str]
    addr: int = 0


@dataclass
class Program:
    words: List[int]
    addrs: List[int]
    lines: List[int]        # línea del fuente de cada palabra
    srcs: List[str]         # texto de la instrucción de cada palabra
    labels: Dict[str, int]

    def hex_text(self) -> str:
        return "".join(f"{w:08x}\n" for w in self.words)

    def listing(self) -> str:
        out = []
        for a, w, n, s in zip(self.addrs, self.words, self.lines, self.srcs):
            out.append(f"{a:04x}  {w:08x}  {n:4d}  {s}")
        return "\n".join(out) + "\n"


def _strip_comment(line: str) -> str:
    for c in ("#", "//", ";"):
        i = line.find(c)
        if i >= 0:
            line = line[:i]
    return line.strip()


def _split_ops(rest: str) -> List[str]:
    rest = rest.strip()
    return [o.strip() for o in rest.split(",")] if rest else []


def _li_split(v: int) -> Tuple[int, int]:
    """Valor de 32 bits -> (hi20, lo12) tales que (hi20 << 12) + sext(lo12) == v."""
    v &= 0xFFFFFFFF
    lo = v & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((v - lo) >> 12) & 0xFFFFF
    return hi, lo


def _expand(mnem: str, ops: List[str]) -> List[Tuple[str, List[str]]]:
    """Expande pseudoinstrucciones a instrucciones reales (sin resolver labels).

    La cantidad de palabras que ocupa cada sentencia tiene que salir de acá,
    sin conocer los labels, para la primera pasada.
    """
    n = len(ops)

    def need(k):
        if n != k:
            raise ValueError(f"{mnem} lleva {k} operando{'s' if k != 1 else ''}, llegaron {n}")

    if mnem == "nop":
        need(0)
        return [("addi", ["x0", "x0", "0"])]
    if mnem in ("halt", "ebreak"):
        need(0)
        return [("ebreak", [])]
    if mnem == "mv":
        need(2)
        return [("addi", [ops[0], ops[1], "0"])]
    if mnem == "li":
        need(2)
        v = parse_int(ops[1])
        if not -(1 << 31) <= v <= 0xFFFFFFFF:
            raise ValueError(f"li: {v} no entra en 32 bits")
        if -2048 <= v <= 2047:
            return [("addi", [ops[0], "x0", str(v)])]
        hi, lo = _li_split(v)
        out = [("lui", [ops[0], str(hi)])]
        if lo:
            out.append(("addi", [ops[0], ops[0], str(lo)]))
        return out
    if mnem == "j":
        need(1)
        return [("jal", ["x0", ops[0]])]
    if mnem == "jal" and n == 1:
        return [("jal", ["ra", ops[0]])]
    if mnem == "jalr" and n == 1:
        return [("jalr", ["ra", "0(" + ops[0] + ")"])]
    if mnem == "ret":
        need(0)
        return [("jalr", ["x0", "0(ra)"])]
    if mnem in T.ISA:
        return [(mnem, ops)]
    raise ValueError(f"instrucción desconocida {mnem!r}")


def _resolve_target(tok: str, labels: Dict[str, int], pc: int) -> int:
    """Label u offset numérico -> offset en bytes relativo a pc."""
    t = tok.strip()
    if LABEL_RE.fullmatch(t):
        if t not in labels:
            raise ValueError(f"label no definido {t!r}")
        return labels[t] - pc
    return parse_int(t)


def _encode(st: Stmt, labels: Dict[str, int]) -> int:
    mnem, ops, pc = st.mnem, st.ops, st.addr
    if mnem == "ebreak":
        return T.HALT
    fmt = T.ISA[mnem][0]

    def need(k, forma):
        if len(ops) != k:
            raise ValueError(f"{mnem} espera {forma}")

    if fmt == "R":
        need(3, "rd, rs1, rs2")
        return T.encode(mnem, rd=parse_reg(ops[0]), rs1=parse_reg(ops[1]), rs2=parse_reg(ops[2]))
    if fmt == "I" and (mnem in T.LOADS or (mnem == "jalr" and len(ops) == 2)):
        need(2, "rd, imm(rs1)")
        imm, rs1 = parse_mem(ops[1])
        return T.encode(mnem, rd=parse_reg(ops[0]), rs1=rs1, imm=imm)
    if fmt == "I":
        need(3, "rd, rs1, imm")
        return T.encode(mnem, rd=parse_reg(ops[0]), rs1=parse_reg(ops[1]), imm=parse_int(ops[2]))
    if fmt == "S":
        need(2, "rs2, imm(rs1)")
        imm, rs1 = parse_mem(ops[1])
        return T.encode(mnem, rs2=parse_reg(ops[0]), rs1=rs1, imm=imm)
    if fmt == "B":
        need(3, "rs1, rs2, label")
        off = _resolve_target(ops[2], labels, pc)
        return T.encode(mnem, rs1=parse_reg(ops[0]), rs2=parse_reg(ops[1]), imm=off)
    if fmt == "U":
        need(2, "rd, imm20")
        return T.encode(mnem, rd=parse_reg(ops[0]), imm=parse_int(ops[1]))
    if fmt == "J":
        need(2, "rd, label")
        off = _resolve_target(ops[1], labels, pc)
        return T.encode(mnem, rd=parse_reg(ops[0]), imm=off)
    raise AssertionError(fmt)


def assemble(text: str, filename: str = "<entrada>") -> Program:
    """Ensambla el texto de un .s. Lanza AsmError con todos los errores."""
    errors: List[str] = []
    labels: Dict[str, int] = {}
    stmts: List[Stmt] = []

    def err(n, msg):
        errors.append(f"{filename}:{n}: {msg}")

    # Primera pasada: labels, expansión de pseudos y direcciones
    pc = 0
    for n, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw)
        while True:
            m = re.match(r"([^\s:]+)\s*:", line)
            if not m:
                break
            name = m.group(1)
            if not LABEL_RE.fullmatch(name):
                err(n, f"label inválido {name!r}")
            elif name in labels:
                err(n, f"label {name!r} definido dos veces")
            else:
                labels[name] = pc
            line = line[m.end():].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].lower()
        ops = _split_ops(parts[1] if len(parts) > 1 else "")
        if mnem.startswith("."):
            err(n, f"directiva no soportada {mnem!r}")
            continue
        try:
            expanded = _expand(mnem, ops)
        except ValueError as e:
            err(n, str(e))
            continue
        for real, real_ops in expanded:
            stmts.append(Stmt(n, raw.strip(), real, real_ops, pc))
            pc += 4

    if len(stmts) > MAX_WORDS:
        errors.append(f"{filename}: el programa ocupa {len(stmts)} palabras, la imem tiene {MAX_WORDS}")

    # Segunda pasada: codificación
    words = []
    for st in stmts:
        try:
            words.append(_encode(st, labels))
        except ValueError as e:
            err(st.line, f"{st.mnem}: {e}")

    if errors:
        raise AsmError(errors)
    if not words:
        raise AsmError([f"{filename}: el programa está vacío"])
    return Program(words, [s.addr for s in stmts], [s.line for s in stmts],
                   [s.src for s in stmts], labels)


def assemble_file(path: str) -> Program:
    with open(path, encoding="utf-8") as f:
        return assemble(f.read(), path)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Ensamblador RV32I del TP3")
    ap.add_argument("src", help="programa en assembly (.s)")
    ap.add_argument("-o", "--output", help="archivo .hex (por defecto, el .s con extensión .hex)")
    ap.add_argument("-l", "--listing", help="archivo de listing (dirección, palabra, fuente)")
    args = ap.parse_args(argv)

    try:
        prog = assemble_file(args.src)
    except AsmError as e:
        print(e, file=sys.stderr)
        return 1
    except OSError as e:
        print(f"no se pudo leer {args.src}: {e}", file=sys.stderr)
        return 1

    out = args.output or os.path.splitext(args.src)[0] + ".hex"
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(prog.hex_text())
    if args.listing:
        with open(args.listing, "w", encoding="utf-8", newline="\n") as f:
            f.write(prog.listing())
    print(f"{args.src}: {len(prog.words)} palabras -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
