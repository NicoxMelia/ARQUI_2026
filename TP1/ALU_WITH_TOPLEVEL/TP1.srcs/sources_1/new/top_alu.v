`timescale 1ns / 1ps

module top_alu
#(
    parameter NB_SWITCH = 8,
    parameter NB_RESULT = NB_SWITCH + 1,
    parameter NB_OP     = 6
)
(
    input  wire                   clk,
    input  wire [NB_SWITCH-1:0]   i_sw,
    input  wire                   btn_0,
    input  wire                   btn_1,
    input  wire                   btn_2,
    output wire [NB_RESULT-1:0]   o_leds
);

    reg  [NB_SWITCH-1:0] reg_data_a;
    reg  [NB_SWITCH-1:0] reg_data_b;
    reg  [NB_OP-1:0]     reg_op;

    wire [NB_SWITCH-1:0] alu_result;
    wire                 alu_carry;

    // Cada boton guarda en un registro el valor presente en los switches.
    always @(posedge clk) begin
        if (btn_0)
            reg_data_a <= i_sw;

        if (btn_1)
            reg_data_b <= i_sw;

        if (btn_2)
            reg_op <= i_sw[NB_OP-1:0];
    end

    ALU #(
        .N_BITS(NB_SWITCH),
        .N_OP  (NB_OP)
    )
    u_alu
    (
        .in_a    (reg_data_a),
        .in_b    (reg_data_b),
        .in_op   (reg_op),
        .o_result(alu_result),
        .o_carry (alu_carry)
    );

    // El LED mas significativo muestra el carry de la suma.
    assign o_leds = {alu_carry, alu_result};

endmodule
