# ISA implementada: subconjunto de RV32I (32 instrucciones)

Fuente: *RISC-V Unprivileged ISA*, RV32I. Cada encoding se contrastó con la especificación y no solo con las diapositivas. La tabla en forma de código está en [`sw/isa_table.py`](../sw/isa_table.py), que además trae `encode()` y un autotest con vectores de referencia (`python sw/isa_table.py`).

## Formatos

```
 31        25 24  20 19  15 14  12 11       7 6     0
R: funct7    | rs2  | rs1  |funct3| rd       | opcode
I: imm[11:0]        | rs1  |funct3| rd       | opcode
S: imm[11:5] | rs2  | rs1  |funct3| imm[4:0] | opcode
B: imm[12|10:5]|rs2 | rs1  |funct3| imm[4:1|11] | opcode
U: imm[31:12]                      | rd       | opcode
J: imm[20|10:1|11|19:12]           | rd       | opcode
```

## Tabla de instrucciones

| Instr | Fmt | Opcode | funct3 | funct7 | Semántica |
|-------|-----|--------|--------|--------|-----------|
| add   | R | 0110011 | 000 | 0000000 | rd = rs1 + rs2 |
| sub   | R | 0110011 | 000 | 0100000 | rd = rs1 - rs2 |
| sll   | R | 0110011 | 001 | 0000000 | rd = rs1 << rs2[4:0] |
| slt   | R | 0110011 | 010 | 0000000 | rd = (rs1 < rs2) con signo |
| sltu  | R | 0110011 | 011 | 0000000 | rd = (rs1 < rs2) sin signo |
| xor   | R | 0110011 | 100 | 0000000 | rd = rs1 ^ rs2 |
| srl   | R | 0110011 | 101 | 0000000 | rd = rs1 >> rs2[4:0] (lógico) |
| sra   | R | 0110011 | 101 | 0100000 | rd = rs1 >>> rs2[4:0] (aritmético) |
| or    | R | 0110011 | 110 | 0000000 | rd = rs1 \| rs2 |
| and   | R | 0110011 | 111 | 0000000 | rd = rs1 & rs2 |
| addi  | I | 0010011 | 000 | - | rd = rs1 + sext(imm) |
| slti  | I | 0010011 | 010 | - | rd = (rs1 < sext(imm)) con signo |
| sltiu | I | 0010011 | 011 | - | rd = (rs1 < sext(imm)) sin signo (imm se extiende con signo y se compara como sin signo) |
| xori  | I | 0010011 | 100 | - | rd = rs1 ^ sext(imm) |
| ori   | I | 0010011 | 110 | - | rd = rs1 \| sext(imm) |
| andi  | I | 0010011 | 111 | - | rd = rs1 & sext(imm) |
| slli  | I | 0010011 | 001 | 0000000 (imm[11:5]) | rd = rs1 << shamt |
| srli  | I | 0010011 | 101 | 0000000 (imm[11:5]) | rd = rs1 >> shamt (lógico) |
| srai  | I | 0010011 | 101 | 0100000 (imm[11:5]) | rd = rs1 >>> shamt (aritmético) |
| lb    | I | 0000011 | 000 | - | rd = sext(mem8[rs1+imm]) |
| lh    | I | 0000011 | 001 | - | rd = sext(mem16[rs1+imm]) |
| lw    | I | 0000011 | 010 | - | rd = mem32[rs1+imm] |
| lbu   | I | 0000011 | 100 | - | rd = zext(mem8[rs1+imm]) |
| lhu   | I | 0000011 | 101 | - | rd = zext(mem16[rs1+imm]) |
| jalr  | I | 1100111 | 000 | - | rd = PC+4; PC = (rs1 + sext(imm)) & ~1 |
| sb    | S | 0100011 | 000 | - | mem8[rs1+imm] = rs2[7:0] |
| sh    | S | 0100011 | 001 | - | mem16[rs1+imm] = rs2[15:0] |
| sw    | S | 0100011 | 010 | - | mem32[rs1+imm] = rs2 |
| beq   | B | 1100011 | 000 | - | si rs1 == rs2: PC = PC + sext(imm) |
| bne   | B | 1100011 | 001 | - | si rs1 != rs2: PC = PC + sext(imm) |
| lui   | U | 0110111 | - | - | rd = imm[31:12] << 12 |
| jal   | J | 1101111 | - | - | rd = PC+4; PC = PC + sext(imm) |

Además: `ebreak` (HALT) = `0x00100073`, opcode `1110011`, funct3 `000`, imm `000000000001`. No cuenta entre las 32.

## Correcciones a las diapositivas de la consigna

- **jal:** el destino sale de `PC + imm` (no de un registro); `rd` recibe la dirección de retorno `PC+4`.
- **beq:** los operandos son `rs1` y `rs2` (la slide muestra `rs1` dos veces).
- **ld:** es RV64; en RV32 corresponde `lw`.
- **slli/srli/srai:** llevan `funct7` en `imm[11:5]` y `shamt` en `imm[4:0]`; `srai` se distingue de `srli` por el bit 30.

## Notas de implementación

- Inmediatos de B y J son offsets en bytes pares (bit 0 implícito en 0), con signo; rangos ±4 KiB (B) y ±1 MiB (J).
- `x0` siempre vale 0: las escrituras a `x0` se descartan.
- Los shifts de registro usan solo `rs2[4:0]`.
- Los loads/stores no alineados quedan fuera del alcance (ver D4).

## Instrucciones especiales

| Nombre | Codificación | Valor |
|--------|--------------|-------|
| NOP | `addi x0, x0, 0` | `0x00000013` |
| HALT | `ebreak` | `0x00100073` |
| Ilegal | cualquier palabra que no sea una de las 32 (ni `ebreak`), incluida `0x00000000` | se trata como HALT y levanta `illegal` |
