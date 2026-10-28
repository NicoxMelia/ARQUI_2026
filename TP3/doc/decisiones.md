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
