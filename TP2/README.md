# TP2 - Máquinas de Estado Finitas: UART + ALU

Arquitectura de Computadoras - FCEFyN, UNC
Placa: **Basys 3** (Artix-7 `xc7a35tcpg236-1`, clock de 100 MHz)

Implementación de una UART completa (receptor, transmisor, generador de baud
rate y circuito de interfaz) que se comunica con la ALU del TP1. Desde una
terminal en la PC se mandan los operandos y la placa devuelve el resultado.

---

## Arquitectura

```
          ┌──────────────┐
  RX ────►│              │
          │              │ r_data / rd / rx_empty   ┌────────┐   a, b, op   ┌─────┐
          │     uart     │◄────────────────────────►│  intf  │◄────────────►│ ALU │
  TX ◄────│              │ w_data / wr / tx_full    │  FSM   │   result     │     │
          │              │                          └────────┘              └─────┘
          └──────────────┘
                 │
     baud_gen + uart_rx + uart_tx + 2 FIFOs
```

| Archivo | Qué hace |
|---|---|
| `src/baud_gen.v` | Contador módulo-M. Genera un *tick* a 16× el baud rate. |
| `src/uart_rx.v` | FSM del receptor: `IDLE → START → DATA → STOP`. Sobremuestrea 16× y muestrea cada bit en su punto medio. |
| `src/uart_tx.v` | FSM del transmisor: misma secuencia, saca un bit cada 16 ticks. |
| `src/fifo.v` | Buffer circular parametrizable. Desacopla el UART (lento) de la lógica interna (100 MHz). |
| `src/uart.v` | Junta baud_gen + rx + tx + las dos FIFOs. Expone una interfaz tipo cola. |
| `src/intf.v` | **Interface Circuit**: FSM que arma la operación (`LOAD_A → LOAD_B → LOAD_OP → SEND`). |
| `src/ALU.v` | La ALU del TP1, sin modificar. |
| `src/top_uart_alu.v` | Top level: sincronizador de `rx`, instancias y LEDs. |
| `sim/top_uart_alu_tb.v` | Testbench autochequeante de sistema. |
| `constrs/constraints.xdc` | Pines de la Basys 3. |
| `create_project.tcl` | Arma el proyecto de Vivado. |
| `test_uart.py` | Script de prueba desde la PC (pyserial). |

---

## Protocolo

| Sentido | Byte | Contenido |
|---|---|---|
| PC → FPGA | 1 | Dato **A** |
| PC → FPGA | 2 | Dato **B** |
| PC → FPGA | 3 | **Operación** (se usan los 6 bits bajos) |
| FPGA → PC | 4 | **Resultado** de la ALU |

Configuración serie: **19200 baud, 8 bits de datos, sin paridad, 1 bit de stop (8N1)**.

### Códigos de operación (los del TP1)

| Operación | Código |
|---|---|
| ADD | `100000` (0x20) |
| SUB | `100010` (0x22) |
| AND | `100100` (0x24) |
| OR  | `100101` (0x25) |
| XOR | `100110` (0x26) |
| NOR | `100111` (0x27) |
| SRL | `000010` (0x02) |
| SRA | `000011` (0x03) |

Cualquier otro código devuelve `0x00`.

---

## Cálculo del baud rate

El receptor sobremuestrea la línea 16 veces por bit, así que el tick tiene que
correr a `BaudRate × 16`:

```
M = Clock / (BaudRate × 16) = 100_000_000 / (19200 × 16) = 325.52 ≈ 326
```

El error de redondeo es del **0.15%**, muy por debajo del ~5% que tolera una
trama UART (el desfasaje se acumula sobre 10 bits antes de resincronizar con
el siguiente start).

Para cambiar el baud rate alcanza con tocar el parámetro `DVSR` del top:

| Baud | DVSR |
|---|---|
| 9600 | 651 |
| 19200 | 326 |
| 57600 | 109 |
| 115200 | 54 |

---

## Cómo levantarlo

### Proyecto de Vivado

```
Tools > Run Tcl Script...  →  create_project.tcl
```

Queda en `vivado/TP2.xpr`, con `top_uart_alu` como top de síntesis y
`top_uart_alu_tb` como top de simulación.

### Simulación

En Vivado: `Run Simulation > Run Behavioral Simulation`.
La consola tiene que imprimir `TEST PASSED: 0 errores`.

Con Icarus Verilog:

```bash
iverilog -g2005 -o sim.out src/*.v sim/top_uart_alu_tb.v
vvp sim.out
```

> El testbench instancia el top con `DVSR = 4` en vez de 326 para que la
> simulación no tarde una eternidad. Las FSM se comportan igual: lo único que
> cambia es cada cuántos ciclos llega el tick.

### En la placa

1. `Generate Bitstream` → `Program Device`.
2. Conectar el USB (el mismo de programación hace de puente serie).
3. Probar con el script:

```bash
pip install pyserial
python3 test_uart.py
```

O a mano con cualquier terminal serie en modo hexadecimal: mandar
`05 03 20` y tiene que volver `08`.

### LEDs

| LEDs | Significado |
|---|---|
| LD0–LD7 | Resultado de la última operación |
| LD8 | Carry |
| LD12–LD15 | Estado de la FSM del `intf` (one-hot: `LOAD_A`, `LOAD_B`, `LOAD_OP`, `SEND`) |

---

## Decisiones de diseño

**Codificación one-hot de los estados.** Es la recomendada para FPGA: usa más
flip-flops pero la lógica de próximo estado queda mínima, lo que da la máxima
frecuencia de operación. En un Artix-7 los FF sobran.

**Dos `always` separados.** Uno secuencial para el registro de estado y uno
combinacional para la lógica de próximo estado y las salidas, como pide la
lámina "Máquinas de estado en Verilog". Todas las señales tienen asignación
por defecto **antes** del `case` para evitar latches.

**`default` en todos los `case`.** Máquina de estado segura: ante un estado
inválido se vuelve al estado inicial en el ciclo siguiente.

**Sincronizador de dos flip-flops en `rx`.** La línea serie es asincrónica al
clock de 100 MHz; sin sincronizar hay riesgo de metaestabilidad justo en el
flanco del bit de start. El `.xdc` marca `set_false_path` sobre ese puerto.

**FIFOs entre la UART y la lógica interna.** A 19200 baud un byte tarda
~520 µs mientras el resto del sistema corre a 10 ns de período. Las colas
evitan perder bytes si llegan seguidos y permiten encadenar transmisiones sin
que la FSM tenga que esperar.

**La ALU no se tocó.** Es combinacional pura: alcanza con mantener A, B y OP
registrados en el `intf` y su salida es válida en el mismo ciclo. La FSM sólo
secuencia las lecturas y escrituras.
