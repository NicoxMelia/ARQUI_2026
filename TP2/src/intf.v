`timescale 1ns / 1ps

// Interface Circuit (Maquina de Estado que controla entre el UART y la ALU)

// Protocolo sobre la linea serie (3 bytes entran, 1 byte sale):

//      PC -> FPGA : byte 1 = dato A
//      PC -> FPGA : byte 2 = dato B
//      PC -> FPGA : byte 3 = codigo de operacion (se usan los 6 bits bajos)
//      FPGA -> PC : byte 4 = resultado de la ALU

// Estados: LOAD_A, LOAD_B, LOAD_OP, SEND


module intf
#(
    parameter NB_DATA = 8,
    parameter NB_OP   = 6
)
(
    input  wire                     clk,
    input  wire                     reset,          // activo en alto

    // Lado FIFO de recepcion
    input  wire [NB_DATA-1:0]       r_data,
    input  wire                     rx_empty,
    output reg                      rd,

    // Lado FIFO de transmision
    output wire [NB_DATA-1:0]       w_data,
    output reg                      wr,
    input  wire                     tx_full,

    // Lado ALU
    output wire [NB_DATA-1:0]       o_alu_a,
    output wire [NB_DATA-1:0]       o_alu_b,
    output wire [NB_OP-1:0]         o_alu_op,
    input  wire [NB_DATA-1:0]       i_alu_result,
    input  wire                     i_alu_carry,

    // Debug / LEDs
    output wire                     o_carry_flag,
    output wire [3:0]               o_state
);

    localparam [3:0] LOAD_A  = 4'b0001,
                     LOAD_B  = 4'b0010,
                     LOAD_OP = 4'b0100,
                     SEND    = 4'b1000;

    reg [3:0]         state_reg, state_next;
    reg [NB_DATA-1:0] a_reg,     a_next;
    reg [NB_DATA-1:0] b_reg,     b_next;
    reg [NB_OP-1:0]   op_reg,    op_next;
    reg               carry_reg, carry_next;

    // Memoria
    always @(posedge clk) begin
        if (reset) begin
            state_reg <= LOAD_A;
            a_reg     <= {NB_DATA{1'b0}};
            b_reg     <= {NB_DATA{1'b0}};
            op_reg    <= {NB_OP{1'b0}};
            carry_reg <= 1'b0;
        end
        else begin
            state_reg <= state_next;
            a_reg     <= a_next;
            b_reg     <= b_next;
            op_reg    <= op_next;
            carry_reg <= carry_next;
        end
    end

    // Logica de proximo estado
    always @(*) begin
        state_next = state_reg;
        a_next     = a_reg;
        b_next     = b_reg;
        op_next    = op_reg;
        carry_next = carry_reg;
        rd         = 1'b0;
        wr         = 1'b0;

        case (state_reg)
            LOAD_A: begin
                if (~rx_empty) begin
                    rd         = 1'b1;
                    a_next     = r_data;
                    state_next = LOAD_B;
                end
            end

            LOAD_B: begin
                if (~rx_empty) begin
                    rd         = 1'b1;
                    b_next     = r_data;
                    state_next = LOAD_OP;
                end
            end

            LOAD_OP: begin
                if (~rx_empty) begin
                    rd         = 1'b1;
                    op_next    = r_data[NB_OP-1:0];
                    state_next = SEND;
                end
            end

            SEND: begin
                if (~tx_full) begin
                    wr         = 1'b1;
                    carry_next = i_alu_carry;   // se engancha para el LED
                    state_next = LOAD_A;
                end
            end

            default: state_next = LOAD_A;       // Recuperacion ante fallos
        endcase
    end

    assign o_alu_a      = a_reg;
    assign o_alu_b      = b_reg;
    assign o_alu_op     = op_reg;
    assign w_data       = i_alu_result;
    assign o_carry_flag = carry_reg;
    assign o_state      = state_reg;

endmodule
