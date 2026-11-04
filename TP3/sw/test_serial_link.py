"""Tests de protocol.py, serial_link.py y fake_serial.py (sin placa).

Desde TP3/:  python -m unittest discover -s sw -v     (o make test-sw)

Issue: SW-2 (#17).
"""

import os
import tempfile
import unittest

import protocol as P
from fake_serial import EBREAK, FakeSerial
from serial_link import DebugLink, LinkError, ResponseTimeout, read_frame, read_hex

NOP = 0x00000013
PROG_A = [0x00100093, 0x00200113, 0x00300193, 0x00400213, EBREAK]


class TestProtocolo(unittest.TestCase):
    """Ejemplos de doc/protocolo_uart.md, sección 6."""

    def test_load_del_documento(self):
        words = [0x00500093, 0x00308113, 0x00100073]
        self.assertEqual(P.encode_load(words), bytes.fromhex(
            "02 0300 93005000 13813000 73001000"))
        self.assertEqual(P.load_checksum(words), 0x02)
        self.assertEqual(P.frame_load_ack(3, 0x02).encode(), bytes.fromhex("AA 10 0400 02 0300 02"))
        self.assertEqual(P.parse_load_ack(P.frame_load_ack(3, 0x02)), (3, 0x02))

    def test_ack_y_nack(self):
        self.assertEqual(P.frame_ack(P.CMD_PING).encode(), bytes.fromhex("AA 10 0100 01"))
        nack = P.Frame(P.T_NACK, bytes.fromhex("7F 01"))
        self.assertEqual(nack.encode(), bytes.fromhex("AA 11 0200 7F 01"))
        with self.assertRaises(P.NackError) as cm:
            P.parse_ack(nack, P.CMD_PING)
        self.assertEqual((cm.exception.cmd, cm.exception.code), (0x7F, P.E_UNKNOWN_CMD))
        self.assertIn("UNKNOWN_CMD", str(cm.exception))

    def test_read_dmem(self):
        self.assertEqual(P.encode_read_dmem(0, 4), bytes.fromhex("08 0000 0400"))
        self.assertEqual(P.encode_read_dmem(0x10, 0), bytes.fromhex("08 1000 0000"))
        for addr, count in ((2, 1), (4092, 2), (4096, 0), (-4, 1)):
            with self.assertRaises(ValueError):
                P.encode_read_dmem(addr, count)

    def test_validacion_de_programa(self):
        with self.assertRaises(ValueError):
            P.encode_load([])
        with self.assertRaises(ValueError):
            P.encode_load([0] * 1025)
        with self.assertRaises(ValueError):
            P.encode_load([1 << 32])
        self.assertEqual(len(P.encode_load([0] * 1024)), 3 + 4096)

    def test_dump_campos(self):
        """Cada campo de los latches sale de los bits de interfaz_core.md."""
        id_ex = (0x11111111 | (0x22222222 << 32) | (0x33333333 << 64) | (0xFFFFF800 << 96)
                 | (1 << 128) | (2 << 133) | (31 << 138) | (0b101 << 143) | (0b1101 << 146)
                 | (1 << 150) | (1 << 152) | (1 << 155) | (1 << 156))
        ex_mem = 0xAAAA5555 | (0x12345678 << 32) | (7 << 64) | (0b010 << 69) | (1 << 73) | (1 << 74)
        mem_wb = 0xCAFEBABE | (0x00000FFC << 32) | (9 << 64) | (0b100 << 69) | (1 << 72) | (1 << 73)
        if_id = (0x00100073 << 32) | 0x40
        status = P.Status(True, False, False, [True, True, False, True]).to_byte()
        regs = [(i * 0x01010101) & 0xFFFFFFFF for i in range(32)]
        raw = P.build_dump_payload(status, 0x44, regs, if_id, id_ex, ex_mem, mem_wb)
        self.assertEqual(len(raw), P.DUMP_LEN)

        d = P.parse_dump(P.Frame(P.T_DUMP, raw))
        self.assertEqual(status, 0b1011001)
        self.assertEqual(d.status, P.Status(True, False, False, [True, True, False, True]))
        self.assertEqual(d.pc, 0x44)
        self.assertEqual(d.regs, regs)
        self.assertEqual(d.if_id, P.IfId(pc=0x40, instr=0x00100073))
        self.assertEqual(d.id_ex, P.IdEx(
            pc=0x11111111, rs1_val=0x22222222, rs2_val=0x33333333, imm=0xFFFFF800,
            rs1=1, rs2=2, rd=31, funct3=0b101, alu_op=0b1101, reg_write=True,
            mem_read=False, mem_write=True, branch=False, jal=False, jalr=True,
            alu_src_imm=True))
        self.assertEqual(d.ex_mem, P.ExMem(0xAAAA5555, 0x12345678, 7, 0b010, False, True, True))
        self.assertEqual(d.mem_wb, P.MemWb(0xCAFEBABE, 0xFFC, 9, 0b100, True, True))
        # Offsets fijos del formato: IF/ID empieza en el byte 133
        self.assertEqual(raw[133:137], (0x40).to_bytes(4, "little"))
        self.assertEqual(raw[137:141], (0x00100073).to_bytes(4, "little"))

    def test_dump_largo_incorrecto(self):
        with self.assertRaises(P.ProtocolError):
            P.parse_dump(P.Frame(P.T_DUMP, bytes(180)))

    def test_read_frame_resincroniza(self):
        ser = FakeSerial(timeout=0.01)
        # basura, un 0xAA suelto con tipo inválido y después una trama válida
        ser._tx += bytes.fromhex("00 13 AA 55") + P.frame_ack(P.CMD_PING).encode()
        self.assertEqual(read_frame(ser, 0.2), P.frame_ack(P.CMD_PING))

    def test_read_frame_timeout(self):
        ser = FakeSerial(timeout=0.01)
        ser._tx += bytes.fromhex("AA 20 B5 00 01 02")   # DUMP truncado
        with self.assertRaises(ResponseTimeout):
            read_frame(ser, 0.05)


