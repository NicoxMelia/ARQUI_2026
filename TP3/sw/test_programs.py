"""Tests de los programas de prueba, de riscv_sim.py y de check_program.py.

Desde TP3/:  python -m unittest discover -s sw -v     (o make test-sw)

Para cada programa de programs/ verifica que el .hex esté al día con el .s,
que el simulador de referencia llegue al estado del .expected.json (que se
calculó a mano) y, si el programa es para el pipeline base, que no tenga
dependencias que necesiten forwarding.

Issue: TEST-1 (#18).
"""

import contextlib
import io
import json
import os
import tempfile
import unittest

import assembler as A
import check_program as C
import isa_table as T
import riscv_sim as S
from fake_serial import FakeSerial
from serial_link import DebugLink

# Instrucciones del pipeline base (hito M2): R, I aritmético-lógicas y lui
M2_MNEMS = {m for m, (fmt, op, _, _) in T.ISA.items() if op in (T.OP_R, T.OP_I, T.OP_LUI)}


def sim(src):
    return S.run(A.assemble(src).words)


class TestProgramas(unittest.TestCase):

    def setUp(self):
        self.bases = C.all_programs()

    def test_hay_programas(self):
        self.assertGreaterEqual(len(self.bases), 7)

    def test_hex_al_dia(self):
        for b in self.bases:
            with self.subTest(programa=os.path.basename(b)):
                prog = A.assemble_file(b + ".s")
                with open(b + ".hex") as f:
                    self.assertEqual(f.read(), prog.hex_text(),
                                     "regenerar con python sw/assembler.py " + b + ".s")

    def test_referencia_coincide_con_esperado(self):
        for b in self.bases:
            with self.subTest(programa=os.path.basename(b)):
                exp = C.load_expected(b + ".expected.json")
                obs = C.run_reference(C.read_hex(b + ".hex"))
                self.assertEqual(C.compare(exp, obs), [])

    def test_sin_forwarding_no_tiene_dependencias_cercanas(self):
        for b in self.bases:
            exp = C.load_expected(b + ".expected.json")
            if not exp.sin_forwarding:
                continue
            with self.subTest(programa=os.path.basename(b)):
                prog = A.assemble_file(b + ".s")
                hz = S.raw_hazards(prog.words)
                msg = ", ".join(f"línea {prog.lines[j]} lee x{r} de la línea {prog.lines[i]}"
                                for i, j, r in hz)
                self.assertEqual(hz, [], msg)

    def test_cubren_las_instrucciones_del_pipeline_base(self):
        usadas = set()
        for b in self.bases:
            usadas |= {S.decode(w).mnem for w in C.read_hex(b + ".hex")}
        self.assertEqual(M2_MNEMS - usadas, set())
        self.assertIn("ebreak", usadas)

    def test_esperados_bien_formados(self):
        for b in self.bases:
            with self.subTest(programa=os.path.basename(b)):
                with open(b + ".expected.json") as f:
                    d = json.load(f)
                self.assertLessEqual(set(d), {"descripcion", "sin_forwarding", "halted",
                                              "illegal", "regs", "dmem"})
                self.assertTrue(d.get("descripcion"))


