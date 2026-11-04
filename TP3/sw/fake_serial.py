"""FakeSerial: Debug Unit + core_stub emulados, para probar sin placa.

Tiene la interfaz de pyserial que usa serial_link.py (write, read,
reset_input_buffer, in_waiting, timeout, flush, close) y responde según
doc/protocolo_uart.md. El core imita a src/core_stub.v:

  - con cada ciclo el PC avanza de a 4 y IF/ID guarda {instr, pc};
  - banco de registros falso: x_i = i; dmem falsa: palabra i = 0xD0000000 | i;
  - ebreak en IF/ID detiene el core; 0x00000000 lo detiene con illegal (D3).

Fallas inyectables (para probar timeouts y reintentos):
  responsive=False      no responde nada (como si no hubiera placa)
  drop_responses=N      se pierden las próximas N respuestas
  corrupt_load_acks=N   los próximos N ACK de LOAD traen el xor cambiado
  garbage=b"..."        bytes basura antes de la próxima respuesta
  max_run_cycles        ciclos que simula un RUN antes de considerarlo
                        "corriendo para siempre" (programa sin HALT)

No emula el timeout de 10 ms de la FPGA: una trama incompleta queda
esperando los bytes que faltan.

Issue: SW-2 (#17).
"""

import time

import protocol as P

EBREAK = 0x00100073


class FakeSerial:
    def __init__(self, *, responsive=True, timeout=None, max_run_cycles=10_000):
        self.timeout = timeout
        self.responsive = responsive
        self.max_run_cycles = max_run_cycles
        self.drop_responses = 0
        self.corrupt_load_acks = 0
        self.garbage = b""
        self.is_open = True
        self.commands = []          # comandos recibidos (para los tests)
        self._rx = bytearray()      # PC -> FPGA, todavía sin procesar
        self._tx = bytearray()      # FPGA -> PC
        self.running = False
        self.imem = [0] * P.IMEM_WORDS
        self._core_reset()

    # ------------------------------------------------------------------
    # Interfaz tipo pyserial
    # ------------------------------------------------------------------
    def write(self, data) -> int:
        self._rx += bytes(data)
        self._process()
        return len(data)

    def read(self, n=1) -> bytes:
        if not self._tx:
            # Como pyserial: sin datos espera hasta el timeout
            if self.timeout:
                time.sleep(min(self.timeout, 0.05))
            return b""
        out = bytes(self._tx[:n])
        del self._tx[:n]
        return out

    @property
    def in_waiting(self) -> int:
        return len(self._tx)

    def reset_input_buffer(self) -> None:
        self._tx.clear()

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.is_open = False

    # ------------------------------------------------------------------
    # Core (como core_stub.v)
    # ------------------------------------------------------------------
    def _core_reset(self) -> None:
        self.pc = 0
        self.if_id_pc = 0
        self.if_id_instr = 0
        self.if_id_valid = False
        self.halted = False
        self.illegal = False

    def _tick(self) -> None:
        is_halt = self.if_id_valid and self.if_id_instr == EBREAK
        is_ill = self.if_id_valid and self.if_id_instr == 0
        if self.halted or is_halt or is_ill:
            self.if_id_pc = self.if_id_instr = 0
            self.if_id_valid = False
            self.halted |= is_halt or is_ill
            self.illegal |= is_ill
        else:
            self.if_id_pc = self.pc
            self.if_id_instr = self.imem[(self.pc >> 2) % P.IMEM_WORDS]
            self.if_id_valid = True
            self.pc = (self.pc + 4) & 0xFFFFFFFF

    def _done(self) -> bool:
        return self.halted and not self.if_id_valid

    def _dump_frame(self) -> P.Frame:
        status = P.Status(self.halted, self.illegal, not self.if_id_valid,
                          [self.if_id_valid, False, False, False]).to_byte()
        if_id = (self.if_id_instr << 32) | self.if_id_pc
        payload = P.build_dump_payload(status, self.pc, list(range(32)), if_id=if_id)
        return P.Frame(P.T_DUMP, payload)

    # ------------------------------------------------------------------
    # Debug Unit
    # ------------------------------------------------------------------
    def _respond(self, frame: P.Frame) -> None:
        if not self.responsive:
            return
        if self.drop_responses > 0:
            self.drop_responses -= 1
            return
        self._tx += self.garbage + frame.encode()
        self.garbage = b""

    def _process(self) -> None:
        while self._rx:
            if self.running:
                # D12: durante RUN solo se atiende STOP
                b = self._rx.pop(0)
                if b == P.CMD_STOP:
                    self.commands.append(P.CMD_STOP)
                    self.running = False
                    self._respond(self._dump_frame())
                continue

            cmd = self._rx[0]
            if cmd == P.CMD_LOAD:
                if len(self._rx) < 3:
                    return
                n = self._rx[1] | (self._rx[2] << 8)
                if not 1 <= n <= P.IMEM_WORDS:
                    self._rx.clear()            # D14: se descarta el resto
                    self._respond(P.frame_nack(cmd, P.E_BAD_ARG))
                    continue
                if len(self._rx) < 3 + 4 * n:
                    return
                data = bytes(self._rx[3:3 + 4 * n])
                del self._rx[:3 + 4 * n]
                self._load(data, n)
            elif cmd == P.CMD_READ_DMEM:
                if len(self._rx) < 5:
                    return
                addr = self._rx[1] | (self._rx[2] << 8)
                count = self._rx[3] | (self._rx[4] << 8)
                del self._rx[:5]
                self._read_dmem(addr, count)
            else:
                self._rx.pop(0)
                self._simple(cmd)
            self.commands.append(cmd)

    def _load(self, data: bytes, n: int) -> None:
        self._core_reset()
        words = [int.from_bytes(data[4 * i:4 * i + 4], "little") for i in range(n)]
        self.imem = words + [0] * (P.IMEM_WORDS - n)
        xor = 0
        for b in data:
            xor ^= b
        if self.corrupt_load_acks > 0:
            self.corrupt_load_acks -= 1
            xor ^= 0xFF
        self._respond(P.frame_load_ack(n, xor))

    def _read_dmem(self, addr: int, count: int) -> None:
        if addr % 4 or addr + 4 * count > P.DMEM_BYTES or addr >= P.DMEM_BYTES:
            self._respond(P.frame_nack(P.CMD_READ_DMEM, P.E_BAD_ARG))
            return
        # dmem_hwm = 0 en el stub: count = 0 devuelve 0 palabras
        first = addr // 4
        words = [0xD0000000 | (first + i) for i in range(count)]
        payload = bytes((addr & 0xFF, addr >> 8, count & 0xFF, count >> 8))
        payload += b"".join(w.to_bytes(4, "little") for w in words)
        self._respond(P.Frame(P.T_DMEM, payload))

    def _simple(self, cmd: int) -> None:
        if cmd in (P.CMD_PING, P.CMD_STOP):
            self._respond(P.frame_ack(cmd))
        elif cmd == P.CMD_RESET:
            self._core_reset()
            self._respond(P.frame_ack(cmd))
        elif cmd == P.CMD_STEP:
            self._tick()
            self._respond(self._dump_frame())
        elif cmd == P.CMD_DUMP:
            self._respond(self._dump_frame())
        elif cmd == P.CMD_RUN:
            for _ in range(self.max_run_cycles):
                if self._done():
                    self._respond(self._dump_frame())
                    return
                self._tick()
            if self._done():
                self._respond(self._dump_frame())
            else:
                self.running = True             # sin HALT: hasta que llegue STOP
        else:
            self._respond(P.frame_nack(cmd, P.E_UNKNOWN_CMD))
