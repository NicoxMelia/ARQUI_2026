"""Tabla de instrucciones RV32I implementadas (32) y helpers de codificación.

Fuente: RISC-V Unprivileged ISA, RV32I (cap. "RV32I Base Integer Instruction Set").
Ver doc/isa.md.
"""

# Opcodes (bits 6:0)
OP_R = 0b0110011
OP_I = 0b0010011
OP_LOAD = 0b0000011
OP_JALR = 0b1100111
OP_S = 0b0100011
OP_B = 0b1100011
OP_LUI = 0b0110111
OP_JAL = 0b1101111
OP_SYSTEM = 0b1110011

# mnemónico -> (formato, opcode, funct3, funct7)
# funct3/funct7 None = el campo no existe en ese formato.
# Para slli/srli/srai, funct7 va en imm[11:5] y shamt en imm[4:0].
ISA = {
    # R
    "add":   ("R", OP_R, 0b000, 0b0000000),
    "sub":   ("R", OP_R, 0b000, 0b0100000),
    "sll":   ("R", OP_R, 0b001, 0b0000000),
    "slt":   ("R", OP_R, 0b010, 0b0000000),
    "sltu":  ("R", OP_R, 0b011, 0b0000000),
    "xor":   ("R", OP_R, 0b100, 0b0000000),
    "srl":   ("R", OP_R, 0b101, 0b0000000),
    "sra":   ("R", OP_R, 0b101, 0b0100000),
    "or":    ("R", OP_R, 0b110, 0b0000000),
    "and":   ("R", OP_R, 0b111, 0b0000000),
    # I (aritmético-lógicas)
    "addi":  ("I", OP_I, 0b000, None),
    "slti":  ("I", OP_I, 0b010, None),
    "sltiu": ("I", OP_I, 0b011, None),
    "xori":  ("I", OP_I, 0b100, None),
    "ori":   ("I", OP_I, 0b110, None),
    "andi":  ("I", OP_I, 0b111, None),
    "slli":  ("I", OP_I, 0b001, 0b0000000),
    "srli":  ("I", OP_I, 0b101, 0b0000000),
    "srai":  ("I", OP_I, 0b101, 0b0100000),
    # Loads (formato I)
    "lb":    ("I", OP_LOAD, 0b000, None),
    "lh":    ("I", OP_LOAD, 0b001, None),
    "lw":    ("I", OP_LOAD, 0b010, None),
    "lbu":   ("I", OP_LOAD, 0b100, None),
    "lhu":   ("I", OP_LOAD, 0b101, None),
    # jalr (formato I)
    "jalr":  ("I", OP_JALR, 0b000, None),
    # S
    "sb":    ("S", OP_S, 0b000, None),
    "sh":    ("S", OP_S, 0b001, None),
    "sw":    ("S", OP_S, 0b010, None),
    # B
    "beq":   ("B", OP_B, 0b000, None),
    "bne":   ("B", OP_B, 0b001, None),
    # U
    "lui":   ("U", OP_LUI, None, None),
    # J
    "jal":   ("J", OP_JAL, None, None),
}

SHIFT_IMM = {"slli", "srli", "srai"}
LOADS = {"lb", "lh", "lw", "lbu", "lhu"}

NOP = 0x00000013    # addi x0, x0, 0
HALT = 0x00100073   # ebreak
ILLEGAL_ZERO = 0x00000000  # ilegal: se trata como HALT + flag illegal


def _reg(x):
    if not 0 <= x < 32:
        raise ValueError(f"registro fuera de rango: {x}")
    return x


def _imm(v, bits, signed=True, align=1):
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    if not lo <= v <= hi:
        raise ValueError(f"inmediato {v} fuera de rango [{lo}, {hi}]")
    if v % align:
        raise ValueError(f"inmediato {v} no alineado a {align}")
    return v & ((1 << bits) - 1)


def encode(mnem, rd=0, rs1=0, rs2=0, imm=0):
    """Codifica una instrucción a palabra de 32 bits.

    imm: para B/J es el offset en bytes relativo al PC de la instrucción;
    para U es el valor de 20 bits (imm[31:12]); para shifts inmediatos es shamt.
    """
    fmt, op, f3, f7 = ISA[mnem]
    rd, rs1, rs2 = _reg(rd), _reg(rs1), _reg(rs2)
    if fmt == "R":
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
    if fmt == "I":
        if mnem in SHIFT_IMM:
            i = (f7 << 5) | _imm(imm, 5, signed=False)
        else:
            i = _imm(imm, 12)
        return (i << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
    if fmt == "S":
        i = _imm(imm, 12)
        return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | op
    if fmt == "B":
        i = _imm(imm, 13, align=2)
        return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
            | (f3 << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | op
    if fmt == "U":
        return (_imm(imm, 20, signed=False) << 12) | (rd << 7) | op
    if fmt == "J":
        i = _imm(imm, 21, align=2)
        return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) | (((i >> 11) & 1) << 20) \
            | (((i >> 12) & 0xFF) << 12) | (rd << 7) | op
    raise AssertionError(fmt)


if __name__ == "__main__":
    assert len(ISA) == 32
    # Vectores conocidos (salida de un ensamblador RISC-V de referencia)
    checks = [
        (encode("addi", rd=0, rs1=0, imm=0), NOP),
        (encode("addi", rd=1, rs1=0, imm=5), 0x00500093),
        (encode("add", rd=3, rs1=1, rs2=2), 0x002081B3),
        (encode("sub", rd=3, rs1=1, rs2=2), 0x402081B3),
        (encode("srai", rd=1, rs1=1, imm=1), 0x4010D093),
        (encode("lw", rd=2, rs1=1, imm=4), 0x0040A103),
        (encode("sw", rs1=1, rs2=2, imm=4), 0x0020A223),
        (encode("beq", rs1=1, rs2=2, imm=8), 0x00208463),
        (encode("lui", rd=1, imm=0x12345), 0x123450B7),
        (encode("jal", rd=1, imm=8), 0x008000EF),
        (encode("jalr", rd=0, rs1=1, imm=0), 0x00008067),
    ]
    for got, exp in checks:
        assert got == exp, f"{got:#010x} != {exp:#010x}"
    print("isa_table OK")
