# CLAUDE.md

Repo de los prácticos de Arquitectura de Computadoras (FCEFyN, UNC), placa **Basys 3** (Artix-7 `xc7a35tcpg236-1`, 100 MHz).
Equipo de dos: Persona A (core) = NicoxMelia · Persona B (debug y software) = LauCallovi.

| Carpeta | Estado |
|---|---|
| `TP1/` | ALU. Cerrado, no tocar salvo pedido explícito. |
| `TP2/` | UART + ALU. Cerrado, se usa como referencia de estilo. |
| `TP3/` | **Trabajo activo**: pipeline RISC-V RV32I de 5 etapas + Debug Unit por UART. |

## Fuentes de verdad (leer antes de tocar algo de TP3)

- Issues y milestones de GitHub (`NicoxMelia/ARQUI_2026`): mandan sobre cualquier archivo. `TP3/doc/PLAN.md` es solo un resumen.
- `TP3/doc/isa.md` — las 32 instrucciones, encodings, NOP/HALT. `TP3/sw/isa_table.py` debe coincidir con este archivo.
- `TP3/doc/protocolo_uart.md` — tramas PC ↔ Debug Unit, NACKs, timeouts, RUN/STOP.
- `TP3/doc/interfaz_core.md` — puertos Debug Unit ↔ core, formato de latches y del DUMP (181 B).
- `TP3/doc/arquitectura.md` — datapath y unidades de control.
- `TP3/doc/decisiones.md` — decisiones D1..Dn. No contradecir una decisión existente sin proponerlo explícitamente.

Los documentos son **contratos** entre los dos integrantes: si un cambio de RTL o software altera un contrato, se actualiza el doc en el mismo PR y se avisa en la descripción.

## Flujo de trabajo (obligatorio)

1. **Una rama por issue**, siempre creada desde `develop` actualizado:
   ```bash
   git checkout develop && git pull origin develop
   git checkout -b feat/<ID>-<slug>      # ej: feat/DBG-2-fsm, feat/CORE-1-alu
   ```
   `<ID>` es el prefijo de la issue (SPEC, INFRA, DBG, MEM, CORE, SW, TEST, INT, TIME, DOC). Nunca mezclar dos issues en una rama.
2. Si no hay issue para el trabajo pedido, preguntar antes de crear rama (o proponer crear la issue).
3. Nunca commitear ni pushear directo a `develop` ni a `main`. `main` solo recibe merges de `develop` al cerrar un hito.
4. El PR va de la rama a `develop`, usa `.github/pull_request_template.md`, lleva `Closes #N`, copia y tilda los criterios de aceptación de la issue, y necesita la aprobación del otro integrante. No mergear PRs por cuenta propia.
5. Si `develop` avanzó, traerlo a la rama con merge (`git merge develop`), no reescribir historia ya pusheada.
6. Commits en español, estilo Conventional Commits con el ID de la issue al final:
   `feat: FSM de la Debug Unit con timeout de recepción (DBG-2)` — tipos usados: `feat`, `fix`, `docs`, `chore`, `test`.
7. Commitear o pushear solo cuando se pida.

## Convenciones de código

**Verilog** (las de TP2, uniformes en todo el repo):
- Verilog-2001 (`.v`), compatible con `iverilog -g2005 -Wall` y con Vivado. Nada de SystemVerilog.
- Reset **síncrono activo en alto**. Un único clock: el core se controla solo con `ce` (D1), nunca compuertar ni dividir el clock.
- FSM one-hot con dos `always` (secuencial + combinacional), valores por defecto antes del `case` y `default` en **todos** los `case`.
- Prefijos `i_`/`o_` en los puertos de los tops. Parámetros en lugar de números mágicos (ej. `CLK_FREQ`, `BAUD`).
- Comentario de cabecera en cada módulo explicando qué hace y qué decisión/issue implementa. Comentarios en español.
- Memorias detrás de un wrapper (D7). Programas en `.hex` (una palabra de 32 bits por línea), no `.mem`.
- El RTL del core y de la Debug Unit no debe depender de IP de Xilinx, para poder probarse entero con Icarus. Lo que sí dependa se marca con `// REQUIERE_VIVADO: <motivo>` y se lista en la sección "Requiere Vivado" del PR.

**Testbenches** (`TP3/sim/<nombre>_tb.v`, módulo top `<nombre>_tb`):
- Autochequeantes, con contador de errores. Terminan imprimiendo exactamente `TEST PASSED: 0 errores` o `TEST FAILED: N errores`, y tienen timeout.
- Todo módulo nuevo en `src/` viene con su testbench en el mismo PR.

**Python** (`TP3/sw/`): Python 3, dependencias en `TP3/requirements.txt` (hoy solo `pyserial`). La codificación de instrucciones sale de `isa_table.py`, no se duplica.

## Verificación antes de dar algo por terminado

Desde `TP3/`:
```bash
make list              # testbenches disponibles
make sim TB=uart_tb    # corre uno
make test              # corre todos; es lo mismo que corre el CI
make vivado-only       # lo que solo se prueba en Vivado
```
- El check **TP3 - simulacion (Icarus)** de GitHub Actions corre `make test` en cada PR a `develop`/`main`. Tiene que estar en verde.
- No afirmar que algo funciona en placa, sintetiza o cumple timing sin haberlo corrido en Vivado: indicarlo como pendiente en "Requiere Vivado".

## Decisiones de diseño

- Toda decisión nueva se anota en `TP3/doc/decisiones.md` **en el mismo PR**, con la plantilla del archivo (Contexto / Opciones / Elección / Por qué / Issue).
- Usar el número reservado en `PLAN.md` si existe; si no, el siguiente libre (hoy el último usado es D13).

## Lo que no se versiona

- Proyecto de Vivado (`TP3/vivado/`, `.runs/`, `.cache/`, `.bit`, `.dcp`, logs). Se regenera con `TP3/create_project.tcl`.
- `TP3/build/` (salida de Icarus), `__pycache__/`, `.venv/`.
- Ojo: `.gitignore` ignora `*.txt`, `*.xml`, `*.sh`, `*.mem`, `*.log`, `*.rpt`. Si hace falta versionar uno de esos, agregar la excepción `!ruta` (como ya se hace con `TP3/requirements.txt` y `TP3/doc/timing/`).

## Entorno

- Se trabaja en Windows (Vivado 2024) y el CI corre en Ubuntu. Los scripts y el `Makefile` asumen shell POSIX: correrlos desde Git Bash/WSL.
- Rutas relativas a `TP3/` en `$readmemh` (vvp y xsim corren desde ahí).