class TestDebugLink(unittest.TestCase):

    def setUp(self):
        self.ser = FakeSerial()
        self.link = DebugLink(ser=self.ser, timeout=0.05)

    def test_load_y_step(self):
        """Tras LOAD de N palabras, N STEP muestran la palabra N-ésima en IF/ID."""
        self.link.load(PROG_A)
        d = self.link.dump()
        self.assertEqual((d.pc, d.status.pipeline_empty), (0, True))
        for i, w in enumerate(PROG_A):
            d = self.link.step()
            self.assertEqual(d.pc, 4 * (i + 1))
            self.assertEqual(d.if_id, P.IfId(pc=4 * i, instr=w))
            self.assertTrue(d.status.valid[0])
            self.assertEqual(d.regs, list(range(32)))

    def test_run_hasta_halt(self):
        self.link.load(PROG_A)
        d = self.link.run(timeout=1)
        self.assertTrue(d.status.halted and d.status.pipeline_empty)
        self.assertFalse(d.status.illegal)
        self.assertEqual(d.pc, 20)
        self.assertFalse(self.link.running)
        self.assertIsNone(self.link.stop())     # STOP fuera de RUN: ACK

    def test_segundo_load_mas_corto(self):
        self.link.load(PROG_A)
        self.link.run(timeout=1)
        self.link.load([0x00500293, 0x00600313])
        self.assertEqual(self.ser.imem[:3], [0x00500293, 0x00600313, 0])
        d = self.link.run(timeout=1)
        self.assertTrue(d.status.halted and d.status.illegal)   # cayó en el relleno

    def test_reset(self):
        self.link.load(PROG_A)
        self.link.step()
        self.link.reset()
        self.assertEqual(self.link.dump().pc, 0)
        self.assertEqual(self.ser.imem[:5], PROG_A)               # RESET no toca la imem

    def test_run_sin_halt_y_stop(self):
        self.link.load([NOP] * 1024)
        self.link.start_run()
        with self.assertRaises(LinkError):
            self.link.step()                    # durante RUN solo se puede STOP
        with self.assertRaises(LinkError):
            self.link.dump()
        with self.assertRaises(ResponseTimeout):
            self.link.wait_run(timeout=0.05)    # sigue corriendo
        d = self.link.stop()
        self.assertFalse(d.status.halted)
        self.assertFalse(self.link.running)
        self.link.ping()

    def test_stop_justo_despues_del_halt(self):
        """Si el DUMP del HALT ya salió, el ACK del STOP se descarta solo."""
        self.link.load(PROG_A)
        self.link.start_run()                   # el fake termina enseguida
        self.ser._process()
        self.ser._tx += P.frame_ack(P.CMD_STOP).encode()   # lo que la FPGA respondería
        d = self.link.stop()
        self.assertTrue(d.status.halted)
        self.link.ping()

    def test_read_dmem(self):
        self.assertEqual(self.link.read_dmem(8, 3), [0xD0000002, 0xD0000003, 0xD0000004])
        self.assertEqual(self.link.read_dmem(0, 0), [])          # dmem_hwm = 0
        with self.assertRaises(ValueError):
            self.link.read_dmem(2, 1)

    def test_nack_se_informa(self):
        self.ser.write(bytes((0x7F,)))
        with self.assertRaises(P.NackError):
            P.parse_ack(read_frame(self.ser, 0.1), P.CMD_PING)