class TestReferencia(unittest.TestCase):

    def test_decode_de_las_32(self):
        for m, (fmt, *_ ) in T.ISA.items():
            with self.subTest(m=m):
                imm = {"U": 0x12345, "B": -8, "J": 2048}.get(fmt, 3 if m in T.SHIFT_IMM else -5)
                i = S.decode(T.encode(m, rd=1, rs1=2, rs2=3, imm=imm))
                self.assertEqual(i.mnem, m)
                if fmt in ("I", "S", "B", "J"):
                    self.assertEqual(i.imm, imm)
                if fmt == "U":
                    self.assertEqual(i.imm, 0x12345000)

    def test_ilegales(self):
        for w in (0x00000000, 0xFFFFFFFF, 0x00000073,          # ecall
                  0x002081B3 | (1 << 25),                       # add con funct7 = 1
                  0x01F11093 | (1 << 30) | (1 << 31),           # slli con funct7 raro
                  0x00003003,                                   # ld (RV64)
                  0x00009067):                                  # jalr con funct3 = 1
            self.assertEqual(S.decode(w).mnem, "illegal", hex(w))
        s = S.run([T.NOP])                                      # cae en el relleno con ceros
        self.assertTrue(s.halted and s.illegal)
        self.assertEqual(s.pc, 4)

    def test_halt(self):
        s = sim("addi x1, x0, 1\nhalt\naddi x1, x0, 2")
        self.assertTrue(s.halted)
        self.assertFalse(s.illegal)
        self.assertEqual(s.regs[1], 1)

    def test_memoria(self):
        s = sim("""
            li   x1, 0x80FF7F01
            addi x2, x0, 16
            sw   x1, 0(x2)
            sb   x1, 5(x2)       # byte 21
            sh   x1, 10(x2)      # bytes 26-27
            lb   x3, 1(x2)       # 0x7F
            lb   x4, 3(x2)       # 0x80 -> negativo
            lbu  x5, 3(x2)
            lh   x6, 2(x2)       # 0x80FF -> negativo
            lhu  x7, 2(x2)
            lw   x8, 0(x2)
            halt
        """)
        self.assertEqual(s.regs[3:9], [0x7F, 0xFFFFFF80, 0x80, 0xFFFF80FF, 0x80FF, 0x80FF7F01])
        self.assertEqual(s.dmem_words(), [0, 0, 0, 0, 0x80FF7F01, 0x0100, 0x7F010000])
        self.assertEqual(s.dmem_hwm, 28)

    def test_saltos(self):
        s = sim("""
                addi x5, x0, 3
            bucle:
                addi x2, x2, 10
                addi x5, x5, -1
                bne  x5, x0, bucle
                beq  x0, x0, salto
                addi x9, x0, 99      # no se ejecuta
            salto:
                jal  ra, func
                halt
            func:
                addi x3, x0, 7
                jalr x0, 0(ra)
        """)
        # ra = dirección del halt (0x1C)
        self.assertEqual((s.regs[2], s.regs[3], s.regs[5], s.regs[9], s.regs[1]), (30, 7, 0, 0, 0x1C))

    def test_errores_de_memoria_y_bucle_infinito(self):
        with self.assertRaises(S.SimError):
            sim("addi x1, x0, 2\nlw x2, 0(x1)\nhalt")           # desalineado
        with self.assertRaises(S.SimError):
            sim("lui x1, 1\nsw x0, 0(x1)\nhalt")                # fuera de la dmem
        with self.assertRaises(S.SimError):
            S.run(A.assemble("a: j a").words, max_steps=100)

    def test_raw_hazards(self):
        w = A.assemble("""
            addi x1, x0, 1
            add  x2, x1, x1      # x1 a distancia 1
            nop
            add  x4, x2, x0      # x2 a distancia 2
            add  x3, x2, x0      # x2 a distancia 3: lo resuelve el bypass del banco
            addi x0, x0, 1
            add  x5, x0, x0      # x0 no cuenta
            nop
            sw   x5, 0(x0)       # x5 a distancia 2 (el store lee rs2)
            halt
        """).words
        self.assertEqual(S.raw_hazards(w), [(0, 1, 1), (1, 3, 2), (6, 8, 5)])


