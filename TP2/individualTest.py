#!/usr/bin/env python3

import sys
import serial
import serial.tools.list_ports

BAUD = 19200

OPS = {
    "ADD": 0b100000,
    "SUB": 0b100010,
    "AND": 0b100100,
    "OR":  0b100101,
    "XOR": 0b100110,
    "NOR": 0b100111,
    "SRL": 0b000010,
    "SRA": 0b000011,
}


def modelo(a, b, op):
    """Misma logica que la ALU del TP1, para saber que esperar."""
    if op == OPS["ADD"]:
        return (a + b) & 0xFF
    if op == OPS["SUB"]:
        return (a - b) & 0xFF
    if op == OPS["AND"]:
        return a & b
    if op == OPS["OR"]:
        return a | b
    if op == OPS["XOR"]:
        return a ^ b
    if op == OPS["NOR"]:
        return (~(a | b)) & 0xFF
    if op == OPS["SRL"]:
        return (a >> b) & 0xFF if b < 8 else 0
    if op == OPS["SRA"]:
        signed = a - 256 if a & 0x80 else a
        return (signed >> min(b, 7)) & 0xFF
    return 0


def buscar_puerto():
    puertos = list(serial.tools.list_ports.comports())
    if not puertos:
        sys.exit("No se encontro ningun puerto serie. Conectaste la placa?")
    for p in puertos:
        # El puente de la Basys 3 es un FTDI FT2232HQ
        if "FTDI" in (p.manufacturer or "") or "0403" in (p.hwid or ""):
            return p.device
    return puertos[0].device


def operar(ser, a, b, op):
    ser.reset_input_buffer()
    ser.write(bytes([a & 0xFF, b & 0xFF, op & 0xFF]))
    resp = ser.read(1)
    if len(resp) != 1:
        raise TimeoutError("La placa no contesto")
    return resp[0]


def pedir_byte(mensaje):
    while True:
        entrada = input(mensaje).strip().replace("0b", "").replace("_", "")
        if not entrada or any(c not in "01" for c in entrada):
            print("Valor invalido, ingresa un numero binario (ej: 00000101).")
            continue
        if len(entrada) > 8:
            print("El valor debe tener a lo sumo 8 bits.")
            continue
        return int(entrada, 2)


def pedir_operacion():
    nombres = list(OPS.keys())
    while True:
        entrada = input(f"Operacion ({'/'.join(nombres)}): ").strip().upper()
        if entrada in OPS:
            return entrada
        print("Operacion invalida.")


def main():
    puerto = sys.argv[1] if len(sys.argv) > 1 else buscar_puerto()
    print(f"Puerto: {puerto} @ {BAUD} baud, 8N1\n")

    a = pedir_byte("Entrada A (binario, 8 bits): ")
    b = pedir_byte("Entrada B (binario, 8 bits): ")
    nombre = pedir_operacion()
    op = OPS[nombre]

    print(f"\n{nombre}: 0b{op:06b}\n")

    with serial.Serial(puerto, BAUD, timeout=2) as ser:
        got = operar(ser, a, b, op)

    exp = modelo(a, b, op)
    estado = "OK  " if got == exp else "FAIL"

    print(f"{estado} | A=0x{a:02X} B=0x{b:02X} {nombre:<3} "
          f"-> 0x{got:02X} (esperado 0x{exp:02X})")


if __name__ == "__main__":
    main()
