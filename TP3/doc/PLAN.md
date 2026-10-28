# Plan de trabajo - TP3

Fuente de verdad: las [issues](https://github.com/NicoxMelia/ARQUI_2026/issues) y los [milestones](https://github.com/NicoxMelia/ARQUI_2026/milestones) de GitHub. Este archivo es un resumen para orientarse; si algo no coincide, manda GitHub.

**Roles:** Persona A (core) = @NicoxMelia · Persona B (debug y software) = @LauCallovi

## Hitos

| Hito | Fecha | Objetivo |
|---|---|---|
| M0 - Contratos | 23/10 | ISA y encodings, protocolo UART, interfaz Debug-Core y carpeta TP3 lista |
| M1 - Debug Unit + imem | 30/10 | En FPGA, con un `core_stub`: cargar un programa por UART, dar pasos y volcar el estado |
| M2 - Core base integrado | 04/11 | El pipeline base (R, I, lui, HALT) reemplaza al stub: ensamblar, cargar, ejecutar y volcar en la placa |
| M3 - Pipeline completo | 11/11 | Todas las instrucciones y hazards funcionando en FPGA. Feature freeze el 13/11 |
| M4 - Timing, docs y entrega | 18/11 | Análisis de timing, documentación y demo. 19-21/11 es colchón |

## Issues por hito

### M0 - Contratos
| Issue | Título | Dueño |
|---|---|---|
| #1 | SPEC-1 Set de instrucciones, encodings, NOP y HALT | A |
| #2 | SPEC-2 Protocolo UART entre PC y Debug Unit | B |
| #3 | SPEC-3 Interfaz Debug Unit <-> Core, formato de volcado y diagrama de bloques | A |
| #4 | INFRA-1 Carpeta TP3: estructura, create_project.tcl, .gitignore y reglas de PR | B |

### M1 - Debug Unit + imem
| Issue | Título | Dueño |
|---|---|---|
| #9 | MEM-1 Memoria de programa con puerto de escritura para el loader | A |
| #12 | DBG-1 UART adaptada de TP2 | B |
| #13 | DBG-2 FSM de la Debug Unit | B |
| #14 | DBG-3 Loader | B |
| #15 | DBG-4 Dumper básico | B |
| #17 | SW-2 Cliente serie y librería del protocolo | B |
| #19 | INT-1 Debug Unit + imem + core_stub en la FPGA | A |

### M2 - Core base integrado
| Issue | Título | Dueño |
|---|---|---|
| #5 | CORE-1 ALU con las 10 operaciones | B |
| #6 | CORE-2 Banco de registros | A |
| #7 | CORE-3 Generador de inmediatos | A |
| #8 | CORE-4 Unidad de control | A |
| #10 | MEM-2 Memoria de datos | A |
| #11 | CORE-5 Pipeline base sin hazards | A |
| #16 | SW-1 Ensamblador RISC-V en Python | B |
| #18 | TEST-1 Programas de prueba R/I/lui y checker | B |
| #20 | INT-3 Core base en la FPGA | A |

### M3 - Pipeline completo
| Issue | Título | Dueño |
|---|---|---|
| #21 | TIME-1 Primera síntesis e implementación (reporte base) | B |
| #22 | CORE-6 Datapath completo: loads, stores, branches, jal, jalr | A |
| #23 | CORE-7 Unidad de forwarding | A |
| #24 | CORE-8 Riesgo load-use y stall | A |
| #25 | CORE-9 Control de saltos y flush | A |
| #26 | CORE-10 HALT y drenado del pipeline | A |
| #27 | DBG-5 Dumper completo | B |
| #28 | TEST-2 Programas de prueba completos | B |
| #29 | SW-3 Interfaz CLI | B |
| #30 | INT-2 Integración completa y regresión | B |

### M4 - Timing, docs y entrega
| Issue | Título | Dueño |
|---|---|---|
| #31 | SW-4 TUI con vista del pipeline (deseable) | B |
| #32 | TIME-2 Camino crítico, skew y frecuencia óptima | A |
| #33 | TIME-3 Clock Wizard y re-parametrización del baud | B |
| #34 | DOC-1 Documento de decisiones de diseño | A |
| #35 | DOC-2 Respuestas a las preguntas de la consigna | B |
| #36 | DOC-3 Demo y entrega | A y B |

## Decisiones reservadas

| Id | Tema | Issue |
|---|---|---|
| D1 | El clock no se toca: control del core solo por `ce` | #13, #3 |
| D2-D4 | NOP, HALT, instrucción ilegal y direccionamiento | #1 |
| D5 | Resolución de saltos en EX | #25 |
| D6 | Bypass interno del banco de registros | #6 |
| D7 | Memorias detrás de un wrapper | #9, #10 |
| D8 | Interfaz Debug Unit <-> Core | #3 |
| D9 | Baud rate 115200 | #2, #12 |
| D10 | LOAD hace reset completo | #2, #14 |
| D11 | `dmem_hwm` y volcado del rango usado | #3, #27 |

Las decisiones nuevas toman el siguiente número libre y se anotan en `decisiones.md`.
