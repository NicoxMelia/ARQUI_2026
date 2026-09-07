`timescale 1ns / 1ps

module ALU
#(
    parameter N_BITS = 8,
    parameter N_OP = 6
)
(
    input wire[N_BITS-1: 0] in_a,
    input wire[N_BITS-1: 0] in_b,
    input wire[N_OP-1:0] in_op,
    output reg[N_BITS-1:0] o_result,
    output reg o_carry
);

    always @(*) begin
        o_result = {N_BITS{1'b0}};
        o_carry = 1'b0;
        
        case(in_op)
            6'b100000: begin
                {o_carry, o_result} = in_a + in_b;
            end
            6'b100010: begin
                o_result = in_a - in_b;
            end
            6'b100100: begin
                o_result = in_a & in_b;
            end
            6'b100101: begin
                o_result = in_a | in_b;
            end
            6'b100110: begin
                o_result = in_a ^ in_b;
            end
            6'b100111: begin
                o_result = ~(in_a | in_b);
            end
            6'b000010: begin // SRL
                o_result = in_a >> in_b;
            end
            6'b000011: begin // SRA
                o_result = $signed(in_a) >>> in_b;
            end
            default: begin 
                o_result = {N_BITS{1'b0}}; // Ahora devuelve 00 en vez de FF
            end
        endcase
     end
endmodule
