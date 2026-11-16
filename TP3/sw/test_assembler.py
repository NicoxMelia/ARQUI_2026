"""Tests del ensamblador (assembler.py).

Desde TP3/:  python -m unittest discover -s sw -v     (o make test-sw)

Los valores esperados se verificaron desensamblando con Capstone 5.0
(CS_ARCH_RISCV, modo RV32), una referencia independiente de isa_table.py.

Issue: SW-1 (#16).
"""

import contextlib
import io
import os
import tempfile
import unittest

import assembler as A
import isa_table as T


def asm(text):
    return A.assemble(text).words


def asm1(line):
    words = asm(line)
    assert len(words) == 1, words
    return words[0]


# (fuente, palabra esperada). Cubre las 32 instrucciones, con registros por
# número y por nombre ABI e inmediatos en los extremos de su rango.
VECTORES = [
    # R
    ("add  x3, x1, x2",      0x002081B3),
    ("sub  t0, a0, a1",      0x40B502B3),
    ("sll  s1, s2, s3",      0x013914B3),
    ("slt  a0, t5, t6",      0x01FF2533),
    ("sltu x31, x30, x29",   0x01DF3FB3),
    ("xor  x7, x8, x9",      0x009443B3),
    ("srl  x10, x11, x12",   0x00C5D533),
    ("sra  x13, x14, x15",   0x40F756B3),
    ("or   x16, x17, x18",   0x0128E833),
    ("and  x19, x20, x21",   0x015A79B3),
    # I aritmético-lógicas
    ("addi x1, x0, -1",      0xFFF00093),
    ("addi x1, x2, 2047",    0x7FF10093),
    ("addi x1, x2, -2048",   0x80010093),
    ("slti x5, x6, -7",      0xFF932293),
    ("sltiu x5, x6, -1",     0xFFF33293),
    ("xori x5, x6, 0x7ff",   0x7FF34293),
    ("ori  x5, x6, 0x123",   0x12336293),
    ("andi x5, x6, 255",     0x0FF37293),
    ("slli x1, x2, 31",      0x01F11093),
    ("srli x1, x2, 1",       0x00115093),
    ("srai x1, x2, 31",      0x41F15093),
    # Loads
    ("lb   x1, -1(x2)",      0xFFF10083),
    ("lh   x1, 2(x2)",       0x00211083),
    ("lw   x1, 2047(sp)",    0x7FF12083),
    ("lbu  x1, -2048(x2)",   0x80014083),
    ("lhu  x1, (x2)",        0x00015083),
    # jalr (dos sintaxis)
    ("jalr x1, 4(x2)",       0x004100E7),
    ("jalr x0, x1, 0",       0x00008067),
    # S
    ("sb   x5, -1(x6)",      0xFE530FA3),
    ("sh   x5, 2(x6)",       0x00531123),
    ("sw   x5, 2047(x6)",    0x7E532FA3),
    # U
    ("lui  x1, 0xFFFFF",     0xFFFFF0B7),
    ("lui  x1, 0",           0x000000B7),
    # Especiales
    ("ebreak",               0x00100073),
]


class TestInstrucciones(unittest.TestCase):

    def test_vectores(self):
        for src, exp in VECTORES:
            with self.subTest(src=src):
                self.assertEqual(asm1(src), exp, f"{asm1(src):08x} != {exp:08x}")

    def test_cubre_las_32(self):
        mnems = {src.split()[0] for src, _ in VECTORES} | {"beq", "bne", "jal"}
        self.assertEqual(mnems - {"ebreak"}, set(T.ISA))

    def test_saltos_con_labels(self):
        # Mismo programa que se verificó con Capstone: offsets hacia atrás y adelante
        src = "start:\n" + "nop\n" * 31 + """
            beq  x1, x2, start      # 0x7c -> 0x00: -0x7c
            bne  x1, x2, end        # 0x80 -> 0x94: +0x14
            nop
            nop
            jal  x1, start          # 0x8c -> 0x00: -0x8c
            jal  x0, end            # 0x90 -> 0x94: +4
            end: ebreak
        """
        w = asm(src)
        self.assertEqual(w[31:], [0xF82082E3, 0x00209A63, T.NOP, T.NOP,
                                  0xF75FF0EF, 0x0040006F, T.HALT])

    def test_saltos_con_offset_numerico(self):
        self.assertEqual(asm1("beq x1, x2, -124"), 0xF82082E3)
        self.assertEqual(asm1("jal x0, 4"), 0x0040006F)
        self.assertEqual(asm1("beq x0, x0, 0"), 0x00000063)       # salto a sí mismo

    def test_extremos_de_rango_de_saltos(self):
        self.assertEqual(asm1("beq x0, x0, 4094"), T.encode("beq", imm=4094))
        self.assertEqual(asm1("beq x0, x0, -4096"), T.encode("beq", imm=-4096))
        self.assertEqual(asm1("jal x0, -1048576"), T.encode("jal", imm=-1048576))