class TestFallas(unittest.TestCase):

    def test_sin_placa(self):
        with self.assertRaises(LinkError) as cm:
            DebugLink(ser=FakeSerial(responsive=False), timeout=0.02, retries=1)
        self.assertIn("no responde", str(cm.exception))

    def test_puerto_inexistente(self):
        with self.assertRaises(LinkError) as cm:
            DebugLink("PUERTO_QUE_NO_EXISTE")
        msg = str(cm.exception)
        self.assertTrue("pyserial" in msg or "No se pudo abrir" in msg, msg)

    def test_reintento_si_se_pierde_una_respuesta(self):
        ser = FakeSerial()
        link = DebugLink(ser=ser, timeout=0.02)
        ser.drop_responses = 1
        link.ping()
        self.assertEqual(ser.commands[-2:], [P.CMD_PING, P.CMD_PING])

    def test_step_no_se_reintenta(self):
        ser = FakeSerial()
        link = DebugLink(ser=ser, timeout=0.02)
        link.load(PROG_A)
        ser.drop_responses = 1
        with self.assertRaises(ResponseTimeout):
            link.step()
        self.assertEqual(ser.commands.count(P.CMD_STEP), 1)

    def test_load_corrupto_se_reintenta(self):
        ser = FakeSerial()
        link = DebugLink(ser=ser, timeout=0.02)
        ser.corrupt_load_acks = 1
        link.load(PROG_A)
        self.assertEqual(ser.commands.count(P.CMD_LOAD), 2)

    def test_load_siempre_corrupto(self):
        ser = FakeSerial()
        link = DebugLink(ser=ser, timeout=0.02, retries=2)
        ser.corrupt_load_acks = 10
        with self.assertRaises(LinkError) as cm:
            link.load(PROG_A)
        self.assertIn("carga corrupta", str(cm.exception))
        self.assertEqual(ser.commands.count(P.CMD_LOAD), 3)

    def test_basura_antes_de_la_respuesta(self):
        ser = FakeSerial()
        link = DebugLink(ser=ser, timeout=0.05)
        ser.garbage = bytes.fromhex("FF AA 00 13")
        self.assertEqual(link.dump().pc, 0)


class TestReadHex(unittest.TestCase):

    def test_read_hex(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "p.hex")
            with open(path, "w", encoding="utf-8") as f:
                f.write("00500093\n// comentario\n\n00308113  # addi\n00100073\n")
            self.assertEqual(read_hex(path), [0x00500093, 0x00308113, 0x00100073])
            with open(path, "w", encoding="utf-8") as f:
                f.write("0050009Z\n")
            with self.assertRaises(ValueError):
                read_hex(path)


if __name__ == "__main__":
    unittest.main()
