"""Compara el estado final de un programa contra su .expected.json.

Cada programa de programs/ tiene tres archivos con el mismo nombre base:
  <nombre>.s              fuente
  <nombre>.hex            imagen ensamblada (python sw/assembler.py <nombre>.s)
  <nombre>.expected.json  estado final esperado (formato en programs/README.md)

El estado final puede salir de tres lugares:

  python sw/check_program.py programs/basico --port COM5      # placa (Linux: /dev/ttyUSB1)
  python sw/check_program.py programs/basico --dump out.txt   # volcado de simulación
  python sw/check_program.py --all                            # simulador de referencia

Con --port carga el .hex, hace RUN hasta HALT, toma los registros del DUMP y
lee la dmem con READ_DMEM (hasta dmem_hwm). Con --dump lee el archivo de
texto que escribe el testbench del core (formato en programs/README.md). Sin
--port ni --dump usa riscv_sim.py, que sirve para validar el propio
.expected.json.

Sale con 0 si todos los programas coinciden y con 1 si alguno falla.

Issue: TEST-1 (#18).
"""

import argparse
import glob
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import riscv_sim

PROGRAMS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "programs")
NUM_REGS = 32


class CheckError(Exception):
    """Archivo de programa, de esperados o de volcado mal formado."""


# --------------------------------------------------------------------------
# Estado observado y esperado
# --------------------------------------------------------------------------

@dataclass
class Observed:
    regs: List[int]
    dmem: Dict[int, int] = field(default_factory=dict)  # dirección de byte -> palabra
    halted: Optional[bool] = None                       # None = no se sabe
    illegal: Optional[bool] = None


@dataclass
class Expected:
    regs: Dict[int, int]            # los que no figuran valen 0
    dmem: Dict[int, int]            # las palabras que no figuran valen 0
    halted: bool = True
    illegal: bool = False
    sin_forwarding: bool = False    # corre en el pipeline base (M2)


def _num(v, where: str) -> int:
    if isinstance(v, bool):
        raise CheckError(f"{where}: se esperaba un número, llegó {v!r}")
    if isinstance(v, int):
        return v & 0xFFFFFFFF
    if isinstance(v, str):
        try:
            return int(v, 0) & 0xFFFFFFFF
        except ValueError:
            pass
    raise CheckError(f"{where}: número inválido {v!r}")


def _reg_index(name: str, where: str) -> int:
    n = name.strip().lower()
    if n.startswith("x") and n[1:].isdigit() and int(n[1:]) < NUM_REGS:
        return int(n[1:])
    raise CheckError(f"{where}: registro inválido {name!r} (usar x0..x31)")


def load_expected(path: str) -> Expected:
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise CheckError(f"{path}: {e}") from e
    regs = {_reg_index(k, path): _num(v, f"{path}: {k}") for k, v in d.get("regs", {}).items()}
    if regs.get(0, 0) != 0:
        raise CheckError(f"{path}: x0 siempre vale 0")
    dmem = {}
    for k, v in d.get("dmem", {}).items():
        a = _num(k, f"{path}: dmem")
        if a % 4:
            raise CheckError(f"{path}: dirección de dmem no alineada: {k}")
        dmem[a] = _num(v, f"{path}: dmem[{k}]")
    return Expected(regs, dmem, bool(d.get("halted", True)), bool(d.get("illegal", False)),
                    bool(d.get("sin_forwarding", False)))


def compare(exp: Expected, obs: Observed) -> List[str]:
    """Lista de diferencias (vacía si coincide)."""
    diffs = []
    for r in range(NUM_REGS):
        e, o = exp.regs.get(r, 0), obs.regs[r]
        if e != o:
            diffs.append(f"x{r}: obtenido 0x{o:08X}, esperado 0x{e:08X}")
    for a in sorted(set(exp.dmem) | set(obs.dmem)):
        e, o = exp.dmem.get(a, 0), obs.dmem.get(a)
        if o is None:
            diffs.append(f"dmem[0x{a:03X}]: no está en el volcado, esperado 0x{e:08X}")
        elif e != o:
            diffs.append(f"dmem[0x{a:03X}]: obtenido 0x{o:08X}, esperado 0x{e:08X}")
    for name in ("halted", "illegal"):
        o = getattr(obs, name)
        if o is not None and o != getattr(exp, name):
            diffs.append(f"{name}: obtenido {int(o)}, esperado {int(getattr(exp, name))}")
    return diffs


# --------------------------------------------------------------------------
# Fuentes del estado final
# --------------------------------------------------------------------------

def read_hex(path: str) -> List[int]:
    if not os.path.exists(path):
        raise CheckError(f"no existe {path}: ensamblar con python sw/assembler.py {path[:-4]}.s")
    from serial_link import read_hex as _read_hex      # misma lectura que usa la placa
    return _read_hex(path)