class TestPseudo(unittest.TestCase):

    def test_nop_halt_mv(self):
        self.assertEqual(asm1("nop"), 0x00000013)
        self.assertEqual(asm1("halt"), 0x00100073)
        self.assertEqual(asm1("HALT"), 0x00100073)
        self.assertEqual(asm1("mv a0, sp"), T.encode("addi", rd=10, rs1=2, imm=0))

    def test_j_ret_jal_jalr_cortos(self):
        self.assertEqual(asm("a: j a"), [T.encode("jal", rd=0, imm=0)])
        self.assertEqual(asm("a: jal a"), [T.encode("jal", rd=1, imm=0)])
        self.assertEqual(asm1("ret"), 0x00008067)
        self.assertEqual(asm1("jalr t0"), T.encode("jalr", rd=1, rs1=5, imm=0))

    def test_li_chico_es_un_addi(self):
        self.assertEqual(asm("li x5, -2048"), [T.encode("addi", rd=5, imm=-2048)])
        self.assertEqual(asm("li x5, 2047"), [T.encode("addi", rd=5, imm=2047)])

    def test_li_grande(self):
        # lui + addi (con corrección cuando el bit 11 está en 1) o solo lui
        casos = {
            0x12345678: [T.encode("lui", rd=5, imm=0x12345), T.encode("addi", rd=5, rs1=5, imm=0x678)],
            0xDEADBEEF: [T.encode("lui", rd=5, imm=0xDEADC), T.encode("addi", rd=5, rs1=5, imm=-0x111)],
            0x00001000: [T.encode("lui", rd=5, imm=0x1)],
            0x00000800: [T.encode("lui", rd=5, imm=0x1), T.encode("addi", rd=5, rs1=5, imm=-0x800)],
            -1 << 31:   [T.encode("lui", rd=5, imm=0x80000)],
        }
        for v, exp in casos.items():
            with self.subTest(v=hex(v)):
                self.assertEqual(asm(f"li x5, {v}"), exp)

    def test_li_reconstruye_el_valor(self):
        for v in (0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFF800, 0x000007FF, 0x00000FFF, 0xABCDE7FF, -2049):
            hi, lo = A._li_split(v)
            self.assertEqual(((hi << 12) + lo) & 0xFFFFFFFF, v & 0xFFFFFFFF, hex(v))

    def test_labels_despues_de_li_grande(self):
        # li de dos palabras corre los labels siguientes
        p = A.assemble("li x1, 0x12345678\nfin: halt")
        self.assertEqual(p.labels["fin"], 8)


class TestSintaxis(unittest.TestCase):

    def test_comentarios_y_labels(self):
        src = """
            # comentario de línea
            inicio:                 // label solo
            addi x1, x0, 1          ; comentario con punto y coma
            otro: siguiente: addi x2, x0, 2   # dos labels en la línea
            ADDI X3, ZERO, 3        # mayúsculas
            beq x0, x0, otro
        """
        p = A.assemble(src)
        self.assertEqual(p.labels, {"inicio": 0, "otro": 4, "siguiente": 4})
        self.assertEqual(p.words[2], T.encode("addi", rd=3, imm=3))
        self.assertEqual(p.words[3], T.encode("beq", imm=-8))

    def test_nombres_abi(self):
        nombres = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
                   "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
                   "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
                   "t3", "t4", "t5", "t6"]
        for i, n in enumerate(nombres):
            self.assertEqual(A.parse_reg(n), i, n)
            self.assertEqual(A.parse_reg(f"x{i}"), i)
        self.assertEqual(A.parse_reg("fp"), 8)

    def test_formatos_de_numeros(self):
        self.assertEqual(asm1("addi x1, x0, 0x10"), asm1("addi x1, x0, 16"))
        self.assertEqual(asm1("addi x1, x0, 0b101"), asm1("addi x1, x0, 5"))
        self.assertEqual(asm1("addi x1, x0, -0x1"), asm1("addi x1, x0, -1"))
        self.assertEqual(asm1("addi x1, x0, +7"), asm1("addi x1, x0, 7"))
        self.assertEqual(asm1("lw x1, 0x10( sp )"), asm1("lw x1, 16(x2)"))

    def test_hex_y_listing(self):
        p = A.assemble("addi x1, x0, 5\nhalt  # fin\n")
        self.assertEqual(p.hex_text(), "00500093\n00100073\n")
        self.assertEqual(p.listing(), "0000  00500093     1  addi x1, x0, 5\n"
                                      "0004  00100073     2  halt  # fin\n")


