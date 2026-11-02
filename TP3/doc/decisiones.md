# Decisiones de diseño

Registro de decisiones del TP3. Cada quien anota sus decisiones al tomarlas, con el número reservado en la issue correspondiente.

Plantilla:

```markdown
## Dn - Título

- **Contexto:** qué problema hay que resolver.
- **Opciones:** alternativas consideradas.
- **Elección:** qué se decidió.
- **Por qué:** justificación (números si los hay).
- **Issue:** #N
```

---

## D9 - Baud rate de la UART: 115200

- **Contexto:** TP2 usaba 19200 baudios. En TP3 la UART carga programas de hasta 1024 palabras (4 KB) y transmite volcados de ~200 B en cada STEP.
- **Opciones:** 19200 (como TP2), 115200, velocidades mayores (230400 o más).
- **Elección:** 115200, 8N1, parametrizado con `CLK_FREQ` y `BAUD` (`DVSR = CLK_FREQ / (16·BAUD)`).
- **Por qué:** cargar 4 KB tarda ≈ 2,1 s a 19200 y ≈ 0,36 s a 115200; un volcado pasa de ≈ 100 ms a ≈ 17 ms. A 100 MHz, DVSR = 54 con error de 0,47 %, muy por debajo de la tolerancia de 8N1. Es una velocidad estándar que soportan el FT2232 de la Basys 3 y pyserial. Al estar parametrizado, si cambia la frecuencia del clock (TIME-3) el divisor se recalcula solo.
- **Issue:** #2, #12

## D10 - LOAD hace reset completo del core

- **Contexto:** al cargar un programa nuevo puede quedar estado del anterior (registros, dmem, latches, instrucciones viejas en imem si el programa nuevo es más corto).
- **Opciones:** (a) LOAD solo escribe la imem; (b) LOAD hace reset completo y rellena con ceros el resto de imem.
- **Elección:** (b). Antes de escribir: PC=0, flush del pipeline, registros y dmem a 0; después de los datos, el resto de la imem queda en cero.
- **Por qué:** ejecuciones reproducibles: el resultado de un programa no depende de lo que se haya corrido antes. El relleno con ceros hace que un programa sin HALT termine en una instrucción ilegal (0x00000000) en lugar de ejecutar código viejo.
- **Issue:** #2, #14

## D12 - Comandos recibidos durante RUN

- **Contexto:** mientras el core corre en modo continuo puede llegar cualquier byte por la UART.
- **Opciones:** (a) atender todos los comandos; (b) responder NACK BUSY a todo menos STOP; (c) atender solo STOP y descartar el resto.
- **Elección:** (c). RUN termina siempre con un único DUMP, ya sea por HALT o por STOP.
- **Por qué:** es la opción más simple en hardware y evita interpretar a medias tramas con argumentos (por ejemplo, los datos de un LOAD contienen bytes que coinciden con códigos de comando). La librería del PC no permite enviar otros comandos durante RUN, así que el descarte no pierde información útil. Detalle en `protocolo_uart.md`, sección 5.
- **Issue:** #2

## D13 - Receptor UART: errores de trama, overrun y detección del start

- **Contexto:** la UART de TP2 no verificaba el bit de stop y descartaba en silencio los bytes que llegaban con la FIFO de recepción llena. El protocolo (`protocolo_uart.md`) necesita detectar ambos casos para responder NACK `0x05`.
- **Opciones:** (a) guardar el byte con error y marcarlo; (b) descartarlo y levantar un flag; para el start, detectar por nivel (TP2) o por flanco.
- **Elección:** (b), con flags sticky `frame_err` y `rx_overrun` que la Debug Unit limpia con `clr_err`. El start se detecta por flanco de bajada y se vuelve a verificar en el medio del bit (si la línea volvió a 1 era un glitch). El sincronizador de `rx` pasa a estar adentro de `uart.v`.
- **Por qué:** un byte con error no sirve para nada en el protocolo: la trama entera se descarta. Por nivel, después de un error de trama la línea sigue en 0 hasta el final del stop y el receptor lo tomaba como un start nuevo y quedaba desincronizado (lo detectó `uart_tb`). Con el sincronizador adentro, cualquier top que use la UART queda protegido contra metaestabilidad.
- **Issue:** #12
## D2 - NOP y HALT

- **Contexto:** hace falta una instrucción que no haga nada (burbujas, relleno) y una forma de detener el core.
- **Opciones:** NOP como `addi x0,x0,0` u otra codificación; HALT como `ebreak`, un `jal` a sí mismo o un opcode propio.
- **Elección:** NOP = `addi x0, x0, 0` (`0x00000013`); HALT = `ebreak` (`0x00100073`).
- **Por qué:** ambas son las codificaciones canónicas de RISC-V, así que cualquier ensamblador estándar las produce y no inventamos un opcode propio. `ebreak` es una instrucción real de la ISA, distinta de las 32 del set, y se decodifica comparando la palabra completa.
- **Issue:** #1

## D3 - Instrucción ilegal = HALT con flag `illegal`

- **Contexto:** qué pasa si el programa no tiene instrucción de parada, o si el PC cae en memoria sin programa.
- **Opciones:** (a) ignorar la instrucción y seguir; (b) tratarla como NOP; (c) detener el core y avisar.
- **Elección:** (c). Toda palabra que no decodifica a una de las 32 instrucciones (ni `ebreak`), incluida `0x00000000`, se trata como HALT y levanta el flag `illegal`, que se informa en el DUMP.
- **Por qué:** con (a) o (b) un programa sin HALT correría hasta recorrer toda la imem. Como LOAD rellena el resto de imem con ceros (D10), un programa sin parada termina siempre en `0x00000000`, se detiene y el flag distingue "terminó por ebreak" de "se cayó fuera del programa".
- **Issue:** #1

## D4 - Direccionamiento de memoria y PC

- **Contexto:** unidad de direccionamiento y alineación de instrucciones y datos.
- **Opciones:** memoria direccionada por palabra o por byte.
- **Elección:** memoria direccionada por byte; instrucciones de 32 bits alineadas a 4; el PC avanza de a 4. Lecturas y escrituras de `lh/lhu/sh` y `lw/sw` se asumen alineadas (a 2 y 4); el comportamiento ante desalineación no está especificado.
- **Por qué:** es el modelo de RV32I, y `lb/lbu/sb` obligan a acceder por byte. Usar la misma convención que el ensamblador evita conversiones de offsets en `beq`/`bne`/`jal`.
- **Issue:** #1
