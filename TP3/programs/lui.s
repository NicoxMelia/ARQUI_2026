# lui.s: lui con distintos valores, lui pisa los 12 bits bajos, lui a x0 y
# constantes de 32 bits con lui + addi (dos nop en el medio: sin forwarding).
# Issue: TEST-1 (#18).

        addi x5, x0, 7          # se pisa con lui x5, 0
        addi x8, x0, -1         # se pisa con lui x8, 0x00ABC
        lui  x1, 0x12345        # x1 = 0x12345000
        lui  x2, 0xFFFFF        # x2 = 0xFFFFF000
        lui  x3, 0x80000        # x3 = 0x80000000
        lui  x4, 0x00001        # x4 = 0x00001000
        lui  x5, 0              # x5 = 0
        lui  x6, 0xDEADC        # x6 = 0xDEADC000
        lui  x7, 0x12345        # x7 = 0x12345000
        lui  x8, 0x00ABC        # x8 = 0x00ABC000 (bits bajos en 0)
        nop
        lui  x0, 0xABCDE        # x0 sigue en 0
        addi x6, x6, -0x111     # 0xDEADC000 - 0x111 = 0xDEADBEEF
        addi x7, x7, 0x678      # 0x12345678
        add  x10, x0, x2        # lee x0 cuando lui x0 está en WB: 0xFFFFF000
        add  x9, x1, x4         # 0x12346000
        halt
