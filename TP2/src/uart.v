`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart - UART completa: baud generator + receptor + transmisor + FIFOs
//
// Corresponde a los bloques "Baud Rate Generator", "Rx", "Tx" y el
// almacenamiento del "Interface Circuit" del diagrama del TP.
//
// Hacia afuera expone una interfaz tipo cola:
//      lectura : r_data / rd / rx_empty
//      escritura: w_data / wr / tx_full
//
// Detalle del lado Tx: mientras la FIFO de transmision no este vacia se
// mantiene tx_start en alto, y cada vez que el transmisor termina un byte
// (tx_done_tick) se saca ese byte de la cola. Asi se encadenan bytes solos.
//////////////////////////////////////////////////////////////////////////////

module uart
#(
    parameter DBIT       = 8,       // bits de datos
    parameter SB_TICK    = 16,      // ticks de stop (16 = 1 bit de stop)
    parameter DVSR       = 326,     // divisor del baud generator
    parameter DVSR_BIT   = 9,       // bits del contador del baud generator
    parameter FIFO_W     = 4        // profundidad de las FIFOs = 2^FIFO_W
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

    // --- Lineas serie ---
    input  wire             rx,
    output wire             tx
);

    wire             tick;
    wire             rx_done_tick;
    wire             tx_done_tick;
    wire             tx_empty;
    wire             tx_fifo_not_empty;
    wire [DBIT-1:0]  rx_data_out;
    wire [DBIT-1:0]  tx_fifo_out;

    baud_gen #(
        .M (DVSR),
        .N (DVSR_BIT)
    ) u_baud_gen (
        .clk   (clk),
        .reset (reset),
        .tick  (tick)
    );

    uart_rx #(
        .DBIT    (DBIT),
        .SB_TICK (SB_TICK)
    ) u_uart_rx (
        .clk          (clk),
        .reset        (reset),
        .rx           (rx),
        .s_tick       (tick),
        .rx_done_tick (rx_done_tick),
        .dout         (rx_data_out)
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
        .full   ()              // si se llena se pierden bytes (overrun)
    );

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
