`timescale 1ns / 1ps
// Top level del TP2

//      PC  <--USB/UART-->  [ uart ]  <-->  [ intf ]  <-->  [ ALU ]

// Se envian 3 bytes (A, B, OP) y la placa contesta con 1 byte (resultado).
// La ALU es la misma del TP1, sin tocar una linea.

// Pines (Basys 3):
//      clk     -> W5   (100 MHz)
//      i_reset -> U18  (boton central)
//      i_rx    -> B18  (USB-UART, PC -> FPGA)
//      o_tx    -> A18  (USB-UART, FPGA -> PC)
//      o_led   -> LD0..LD15

// LEDs:
//      [7:0]   resultado de la ultima operacion
//      [8]     carry de la ultima operacion
//      [15:12] estado de la FSM del intf (one-hot: A, B, OP, SEND)


module top_uart_alu
#(
    parameter NB_DATA  = 8,
    parameter NB_OP    = 6,
    parameter DVSR     = 326,   // 100 MHz / (19200 * 16)
    parameter DVSR_BIT = 9
)
(
    input  wire         clk,
    input  wire         i_reset,
    input  wire         i_rx,
    output wire         o_tx,
    output wire [15:0]  o_led
);

    // Sincronizador de dos flip-flops para la linea serie
    
    reg rx_meta, rx_sync;
    always @(posedge clk) begin
        if (i_reset) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= i_rx;
            rx_sync <= rx_meta;
        end
    end

    // Interconexion uart <-> intf
    wire [NB_DATA-1:0] r_data;
    wire [NB_DATA-1:0] w_data;
    wire               rd_uart;
    wire               wr_uart;
    wire               rx_empty;
    wire               tx_full;

    // Interconexion intf <-> ALU
    wire [NB_DATA-1:0] alu_a;
    wire [NB_DATA-1:0] alu_b;
    wire [NB_OP-1:0]   alu_op;
    wire [NB_DATA-1:0] alu_result;
    wire               alu_carry;

    wire               carry_flag;
    wire [3:0]         intf_state;

    uart #(
        .DBIT     (NB_DATA),
        .SB_TICK  (16),
        .DVSR     (DVSR),
        .DVSR_BIT (DVSR_BIT),
        .FIFO_W   (4)
    ) u_uart (
        .clk      (clk),
        .reset    (i_reset),
        .rd_uart  (rd_uart),
        .wr_uart  (wr_uart),
        .w_data   (w_data),
        .r_data   (r_data),
        .rx_empty (rx_empty),
        .tx_full  (tx_full),
        .rx       (rx_sync),
        .tx       (o_tx)
    );

    intf #(
        .NB_DATA (NB_DATA),
        .NB_OP   (NB_OP)
    ) u_intf (
        .clk          (clk),
        .reset        (i_reset),
        .r_data       (r_data),
        .rx_empty     (rx_empty),
        .rd           (rd_uart),
        .w_data       (w_data),
        .wr           (wr_uart),
        .tx_full      (tx_full),
        .o_alu_a      (alu_a),
        .o_alu_b      (alu_b),
        .o_alu_op     (alu_op),
        .i_alu_result (alu_result),
        .i_alu_carry  (alu_carry),
        .o_carry_flag (carry_flag),
        .o_state      (intf_state)
    );

    // ALU del TP1
    ALU #(
        .N_BITS (NB_DATA),
        .N_OP   (NB_OP)
    ) u_alu (
        .in_a     (alu_a),
        .in_b     (alu_b),
        .in_op    (alu_op),
        .o_result (alu_result),
        .o_carry  (alu_carry)
    );

    assign o_led = {intf_state, 3'b000, carry_flag, alu_result};

endmodule
