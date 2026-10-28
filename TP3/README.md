# TP3 - Pipeline RISC-V (RV32I) con Debug Unit

Arquitectura de Computadoras - FCEFyN, UNC
Placa: **Basys 3** (Artix-7 `xc7a35tcpg236-1`, clock de 100 MHz)

Procesador RISC-V de 5 etapas (IF, ID, EX, MEM, WB) con forwarding, detección de riesgos y una Debug Unit que, por UART, carga programas, ejecuta en modo continuo o paso a paso y vuelca el estado (PC, registros, latches y memoria de datos) a la PC.

El plan de trabajo está en [`doc/PLAN.md`](doc/PLAN.md) y las decisiones de diseño en [`doc/decisiones.md`](doc/decisiones.md).

---

## Estructura

| Carpeta | Contenido |
|---|---|
| `src/` | RTL en Verilog-2001 (`.v`) |
| `sim/` | Testbenches autochequeantes (`<nombre>_tb.v`) |
| `constrs/` | Constraints de la Basys 3 (`constraints.xdc`) |
| `sw/` | Software de PC en Python: ensamblador, cliente serie, CLI |
| `programs/` | Programas de prueba (`.s`) y su imagen ensamblada (`.hex`) |
| `doc/` | Especificaciones, decisiones y reportes (`doc/timing/`) |
| `create_project.tcl` | Arma el proyecto de Vivado |
| `Makefile` | Simulación con Icarus Verilog |
| `requirements.txt` | Dependencias de Python |

## Cómo levantarlo

### Proyecto de Vivado

```
Tools > Run Tcl Script...  →  create_project.tcl
```

Queda en `vivado/TP3.xpr` (no se versiona: se regenera con el script). Los tops son `top_tp3` (síntesis) y `top_tp3_tb` (simulación); el script los setea solo si los archivos ya existen.

### Simulación con Icarus

```bash
make list              # testbenches disponibles
make sim TB=alu_tb     # corre uno
make test              # corre todos; falla si alguno no imprime "TEST PASSED: 0 errores"
```

### Software de PC

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Convenciones

**Código** (las de TP2, para que todo el repo sea uniforme):

- Verilog-2001 (`.v`), reset síncrono activo en alto.
- FSM con estados one-hot y dos `always` (secuencial + combinacional), con valores por defecto antes del `case` y `default` en todos los `case`.
- Prefijos `i_`/`o_` en los puertos de los tops.
- Testbench autochequeante que termina imprimiendo `TEST PASSED: 0 errores` (o `TEST FAILED: N errores`).
- Programas en `.hex` (una palabra de 32 bits por línea), no `.mem`.

**Flujo de trabajo:**

- Una rama por issue, con nombre `feat/<ID>-slug` (por ejemplo `feat/CORE-1-alu`, `feat/SPEC-2-protocolo-uart`).
- Las ramas salen de `develop` y vuelven por PR a `develop`. `main` solo recibe merges de `develop` en los hitos.
- Cada PR usa la plantilla (`.github/pull_request_template.md`), referencia su issue y necesita la aprobación del otro integrante.
- Toda decisión de diseño se anota en `doc/decisiones.md` en el mismo PR en que se toma.
