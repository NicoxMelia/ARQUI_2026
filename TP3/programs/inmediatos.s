# inmediatos.s: extremos del inmediato de 12 bits y extensión de signo.
#
# Varios inmediatos tienen el bit 10 en 1, que en la instrucción es el bit
# 30 (= funct7[5] de las tipo R). alu_op = {funct7[5], funct3} solo vale
# para las tipo R y srai: si el decodificador lo usa también para las I,
# addi pasa a ser sub, xori/ori/andi/slti/sltiu caen en códigos sin
# definir y estos resultados salen mal.
# Issue: TEST-1 (#18).

        addi  x1, x0, 100       # x1 = 0x64
        lui   x2, 0x12345       # x2 = 0x12345000
        nop
        nop

        addi  x10, x1, 1024     # 1124 = 0x464 (bit 30 en 1)
        addi  x11, x1, -1024    # -924 = 0xFFFFFC64
        addi  x12, x0, 2047     # 0x7FF
        addi  x13, x0, -2048    # 0xFFFFF800
        addi  x14, x1, 0        # mv: 0x64
        addi  x15, x2, -1       # 0x12344FFF
        slti  x16, x1, 1024     # 100 < 1024: 1 (bit 30 en 1)
        sltiu x17, x1, 1100     # 100 < 1100: 1 (bit 30 en 1)
        xori  x18, x1, 1024     # 0x064 ^ 0x400 = 0x464 (bit 30 en 1)
        ori   x19, x2, 0x678    # 0x12345678 (bit 30 en 1)
        andi  x20, x2, -1       # 0x12345000
        andi  x21, x1, 0x7E0    # 0x064 & 0x7E0 = 0x060 (bit 30 en 1)
        addi  x22, x2, 0x678    # 0x12345678
        addi  x0, x1, 1         # x0 sigue en 0
        halt
