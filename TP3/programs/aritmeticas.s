# aritmeticas.s: add, sub y addi. Overflow, negativos y x0 como destino.
# Sin forwarding: los operandos se cargan primero y después de dos nop solo
# se leen registros ya escritos.
# Issue: TEST-1 (#18).

        # Operandos
        lui  x1, 0x80000        # x1 = 0x80000000 (INT_MIN)
        addi x2, x0, 1          # x2 = 1
        addi x3, x0, -1         # x3 = 0xFFFFFFFF
        addi x4, x0, 100        # x4 = 0x64
        addi x5, x0, -100       # x5 = 0xFFFFFF9C
        nop
        nop

        add  x10, x4, x5        # 100 + (-100) = 0
        add  x11, x3, x3        # -1 + -1 = 0xFFFFFFFE
        add  x12, x1, x3        # INT_MIN + (-1) = 0x7FFFFFFF (overflow)
        add  x13, x3, x2        # 0xFFFFFFFF + 1 = 0 (se pierde el carry)
        sub  x14, x1, x2        # INT_MIN - 1 = 0x7FFFFFFF (overflow)
        sub  x15, x0, x1        # -INT_MIN = 0x80000000 (overflow)
        sub  x16, x2, x4        # 1 - 100 = -99 = 0xFFFFFF9D
        sub  x17, x5, x5        # 0
        sub  x18, x4, x5        # 100 - (-100) = 200 = 0xC8
        addi x19, x4, -101      # -1 = 0xFFFFFFFF
        addi x20, x1, -1        # INT_MIN - 1 = 0x7FFFFFFF (overflow con inmediato)
        addi x21, x3, 2047      # -1 + 2047 = 2046 = 0x7FE
        addi x22, x2, -2048     # 1 - 2048 = -2047 = 0xFFFFF801

        # x0 como destino: la escritura se descarta. add x23 lee x0 justo
        # cuando "add x0" está en WB: el bypass del banco (D6) no debe
        # adelantar el 200 que se intentó escribir en x0.
        add  x0, x4, x4
        addi x0, x0, 123
        sub  x0, x3, x4
        add  x23, x0, x4        # 0 + 100 = 0x64
        halt