def run_reference(words: List[int]) -> Observed:
    s = riscv_sim.run(words)
    return Observed(list(s.regs), {4 * i: w for i, w in enumerate(s.dmem_words())},
                    s.halted, s.illegal)


def run_board(words: List[int], link, timeout: float) -> Observed:
    """LOAD + RUN hasta HALT + READ_DMEM hasta dmem_hwm, con un DebugLink abierto."""
    link.load(words)
    d = link.run(timeout=timeout)
    dmem = link.read_dmem(0, 0)
    return Observed(list(d.regs), {4 * i: w for i, w in enumerate(dmem)},
                    d.status.halted, d.status.illegal)


def parse_dump(text: str, where: str = "<volcado>") -> Observed:
    """Volcado de simulación: líneas "x<n> <hex>", "dmem <addr> <hex>",
    "halted 0|1", "illegal 0|1". Comentarios con # o //. Tienen que estar
    los 32 registros."""
    regs: Dict[int, int] = {}
    obs = Observed(regs=[])
    for n, line in enumerate(text.splitlines(), 1):
        line = line.split("#")[0].split("//")[0].strip()
        if not line:
            continue
        tok = line.split()
        here = f"{where}:{n}"
        try:
            if tok[0].lower().startswith("x") and len(tok) == 2:
                regs[_reg_index(tok[0], here)] = int(tok[1], 16)
            elif tok[0] == "dmem" and len(tok) == 3:
                obs.dmem[int(tok[1], 16)] = int(tok[2], 16)
            elif tok[0] in ("halted", "illegal") and len(tok) == 2 and tok[1] in ("0", "1"):
                setattr(obs, tok[0], tok[1] == "1")
            else:
                raise CheckError(f"{here}: línea inválida {line!r}")
        except ValueError:
            raise CheckError(f"{here}: número hexa inválido en {line!r}") from None
    missing = [f"x{r}" for r in range(NUM_REGS) if r not in regs]
    if missing:
        raise CheckError(f"{where}: faltan registros: {', '.join(missing)}")
    obs.regs = [regs[r] for r in range(NUM_REGS)]
    return obs


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def program_base(arg: str) -> str:
    """'programs/x', 'programs/x.s', '.hex' o '.expected.json' -> 'programs/x'."""
    for ext in (".expected.json", ".hex", ".s"):
        if arg.endswith(ext):
            return arg[:-len(ext)]
    return arg


def all_programs() -> List[str]:
    return sorted(p[:-len(".expected.json")]
                  for p in glob.glob(os.path.join(PROGRAMS_DIR, "*.expected.json")))


def check_one(base: str, args) -> bool:
    name = os.path.basename(base)
    try:
        exp = load_expected(base + ".expected.json")
        if args.dump:
            with open(args.dump, encoding="utf-8") as f:
                obs = parse_dump(f.read(), args.dump)
            source = args.dump
        elif args.port:
            from serial_link import DebugLink
            with DebugLink(args.port, args.baud) as link:
                obs = run_board(read_hex(base + ".hex"), link, args.timeout)
            source = args.port
        else:
            obs = run_reference(read_hex(base + ".hex"))
            source = "referencia"
    except (CheckError, riscv_sim.SimError, OSError, ValueError) as e:
        print(f"ERROR {name}: {e}")
        return False
    except Exception as e:                      # errores de la placa (LinkError, NACK)
        print(f"ERROR {name} ({type(e).__name__}): {e}")
        return False

    diffs = compare(exp, obs)
    if diffs:
        print(f"FALLA {name} ({source}): {len(diffs)} diferencia(s)")
        for d in diffs:
            print(f"    {d}")
        return False
    print(f"OK    {name} ({source})")
    return True


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Compara el estado final de un programa con su .expected.json")
    ap.add_argument("programs", nargs="*", help="programas (programs/x, .s, .hex o .expected.json)")
    ap.add_argument("--all", action="store_true", help="todos los programas de programs/")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--port", help="puerto serie de la placa (COM5, /dev/ttyUSB1)")
    src.add_argument("--dump", help="volcado de simulación (un solo programa)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=5.0, help="segundos máximos de RUN (placa)")
    args = ap.parse_args(argv)

    bases = [program_base(p) for p in args.programs] + (all_programs() if args.all else [])
    if not bases:
        ap.error("indicar uno o más programas, o --all")
    if args.dump and len(bases) != 1:
        ap.error("--dump compara un solo programa")

    results = [check_one(b, args) for b in bases]
    if len(results) > 1:
        print(f"\n{sum(results)}/{len(results)} programas OK")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
