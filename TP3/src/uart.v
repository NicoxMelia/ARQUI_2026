`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart - UART completa: baud generator + receptor + transmisor + FIFOs
//
// Adaptada de TP2. Hacia la Debug Unit expone la misma interfaz tipo cola:
//      lectura : r_data / rd_uart / rx_empty
//      escritura: w_data / wr_uart / tx_full
//
// Cambios respecto de TP2:
//  - Parametros CLK_FREQ y BAUD en lugar de DVSR/DVSR_BIT (el divisor lo
//    calcula baud_gen). Por defecto 115200 baudios (D9).
//  - Sincronizador de dos flip-flops sobre rx adentro del modulo (en TP2
//    estaba en el top): la linea serie es asincronica al clock.
//  - Flags de error sticky, que la Debug Unit lee para responder NACK 0x05
//    (ver doc/protocolo_uart.md) y limpia con clr_err:
//      frame_err : llego un byte con el bit de stop en 0 (el byte se descarta)
//      rx_overrun: llego un byte con la FIFO de recepcion llena (se pierde)
//
// Detalle del lado Tx: mientras la FIFO de transmision no este vacia se
// mantiene tx_start en alto, y cada vez que el transmisor termina un byte
// (tx_done_tick) se saca ese byte de la cola. Asi se encadenan bytes solos.
//////////////////////////////////////////////////////////////////////////////

module uart
#(
    parameter DBIT       = 8,               // bits de datos
    parameter SB_TICK    = 16,              // ticks de stop (16 = 1 bit de stop)
    parameter CLK_FREQ   = 100_000_000,     // frecuencia del clock en Hz
    parameter BAUD       = 115200,          // baud rate (D9)
    parameter FIFO_W     = 4                // profundidad de las FIFOs = 2^FIFO_W
)
(
    input  wire             clk,
    input  wire             reset,      // sincronico, activo en alto

    // --- Interfaz con la logica interna ---
    input  wire             rd_uart,
    input  wire             wr_uart,
    input  wire [DBIT-1:0]  w_data,
    output wire [DBIT-1:0]  r_data,
    output wire             rx_empty,
    output wire             tx_full,

    // --- Errores de recepcion (sticky) ---
    input  wire             clr_err,    // pulso: limpia frame_err y rx_overrun
    output wire             frame_err,
    output wire             rx_overrun,

    // --- Lineas serie ---
    input  wire             rx,
    output wire             tx
);

    wire             tick;
    wire             rx_done_tick;
    wire             frame_err_tick;
    wire             tx_done_tick;
    wire             tx_empty;
    wire             tx_fifo_not_empty;
    wire             rx_full;
    wire [DBIT-1:0]  rx_data_out;
    wire [DBIT-1:0]  tx_fifo_out;

    reg              rx_meta, rx_sync;
    reg              frame_err_reg, rx_overrun_reg;

    // Sincronizador de rx (en reposo la linea esta en 1)
    always @(posedge clk) begin
        if (reset) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    baud_gen #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_baud_gen (
        .clk   (clk),
        .reset (reset),
        .tick  (tick)
    );

    uart_rx #(
        .DBIT    (DBIT),
        .SB_TICK (SB_TICK)
    ) u_uart_rx (
        .clk            (clk),
        .reset          (reset),
        .rx             (rx_sync),
        .s_tick         (tick),
        .rx_done_tick   (rx_done_tick),
        .frame_err_tick (frame_err_tick),
        .dout           (rx_data_out)
    );

    // FIFO de recepcion: la escribe el receptor, la lee la logica interna
    fifo #(
        .DATA_WIDTH (DBIT),
        .ADDR_WIDTH (FIFO_W)
    ) u_fifo_rx (
        .clk    (clk),
        .reset  (reset),
        .rd     (rd_uart),
        .wr     (rx_done_tick),
        .w_data (rx_data_out),
        .r_data (r_data),
        .empty  (rx_empty),
        .full   (rx_full)
    );

    // Flags sticky: quedan en 1 hasta clr_err (o reset). Si en el mismo ciclo
    // llega clr_err y un error nuevo, gana el error para no perderlo.
    // Overrun: la fifo no escribe si esta llena, aunque se lea en el mismo ciclo.
    always @(posedge clk) begin
        if (reset) begin
            frame_err_reg  <= 1'b0;
            rx_overrun_reg <= 1'b0;
        end
        else begin
            if (frame_err_tick)
                frame_err_reg <= 1'b1;
            else if (clr_err)
                frame_err_reg <= 1'b0;

            if (rx_done_tick && rx_full)
                rx_overrun_reg <= 1'b1;
            else if (clr_err)
                rx_overrun_reg <= 1'b0;
        end
    end

    assign frame_err  = frame_err_reg;
    assign rx_overrun = rx_overrun_reg;

    // FIFO de transmision: la escribe la logica interna, la lee el transmisor
    fifo #(
        .DATA_WIDTH (DBIT),
        .ADDR_WIDTH (FIFO_W)
    ) u_fifo_tx (
        .clk    (clk),
        .reset  (reset),
        .rd     (tx_done_tick),
        .wr     (wr_uart),
        .w_data (w_data),
        .r_data (tx_fifo_out),
        .empty  (tx_empty),
        .full   (tx_full)
    );

    assign tx_fifo_not_empty = ~tx_empty;

    uart_tx #(
        .DBIT    (DBIT),
        .SB_TICK (SB_TICK)
    ) u_uart_tx (
        .clk          (clk),
        .reset        (reset),
        .tx_start     (tx_fifo_not_empty),
        .s_tick       (tick),
        .din          (tx_fifo_out),
        .tx_done_tick (tx_done_tick),
        .tx           (tx)
    );

endmodule