class TestChecker(unittest.TestCase):

    def exp(self, **kw):
        return C.Expected(regs=kw.get("regs", {}), dmem=kw.get("dmem", {}))

    def test_compare(self):
        regs = [0] * 32
        regs[5] = 7
        self.assertEqual(C.compare(self.exp(regs={5: 7}), C.Observed(regs, halted=True)), [])
        d = C.compare(self.exp(regs={5: 8}), C.Observed(regs, halted=False, illegal=True))
        self.assertEqual(d, ["x5: obtenido 0x00000007, esperado 0x00000008",
                             "halted: obtenido 0, esperado 1", "illegal: obtenido 1, esperado 0"])
        # Registros no listados tienen que valer 0
        self.assertEqual(len(C.compare(self.exp(), C.Observed(regs))), 1)

    def test_compare_dmem(self):
        regs = [0] * 32
        self.assertEqual(C.compare(self.exp(dmem={4: 1}), C.Observed(regs, {0: 0, 4: 1})), [])
        d = C.compare(self.exp(dmem={4: 1, 8: 2}), C.Observed(regs, {0: 3, 4: 1}))
        self.assertEqual(d, ["dmem[0x000]: obtenido 0x00000003, esperado 0x00000000",
                             "dmem[0x008]: no está en el volcado, esperado 0x00000002"])

    def test_parse_dump(self):
        txt = "# volcado\nhalted 1\nillegal 0\n" + "".join(f"x{i} {i:08x}\n" for i in range(32)) \
              + "dmem 0004 deadbeef // comentario\n"
        o = C.parse_dump(txt)
        self.assertEqual(o.regs, list(range(32)))
        self.assertEqual(o.dmem, {4: 0xDEADBEEF})
        self.assertEqual((o.halted, o.illegal), (True, False))
        self.assertIsNone(C.parse_dump(txt.replace("halted 1\n", "")).halted)

    def test_parse_dump_errores(self):
        with self.assertRaisesRegex(C.CheckError, "faltan registros: x31"):
            C.parse_dump("".join(f"x{i} 0\n" for i in range(31)))
        with self.assertRaisesRegex(C.CheckError, ":2: número hexa"):
            C.parse_dump("x0 0\nx1 zz\n")
        with self.assertRaisesRegex(C.CheckError, ":1: línea inválida"):
            C.parse_dump("pc 0 0\n")

    def test_load_expected_errores(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "e.json")
            for contenido, msg in (('{"regs": {"x32": 1}}', "registro inválido"),
                                   ('{"regs": {"x0": 1}}', "x0 siempre vale 0"),
                                   ('{"regs": {"x1": "0xZZ"}}', "número inválido"),
                                   ('{"dmem": {"0x2": 1}}', "no alineada"),
                                   ('{"regs": ', "")):
                with open(p, "w") as f:
                    f.write(contenido)
                with self.assertRaisesRegex(C.CheckError, msg):
                    C.load_expected(p)

    def test_placa_con_fake_serial(self):
        # FakeSerial emula al core_stub: x_i = i, dmem_hwm = 0
        link = DebugLink(ser=FakeSerial())
        obs = C.run_board([T.NOP, T.NOP, T.HALT], link, timeout=1.0)
        self.assertEqual(obs.regs, list(range(32)))
        self.assertEqual((obs.halted, obs.illegal, obs.dmem), (True, False, {}))

    def test_cli(self):
        base = os.path.join(C.PROGRAMS_DIR, "basico")
        with tempfile.TemporaryDirectory() as d:
            dump = os.path.join(d, "dump.txt")
            regs = {1: 5, 2: 3, 3: 0xFFFFFFFF, 4: 8, 5: 2, 6: 0xFFFFFFFE, 7: 4}
            with open(dump, "w") as f:
                f.write("halted 1\n" + "".join(f"x{i} {regs.get(i, 0):08x}\n" for i in range(32)))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(C.main([base + ".s", "--dump", dump]), 0)
                self.assertEqual(C.main(["--all"]), 0)
            self.assertIn("OK    basico", out.getvalue())

            with open(dump, "a") as f:
                f.write("x9 00000001\n")                     # x9 tendría que valer 0
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(C.main([base, "--dump", dump]), 1)
            self.assertIn("x9: obtenido 0x00000001, esperado 0x00000000", out.getvalue())


if __name__ == "__main__":
    unittest.main()
