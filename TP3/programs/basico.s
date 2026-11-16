# basico.s: programa corto para el pipeline base (CORE-5, INT-3).
# addi, add, sub y HALT. Sin forwarding: dos nop entre productor y consumidor.
# Issue: TEST-1 (#18).

        addi x1, x0, 5          # x1 = 5
        addi x2, x0, 3          # x2 = 3
        addi x3, x0, -1         # x3 = 0xFFFFFFFF
        nop
        nop
        add  x4, x1, x2         # x4 = 8
        sub  x5, x1, x2         # x5 = 2
        sub  x6, x2, x1         # x6 = -2 = 0xFFFFFFFE
        add  x7, x1, x3         # x7 = 5 + (-1) = 4
        halt
