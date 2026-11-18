# Programas de prueba

Cada programa tiene tres archivos con el mismo nombre:

| Archivo | Contenido |
|---|---|
| `<nombre>.s` | Fuente en assembly, con el resultado esperado de cada instrucción comentado. |
| `<nombre>.hex` | Imagen ensamblada: una palabra de 32 bits por línea (`$readmemh`, LOAD). |
| `<nombre>.expected.json` | Estado final esperado, calculado a mano. |

`make test-sw` verifica que cada `.hex` esté al día con su `.s`, que el simulador de referencia (`sw/riscv_sim.py`) llegue al estado del `.expected.json` y que los programas marcados `sin_forwarding` no tengan dependencias que el pipeline base no resuelve.

## Programas

Hito M2 (pipeline base: R, I aritmético-lógicas, `lui` y HALT, sin forwarding). Issue TEST-1 (#18).

| Programa | Qué prueba |
|---|---|
| `basico` | Programa corto (addi, add, sub, HALT) para CORE-5 e INT-3. |
| `aritmeticas` | add, sub, addi: overflow, wrap-around, negativos, x0 como destino y lectura de x0 mientras se intenta escribir (bypass del banco, D6). |
| `logicas` | and, or, xor, andi, ori, xori, con inmediatos negativos extendidos con signo. |
| `shifts` | sll, srl, sra, slli, srli, srai: cantidades 0 y 31, cantidades de registro ≥ 32 (solo `[4:0]`), sra con negativos. |
| `comparaciones` | slt, sltu, slti, sltiu sobre los mismos operandos con y sin signo; sltiu con inmediato negativo. |
| `inmediatos` | Extremos de ±2048 y extensión de signo. Inmediatos con el bit 30 en 1 (el `funct7[5]` de las R) para detectar un decodificador que arme `alu_op` con ese bit en las tipo I. |
| `lui` | lui con distintos valores, lui a x0, lui pisa los bits bajos, constantes de 32 bits con lui + addi. |

## Cómo correrlos

Desde `TP3/`:

```bash
python sw/assembler.py programs/basico.s                    # .s -> .hex (-l basico.lst para el listing)
make programs                                               # reensambla todos

python sw/check_program.py --all                            # simulador de referencia
python sw/check_program.py programs/basico --port COM5      # placa (Linux: /dev/ttyUSB1)
python sw/check_program.py programs/basico --dump out.txt   # volcado de una simulación del core
```

Con `--port` el checker hace LOAD, RUN hasta HALT, toma los registros del DUMP y lee la dmem con READ_DMEM hasta `dmem_hwm`. Sale con 0 si todo coincide y con 1 si algo falla, mostrando cada diferencia:

```
FALLA aritmeticas (COM5): 1 diferencia(s)
    x23: obtenido 0x0000012C, esperado 0x00000064
```

## Formato de `.expected.json`

```json
{
  "descripcion": "add, sub, addi: overflow, negativos y x0 como destino",
  "sin_forwarding": true,
  "halted": true,
  "illegal": false,
  "regs": { "x1": "0x80000000", "x10": 0 },
  "dmem": { "0x010": "0xDEADBEEF" }
}
```

- `regs`: registros `x0`..`x31`. **Los que no figuran tienen que valer 0.** Valores como número o string (`"0x..."`, decimal).
- `dmem`: palabras por dirección de byte alineada a 4. Las que no figuran tienen que valer 0 (solo se comparan las que se leyeron).
- `halted` / `illegal`: por defecto `true` / `false`.
- `sin_forwarding`: `true` si el programa corre en el pipeline base (hito M2). Entre una instrucción que escribe un registro y la primera que lo lee hay al menos dos instrucciones en el medio. Con el bypass interno del banco (D6) eso alcanza sin forwarding.

## Formato del volcado de simulación (`--dump`)

Archivo de texto que escribe el testbench del core al terminar. Una línea por dato, comentarios con `#` o `//`, números en hexa sin `0x`:

```
halted 1
illegal 0
x0 00000000
x1 00000005
...
x31 00000000
dmem 0010 deadbeef
```

Tienen que estar los 32 registros. `halted`, `illegal` y las líneas `dmem <dirección de byte> <palabra>` son opcionales (lo que no está no se compara). Con los puertos de debug del core se escribe así:

```verilog
integer f, r;
initial begin
    // ... esperar halted && pipeline_empty ...
    f = $fopen("build/basico.dump", "w");
    $fdisplay(f, "halted %0d", halted);
    $fdisplay(f, "illegal %0d", illegal);
    for (r = 0; r < 32; r = r + 1) begin
        dbg_reg_addr = r;
        @(posedge clk); #1;                 // latencia de 1 ciclo (interfaz_core.md)
        $fdisplay(f, "x%0d %h", r, dbg_reg_data);
    end
    $fclose(f);
end
```
