# shifts.s: sll, srl, sra, slli, srli, srai. Cantidades 0 y 31, cantidades
# de registro >= 32 (solo cuentan los bits [4:0]) y sra con negativos.
# Issue: TEST-1 (#18).

        lui  x1, 0x80000        # x1 = 0x80000000
        addi x2, x0, 1          # x2 = 1
        addi x3, x0, 31         # x3 = 31
        addi x4, x0, 32         # x4 = 32  -> como cantidad vale 0
        addi x5, x0, 35         # x5 = 35  -> como cantidad vale 3
        addi x6, x0, -16        # x6 = 0xFFFFFFF0
        addi x7, x0, -1         # x7 = 0xFFFFFFFF -> como cantidad vale 31
        lui  x8, 0x12345        # x8 = 0x12345000
        nop
        nop

        sll  x10, x2, x3        # 1 << 31 = 0x80000000
        sll  x11, x2, x4        # 1 << 0 = 1
        sll  x12, x8, x5        # 0x12345000 << 3 = 0x91A28000
        srl  x13, x1, x3        # 0x80000000 >> 31 = 1
        srl  x14, x6, x5        # 0xFFFFFFF0 >> 3 = 0x1FFFFFFE (lógico)
        srl  x15, x1, x7        # >> 31 = 1
        sra  x16, x1, x3        # 0x80000000 >>> 31 = 0xFFFFFFFF
        sra  x17, x6, x5        # -16 >>> 3 = -2 = 0xFFFFFFFE
        sra  x18, x8, x4        # >>> 0 = 0x12345000
        sra  x19, x6, x2        # -16 >>> 1 = -8 = 0xFFFFFFF8
        slli x20, x2, 31        # 0x80000000
        slli x21, x8, 0         # 0x12345000
        slli x22, x6, 4         # 0xFFFFFF00
        srli x23, x1, 31        # 1
        srli x24, x6, 4         # 0x0FFFFFFF
        srai x25, x1, 31        # 0xFFFFFFFF
        srai x26, x6, 2         # -4 = 0xFFFFFFFC
        srai x27, x8, 12        # positivo: 0x00012345
        srli x28, x7, 0         # 0xFFFFFFFF
        halt
