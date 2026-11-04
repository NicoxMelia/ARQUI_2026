`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// top_tp3 - Top level del TP3 para el hito M1 (INT-1)
//
//   PC <--USB/UART--> [ uart ] <--> [ debug_unit ] <--> [ core_stub ]
//                                                         (imem + PC + IF/ID)
//
// Es el mismo top que va a tener el TP3 final: cuando exista el core real
// (INT-3) se reemplaza core_stub por core, que tiene los mismos puertos.
//
// Punto de partida: TP2/src/top_uart_alu.v. A diferencia de TP2, el
// sincronizador de rx esta adentro de uart.v (DBG-1).
//
// Reset: el boton central (i_reset) se une con un reset de encendido de 16
// ciclos, asi la FPGA arranca en un estado conocido sin tocar el boton.
//
// Pines (Basys 3), ver constrs/constraints.xdc:
//      clk     -> W5   (100 MHz)
//      i_reset -> U18  (boton central)
//      i_rx    -> B18  (USB-UART, PC -> FPGA)
//      o_tx    -> A18  (USB-UART, FPGA -> PC)
//      o_led   -> LD0..LD15
//
// LEDs:
//      [12:0]  estado de la FSM de la Debug Unit (one-hot, ver fsm_state)
//      [13]    halted
//      [14]    illegal
//      [15]    pipeline_empty
//////////////////////////////////////////////////////////////////////////////

module top_tp3
#(
    parameter CLK_FREQ       = 100_000_000,
    parameter BAUD           = 115200,
    parameter TIMEOUT_CYCLES = CLK_FREQ / 100   // 10 ms entre bytes de una trama
)
(
    input  wire         clk,
    input  wire         i_reset,
    input  wire         i_rx,
    output wire         o_tx,
    output wire [15:0]  o_led
);

    // ------------------------------------------------------------------
    // Reset: boton OR reset de encendido
    // ------------------------------------------------------------------
    reg [3:0] por_cnt = 4'd0;
    wire      por     = ~&por_cnt;
    always @(posedge clk)
        if (por) por_cnt <= por_cnt + 4'd1;

    wire rst = i_reset | por;

    // ------------------------------------------------------------------
    // UART <-> Debug Unit
    // ------------------------------------------------------------------
    wire [7:0] r_data, w_data;
    wire       rd_uart, wr_uart, rx_empty, tx_full;
    wire       clr_err, frame_err, rx_overrun;

    uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_uart (
        .clk        (clk),
        .reset      (rst),
        .rd_uart    (rd_uart),
        .wr_uart    (wr_uart),
        .w_data     (w_data),
        .r_data     (r_data),
        .rx_empty   (rx_empty),
        .tx_full    (tx_full),
        .clr_err    (clr_err),
        .frame_err  (frame_err),
        .rx_overrun (rx_overrun),
        .rx         (i_rx),
        .tx         (o_tx)
    );

    // ------------------------------------------------------------------
    // Debug Unit <-> core
    // ------------------------------------------------------------------
    wire         ce, core_reset, reset_busy;
    wire         imem_we;
    wire [9:0]   imem_addr, dbg_dmem_addr;
    wire [31:0]  imem_wdata, dbg_reg_data, dbg_dmem_data, dbg_pc;
    wire [4:0]   dbg_reg_addr;
    wire         halted, illegal, pipeline_empty;
    wire [12:0]  dmem_hwm;
    wire [3:0]   dbg_valid;
    wire [63:0]  dbg_if_id;
    wire [159:0] dbg_id_ex;
    wire [79:0]  dbg_ex_mem, dbg_mem_wb;
    wire [12:0]  fsm_state;

    debug_unit #(
        .CLK_FREQ       (CLK_FREQ),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES)
    ) u_debug_unit (
        .clk            (clk),
        .reset          (rst),
        .rd_uart        (rd_uart),
        .rx_empty       (rx_empty),
        .r_data         (r_data),
        .wr_uart        (wr_uart),
        .tx_full        (tx_full),
        .w_data         (w_data),
        .clr_err        (clr_err),
        .frame_err      (frame_err),
        .rx_overrun     (rx_overrun),
        .ce             (ce),
        .core_reset     (core_reset),
        .reset_busy     (reset_busy),
        .imem_we        (imem_we),
        .imem_addr      (imem_addr),
        .imem_wdata     (imem_wdata),
        .dbg_reg_addr   (dbg_reg_addr),
        .dbg_reg_data   (dbg_reg_data),
        .dbg_dmem_addr  (dbg_dmem_addr),
        .dbg_dmem_data  (dbg_dmem_data),
        .halted         (halted),
        .illegal        (illegal),
        .pipeline_empty (pipeline_empty),
        .dmem_hwm       (dmem_hwm),
        .dbg_valid      (dbg_valid),
        .dbg_pc         (dbg_pc),
        .dbg_if_id      (dbg_if_id),
        .dbg_id_ex      (dbg_id_ex),
        .dbg_ex_mem     (dbg_ex_mem),
        .dbg_mem_wb     (dbg_mem_wb),
        .fsm_state      (fsm_state)
    );

    core_stub u_core (
        .clk            (clk),
        .rst            (rst),
        .ce             (ce),
        .core_reset     (core_reset),
        .imem_we        (imem_we),
        .imem_addr      (imem_addr),
        .imem_wdata     (imem_wdata),
        .dbg_reg_addr   (dbg_reg_addr),
        .dbg_reg_data   (dbg_reg_data),
        .dbg_dmem_addr  (dbg_dmem_addr),
        .dbg_dmem_data  (dbg_dmem_data),
        .halted         (halted),
        .illegal        (illegal),
        .pipeline_empty (pipeline_empty),
        .reset_busy     (reset_busy),
        .dmem_hwm       (dmem_hwm),
        .dbg_valid      (dbg_valid),
        .dbg_pc         (dbg_pc),
        .dbg_if_id      (dbg_if_id),
        .dbg_id_ex      (dbg_id_ex),
        .dbg_ex_mem     (dbg_ex_mem),
        .dbg_mem_wb     (dbg_mem_wb)
    );

    assign o_led = {pipeline_empty, illegal, halted, fsm_state};

endmodule