class TestErrores(unittest.TestCase):

    def assertAsmError(self, src, *fragmentos):
        with self.assertRaises(A.AsmError) as cm:
            A.assemble(src, "p.s")
        msg = str(cm.exception)
        for f in fragmentos:
            self.assertIn(f, msg)
        return cm.exception

    def test_errores_con_numero_de_linea(self):
        self.assertAsmError("nop\nfoo x1, x2", "p.s:2:", "desconocida", "'foo'")
        self.assertAsmError("nop\nnop\nadd x1, x2, x32", "p.s:3:", "registro inválido 'x32'")
        self.assertAsmError("addi x1, x0, 2048", "p.s:1:", "fuera de rango")
        self.assertAsmError("addi x1, x0, -2049", "fuera de rango")
        self.assertAsmError("slli x1, x1, 32", "fuera de rango")
        self.assertAsmError("lui x1, 0x100000", "fuera de rango")
        self.assertAsmError("lui x1, -1", "fuera de rango")
        self.assertAsmError("addi x1, x0, 12abc", "número inválido")

    def test_operandos(self):
        self.assertAsmError("add x1, x2", "rd, rs1, rs2")
        self.assertAsmError("lw x1, x2", "imm(rs1)")
        self.assertAsmError("sw x1, 4", "imm(rs1)")
        self.assertAsmError("nop x1", "nop lleva 0 operandos")
        self.assertAsmError("li x1", "li lleva 2 operandos")
        self.assertAsmError("li x1, 0x100000000", "no entra en 32 bits")

    def test_labels(self):
        self.assertAsmError("beq x0, x0, nada", "label no definido 'nada'")
        self.assertAsmError("a: nop\na: nop", "p.s:2:", "definido dos veces")
        self.assertAsmError("1a: nop", "label inválido")

    def test_saltos_fuera_de_rango_o_impares(self):
        self.assertAsmError("beq x0, x0, 4096", "fuera de rango")
        self.assertAsmError("beq x0, x0, 3", "no alineado")
        self.assertAsmError("jal x0, 1048576", "fuera de rango")

    def test_reporta_todos_los_errores(self):
        e = self.assertAsmError("foo\nnop\nadd x1, x2, x99\nbeq x0, x0, nada", "p.s:1:", "p.s:3:", "p.s:4:")
        self.assertEqual(len(e.errors), 3)

    def test_vacio_directivas_y_tamano(self):
        self.assertAsmError("# nada\n", "vacío")
        self.assertAsmError(".text\nnop", "directiva no soportada")
        self.assertAsmError("nop\n" * 1025, "1025 palabras")


class TestCLI(unittest.TestCase):

    def setUp(self):
        quiet = contextlib.ExitStack()
        quiet.enter_context(contextlib.redirect_stdout(io.StringIO()))
        quiet.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.addCleanup(quiet.close)

    def test_genera_hex_y_listing(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "p.s")
            with open(src, "w") as f:
                f.write("addi x1, x0, 5\nhalt\n")
            self.assertEqual(A.main([src, "-l", os.path.join(d, "p.lst")]), 0)
            with open(os.path.join(d, "p.hex")) as f:
                self.assertEqual(f.read(), "00500093\n00100073\n")
            self.assertTrue(os.path.exists(os.path.join(d, "p.lst")))

    def test_error_devuelve_1_y_no_escribe(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "p.s")
            with open(src, "w") as f:
                f.write("foo\n")
            self.assertEqual(A.main([src]), 1)
            self.assertFalse(os.path.exists(os.path.join(d, "p.hex")))


if __name__ == "__main__":
    unittest.main()
