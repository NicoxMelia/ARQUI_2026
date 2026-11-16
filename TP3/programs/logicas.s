# logicas.s: and, or, xor, andi, ori, xori. Los inmediatos se extienden
# con signo (andi/ori/xori con imm negativo afectan los 20 bits altos).
# Issue: TEST-1 (#18).

        lui  x1, 0xF0F0F        # x1 = 0xF0F0F000
        lui  x2, 0x0FF00        # x2 = 0x0FF00000
        addi x3, x0, 0x0F0      # x3 = 0x000000F0
        addi x4, x0, -1         # x4 = 0xFFFFFFFF
        addi x5, x0, 0x555      # x5 = 0x00000555
        nop
        nop

        and  x10, x1, x2        # 0x00F00000
        or   x11, x1, x2        # 0xFFF0F000
        xor  x12, x1, x2        # 0xFF00F000
        and  x13, x1, x0        # 0
        or   x14, x3, x5        # 0x5F5
        xor  x15, x4, x1        # not x1 = 0x0F0F0FFF
        xor  x16, x5, x5        # 0
        andi x17, x4, 0x7FF     # 0x7FF
        andi x18, x1, -256      # imm 0xFFFFFF00: 0xF0F0F000
        andi x19, x5, 0x0F0     # 0x050
        ori  x20, x3, -2048     # imm 0xFFFFF800: 0xFFFFF8F0
        ori  x21, x0, 0x2AA     # 0x2AA
        xori x22, x4, -1        # not(-1) = 0
        xori x23, x3, -1        # not 0xF0 = 0xFFFFFF0F
        xori x24, x5, 0x7FF     # 0x2AA
        and  x0, x4, x4         # x0 sigue en 0
        halt
