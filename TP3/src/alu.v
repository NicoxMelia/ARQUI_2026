`timescale 1ns / 1ps

// alu: ALU combinacional de 32 bits del core (etapa EX).
//
// Parte de la ALU de TP1/TP2 (TP2/src/ALU.v), adaptada al RV32I:
//   - 32 bits en lugar de 8;
//   - op de 4 bits = {funct7[5], funct3}, segun doc/interfaz_core.md
//     (seccion 3.2), en lugar de los codigos de 6 bits estilo MIPS;
//   - se agregan sll, slt y sltu; se quitan nor y el carry;
//   - los shifts usan solo b[4:0] como cantidad (doc/isa.md);
//   - flag zero (result == 0) para beq/bne.
//
// Un op que no esta en la tabla devuelve 0.
//
// Issue: CORE-1 (#5).

module alu #(
    parameter N_BITS     = 32,
    parameter SHAMT_BITS = 5        // log2(N_BITS): bits de b que usan los shifts
) (
    input  wire [N_BITS-1:0] a,
    input  wire [N_BITS-1:0] b,
    input  wire [3:0]        op,
    output reg  [N_BITS-1:0] result,
    output wire              zero
);

    // alu_op = {funct7[5], funct3}
    localparam [3:0] OP_ADD    = 4'b0000;
    localparam [3:0] OP_SLL    = 4'b0001;
    localparam [3:0] OP_SLT    = 4'b0010;
    localparam [3:0] OP_SLTU   = 4'b0011;
    localparam [3:0] OP_XOR    = 4'b0100;
    localparam [3:0] OP_SRL    = 4'b0101;
    localparam [3:0] OP_OR     = 4'b0110;
    localparam [3:0] OP_AND    = 4'b0111;
    localparam [3:0] OP_SUB    = 4'b1000;
    localparam [3:0] OP_PASS_B = 4'b1001;   // lui
    localparam [3:0] OP_SRA    = 4'b1101;

    wire [SHAMT_BITS-1:0] shamt = b[SHAMT_BITS-1:0];

    always @(*) begin
        result = {N_BITS{1'b0}};

        case (op)
            OP_ADD:    result = a + b;
            OP_SUB:    result = a - b;
            OP_SLL:    result = a << shamt;
            OP_SRL:    result = a >> shamt;
            OP_SRA:    result = $signed(a) >>> shamt;
            OP_AND:    result = a & b;
            OP_OR:     result = a | b;
            OP_XOR:    result = a ^ b;
            OP_SLT:    result = {{(N_BITS-1){1'b0}}, $signed(a) < $signed(b)};
            OP_SLTU:   result = {{(N_BITS-1){1'b0}}, a < b};
            OP_PASS_B: result = b;
            default:   result = {N_BITS{1'b0}};
        endcase
    end

    assign zero = (result == {N_BITS{1'b0}});

endmodule
