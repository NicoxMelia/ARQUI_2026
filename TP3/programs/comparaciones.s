# comparaciones.s: slt, sltu, slti, sltiu. Los mismos operandos dan
# distinto resultado con y sin signo. sltiu extiende el inmediato con
# signo y compara sin signo.
# Issue: TEST-1 (#18).

        addi x1, x0, -1         # x1 = 0xFFFFFFFF
        addi x2, x0, 1          # x2 = 1
        lui  x3, 0x80000        # x3 = 0x80000000 (INT_MIN)
        addi x4, x0, 5          # x4 = 5
        addi x5, x0, -5         # x5 = 0xFFFFFFFB
        lui  x6, 0x7FFFF        # x6 = 0x7FFFF000
        nop
        nop

        slt   x10, x1, x2       # -1 < 1: 1
        sltu  x11, x1, x2       # 0xFFFFFFFF < 1: 0
        slt   x12, x2, x1       # 1 < -1: 0
        sltu  x13, x2, x1       # 1 < 0xFFFFFFFF: 1
        slt   x14, x3, x6       # INT_MIN < 0x7FFFF000: 1
        sltu  x15, x3, x6       # 0x80000000 < 0x7FFFF000: 0
        slt   x16, x5, x4       # -5 < 5: 1
        slt   x17, x4, x4       # iguales: 0
        sltu  x18, x0, x4       # 0 < 5 (snez): 1
        sltu  x19, x0, x0       # 0
        slt   x20, x5, x1       # -5 < -1: 1
        sltu  x21, x5, x1       # 0xFFFFFFFB < 0xFFFFFFFF: 1
        slti  x22, x5, -4       # -5 < -4: 1
        slti  x23, x4, -4       # 5 < -4: 0
        slti  x24, x3, -2048    # INT_MIN < -2048: 1
        sltiu x25, x4, -1       # 5 < 0xFFFFFFFF: 1
        sltiu x26, x1, -1       # 0xFFFFFFFF < 0xFFFFFFFF: 0
        sltiu x27, x0, 1        # 0 < 1 (seqz): 1
        sltiu x28, x4, 1        # 5 < 1: 0
        slti  x29, x6, 2047     # 0x7FFFF000 < 2047: 0
        slt   x0, x1, x2        # x0 sigue en 0
        halt
