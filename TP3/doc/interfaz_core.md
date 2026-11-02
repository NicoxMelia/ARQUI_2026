# Interfaz Debug Unit <-> Core

Contrato entre la Debug Unit (`TP3/src/debug_unit.v`) y el core (`TP3/src/core.v`). El stub [`core_stub.v`](../src/core_stub.v) implementa exactamente estos puertos. Cualquier cambio se hace por PR con revisión de ambos.

Issues: SPEC-3 (#3, este documento), SPEC-2 (#2, protocolo UART), DBG-2 (#13), DBG-4/5 (#15, #27), CORE-10 (#26). Decisiones: D1, D8, D11 en [`decisiones.md`](decisiones.md). Diagrama del datapath en [`arquitectura.md`](arquitectura.md).

---

## 1. Señales

Dirección vista desde el core. Todo es síncrono a `clk`, un único clock sin modificar (D1).

### Control

| Señal | Ancho | Dir | Descripción |
|---|---|---|---|
| `clk` | 1 | in | Clock único. No se compuerta ni se divide. |
| `rst` | 1 | in | Reset global de placa (síncrono). Equivale a `core_reset`. |
| `ce` | 1 | in | Clock enable global. Con `ce=0` no cambian PC, latches, banco de registros, dmem, `halted`, `illegal` ni `dmem_hwm`. Se ignora mientras `reset_busy=1`. |
| `core_reset` | 1 | in | Pulso de ≥ 1 ciclo. Lleva el core al estado inicial (ver sección 2). Actúa con `ce=0`. No toca la imem. |
| `reset_busy` | 1 | out | En 1 mientras el core se limpia. Es combinacional con `core_reset`/`rst` (vale 1 en el mismo ciclo del pulso) y sigue en 1 hasta terminar el barrido de la dmem (≤ 1024 ciclos). La Debug Unit no sube `ce` mientras esté en 1. |

### Memoria de programa (loader)

| Señal | Ancho | Dir | Descripción |
|---|---|---|---|
| `imem_we` | 1 | in | Escribe una palabra por ciclo. No depende de `ce`. Solo se usa con el core detenido. |
| `imem_addr` | 10 | in | **Índice de palabra** (0..1023), no dirección de byte. |
| `imem_wdata` | 32 | in | Palabra a escribir. |

El relleno con ceros del resto de la imem tras un LOAD (D10) lo hace la Debug Unit escribiendo las palabras `len..1023`.

### Lectura de debug

| Señal | Ancho | Dir | Descripción |
|---|---|---|---|
| `dbg_reg_addr` | 5 | in | Registro a leer. |
| `dbg_reg_data` | 32 | out | Valor de `x[dbg_reg_addr]`. |
| `dbg_dmem_addr` | 10 | in | **Índice de palabra** de la dmem (0..1023). |
| `dbg_dmem_data` | 32 | out | Palabra leída. |

Ambos puertos funcionan con `ce=0` (la dmem usa un puerto aparte del pipeline). La Debug Unit debe asumir **latencia de 1 ciclo**: pone la dirección, espera un ciclo y recién entonces muestrea el dato (el banco puede ser combinacional, la dmem es una BRAM).

### Estado

| Señal | Ancho | Dir | Descripción |
|---|---|---|---|
| `halted` | 1 | out | Se decodificó (y no fue descartado por un salto) un `ebreak` o una instrucción ilegal: se dejó de buscar instrucciones. |
| `illegal` | 1 | out | La causa fue una instrucción ilegal (incluye `0x00000000`, D3). Implica `halted`. |
| `pipeline_empty` | 1 | out | Ningún latch (IF/ID, ID/EX, EX/MEM, MEM/WB) tiene una instrucción válida. |
| `dmem_hwm` | 13 | out | *High-water mark*: **mayor dirección de byte escrita + 1**. 0 = no se escribió nada desde el reset (D11). |
| `dbg_valid` | 4 | out | Bit i = el latch i tiene instrucción válida (no es burbuja): `[0]` IF/ID, `[1]` ID/EX, `[2]` EX/MEM, `[3]` MEM/WB. |

`halted && pipeline_empty` es la condición de fin de RUN del protocolo UART.

### Buses planos de debug

| Señal | Ancho | Dir | Contenido |
|---|---|---|---|
| `dbg_pc` | 32 | out | PC de la próxima instrucción a buscar. |
| `dbg_if_id` | 64 | out | Latch IF/ID (sección 3.1). |
| `dbg_id_ex` | 160 | out | Latch ID/EX (sección 3.2). |
| `dbg_ex_mem` | 80 | out | Latch EX/MEM (sección 3.3). |
| `dbg_mem_wb` | 80 | out | Latch MEM/WB (sección 3.4). |

---

## 2. Modelo de uso

- **Burbuja:** una posición de latch sin instrucción. Tiene `valid=0` y contenido en cero (el core debe ignorar el contenido cuando `valid=0`, incluido un IF/ID con `instr=0`, que no cuenta como ilegal).
- **Reset (`core_reset` / `rst`)**: PC=0, los 4 latches en burbuja, registros y dmem a cero, `halted`, `illegal` y `dmem_hwm` a cero. La dmem no se puede limpiar en un ciclo, por eso existe `reset_busy`. La imem no se toca.
- **Detenido:** el volcado se hace solo con `ce=0`. Con `ce=0` el estado del core es estable, así que registros y dmem se leen por sus puertos de dirección.
- **Snapshot:** al detenerse, la Debug Unit copia `dbg_pc` y los 4 buses de latches a un registro propio **un ciclo después** de que `ce` baja (evita carreras en el flanco de STOP) y serializa desde esa copia. Así el volcado es consistente aunque el core siga cambiando algo en el futuro (p. ej. un `core_reset`).
- **STEP con el core ya detenido** (`halted && pipeline_empty`): no cambia el estado. Una vez `halted`, el PC no avanza y los latches siguen en burbuja.
- Un PC fuera de la imem (`pc[31:12] != 0`) se busca como instrucción `0x00000000`, o sea ilegal (D3).

---

## 3. Formato de los latches

Cada bus se arma con el campo menos significativo en el bit 0 y se rellena con ceros en los bits altos hasta completar bytes. En el volcado se serializa **little-endian** (byte 0 = bits `[7:0]`), igual que el resto del protocolo.

### 3.1 IF/ID: 64 bits = 8 B

| Bits | Campo |
|---|---|
| `[31:0]` | `pc`: PC de la instrucción |
| `[63:32]` | `instr`: instrucción |

### 3.2 ID/EX: 157 bits -> 160 bits = 20 B

| Bits | Campo | Notas |
|---|---|---|
| `[31:0]` | `pc` | |
| `[63:32]` | `rs1_val` | valor leído del banco (antes de forwarding) |
| `[95:64]` | `rs2_val` | idem |
| `[127:96]` | `imm` | inmediato ya extendido |
| `[132:128]` | `rs1` | número de registro |
| `[137:133]` | `rs2` | |
| `[142:138]` | `rd` | |
| `[145:143]` | `funct3` | tamaño de acceso (loads/stores) y condición (branches) |
| `[149:146]` | `alu_op` | `{funct7[5], funct3}`, ver abajo |
| `[150]` | `reg_write` | |
| `[151]` | `mem_read` | |
| `[152]` | `mem_write` | |
| `[153]` | `branch` | beq/bne |
| `[154]` | `jal` | |
| `[155]` | `jalr` | |
| `[156]` | `alu_src_imm` | 1 = operando B es `imm` |
| `[159:157]` | 0 | relleno |

`alu_op` (4 bits), tomado directo de la instrucción para simplificar el decodificador:

| Op | `alu_op` | | Op | `alu_op` |
|---|---|---|---|---|
| ADD | 0000 | | OR | 0110 |
| SLL | 0001 | | AND | 0111 |
| SLT | 0010 | | SUB | 1000 |
| SLTU | 0011 | | PASS_B (`lui`) | 1001 |
| XOR | 0100 | | SRA | 1101 |
| SRL | 0101 | | | |

`jal`/`jalr` calculan el destino en EX y escriben `PC+4` como resultado (por eso el latch lleva `pc`). `ebreak`/ilegal se consumen en ID: no pasan a ID/EX.

### 3.3 EX/MEM: 75 bits -> 80 bits = 10 B

| Bits | Campo |
|---|---|
| `[31:0]` | `alu_result` (o `PC+4` en jal/jalr) |
| `[63:32]` | `store_data` (rs2 ya con forwarding) |
| `[68:64]` | `rd` |
| `[71:69]` | `funct3` |
| `[72]` | `reg_write` |
| `[73]` | `mem_read` |
| `[74]` | `mem_write` |
| `[79:75]` | 0 (relleno) |

### 3.4 MEM/WB: 74 bits -> 80 bits = 10 B

| Bits | Campo | Notas |
|---|---|---|
| `[31:0]` | `rdata` | salida de la dmem **sin extender**; la extensión de signo según `funct3` y `alu_result[1:0]` se hace en WB |
| `[63:32]` | `alu_result` | |
| `[68:64]` | `rd` | |
| `[71:69]` | `funct3` | |
| `[72]` | `reg_write` | |
| `[73]` | `mem_read` | 1 = escribir `rdata` extendido; 0 = `alu_result` |
| `[79:74]` | 0 | relleno |

---

## 4. Formato del volcado (payload del DUMP)

Payload de la trama `0x20` de [`protocolo_uart.md`](protocolo_uart.md): **181 bytes** (`133 + L`, con `L = 8 + 20 + 10 + 10 = 48`). A 115200 baudios, 185 B con encabezado tardan ≈ 16 ms.

| Offset | Largo | Contenido |
|---|---|---|
| 0 | 1 | `status` |
| 1 | 4 | `PC` (`dbg_pc`, little-endian) |
| 5 | 128 | `x0..x31`, 4 B cada uno, little-endian |
| 133 | 8 | IF/ID |
| 141 | 20 | ID/EX |
| 161 | 10 | EX/MEM |
| 171 | 10 | MEM/WB |

`status` (1 B):

| Bit | Señal |
|---|---|
| 0 | `halted` |
| 1 | `illegal` |
| 2 | `pipeline_empty` |
| 3 | `dbg_valid[0]` (IF/ID válido) |
| 4 | `dbg_valid[1]` (ID/EX) |
| 5 | `dbg_valid[2]` (EX/MEM) |
| 6 | `dbg_valid[3]` (MEM/WB) |
| 7 | 0 |

El rango de la dmem **no** va en el DUMP: se pide con READ_DMEM. Con `count = 0`, la Debug Unit devuelve `ceil(dmem_hwm / 4)` palabras desde `addr`.
