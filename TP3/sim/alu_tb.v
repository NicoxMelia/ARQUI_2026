`timescale 1ns / 1ps

// Testbench autochequeante de alu: casos borde dirigidos (overflow, shifts
// de 0 y 31, cantidad de shift >= 32, signo en slt vs sltu, sra con
// negativos, flag zero, ops sin definir) y vectores aleatorios contra un
// modelo de referencia escrito de otra forma que el RTL.
//
// Issue: CORE-1 (#5).

module alu_tb;

    localparam [3:0] OP_ADD    = 4'b0000;
    localparam [3:0] OP_SLL    = 4'b0001;
    localparam [3:0] OP_SLT    = 4'b0010;
    localparam [3:0] OP_SLTU   = 4'b0011;
    localparam [3:0] OP_XOR    = 4'b0100;
    localparam [3:0] OP_SRL    = 4'b0101;
    localparam [3:0] OP_OR     = 4'b0110;
    localparam [3:0] OP_AND    = 4'b0111;
    localparam [3:0] OP_SUB    = 4'b1000;
    localparam [3:0] OP_PASS_B = 4'b1001;
    localparam [3:0] OP_SRA    = 4'b1101;

    reg  [31:0] a = 0;
    reg  [31:0] b = 0;
    reg  [3:0]  op = 0;
    wire [31:0] result;
    wire        zero;

    alu dut (.a(a), .b(b), .op(op), .result(result), .zero(zero));

    integer errors = 0;
    integer checks = 0;
    integer i;
    integer seed = 32'h5EED;

    // Modelo de referencia. slt sale de los bits de signo (no de $signed) y
    // sra de extender a 64 bits y desplazar logico.
    function [31:0] ref_alu(input [3:0] o, input [31:0] x, input [31:0] y);
        reg [63:0] ext;
        begin
            ext = {{32{x[31]}}, x};
            case (o)
                OP_ADD:    ref_alu = x + y;
                OP_SUB:    ref_alu = x + ~y + 32'd1;
                OP_SLL:    ref_alu = x << (y % 32);
                OP_SRL:    ref_alu = x >> (y % 32);
                OP_SRA:    ref_alu = ext >> (y % 32);
                OP_AND:    ref_alu = x & y;
                OP_OR:     ref_alu = x | y;
                OP_XOR:    ref_alu = x ^ y;
                OP_SLT:    ref_alu = (x[31] != y[31]) ? {31'b0, x[31]} : {31'b0, x < y};
                OP_SLTU:   ref_alu = {31'b0, x < y};
                OP_PASS_B: ref_alu = y;
                default:   ref_alu = 32'b0;
            endcase
        end
    endfunction

    // Aplica a, b y op, espera a que se estabilice y compara result y zero
    task check(input [3:0] o, input [31:0] x, input [31:0] y, input [31:0] exp);
        begin
            op = o; a = x; b = y;
            #1;
            checks = checks + 1;
            if (result !== exp || zero !== (exp == 0)) begin
                errors = errors + 1;
                $display("ERROR op=%b a=%h b=%h: result=%h zero=%b, esperado %h zero=%b",
                         o, x, y, result, zero, exp, exp == 0);
            end
        end
    endtask

    // Igual que check, pero el esperado sale del modelo de referencia
    task check_ref(input [3:0] o, input [31:0] x, input [31:0] y);
        begin
            check(o, x, y, ref_alu(o, x, y));
        end
    endtask

    initial begin
        // ---- add / sub: overflow y wrap-around ----
        check(OP_ADD, 32'd5,        32'd3,        32'd8);
        check(OP_ADD, 32'h7FFFFFFF, 32'd1,        32'h80000000);  // overflow con signo
        check(OP_ADD, 32'hFFFFFFFF, 32'd1,        32'h00000000);  // carry se pierde, zero=1
        check(OP_ADD, 32'h80000000, 32'h80000000, 32'h00000000);
        check(OP_ADD, 32'hFFFFFFFB, 32'd5,        32'h00000000);  // -5 + 5
        check(OP_SUB, 32'd5,        32'd3,        32'd2);
        check(OP_SUB, 32'd3,        32'd5,        32'hFFFFFFFE);  // -2
        check(OP_SUB, 32'h80000000, 32'd1,        32'h7FFFFFFF);  // overflow con signo
        check(OP_SUB, 32'h12345678, 32'h12345678, 32'h00000000);  // zero=1 (beq)
        check(OP_SUB, 32'h00000000, 32'h80000000, 32'h80000000);

        // ---- shifts: cantidad 0, 31 y solo b[4:0] ----
        check(OP_SLL, 32'h00000001, 32'd0,        32'h00000001);
        check(OP_SLL, 32'h00000001, 32'd31,       32'h80000000);
        check(OP_SLL, 32'h00000003, 32'd31,       32'h80000000);
        check(OP_SLL, 32'h00000001, 32'd32,       32'h00000001);  // 32 -> shamt 0
        check(OP_SLL, 32'h00000001, 32'd33,       32'h00000002);  // 33 -> shamt 1
        check(OP_SLL, 32'h0000000F, 32'hFFFFFFE4, 32'h000000F0);  // b=-28 -> shamt 4
        check(OP_SRL, 32'h80000000, 32'd0,        32'h80000000);
        check(OP_SRL, 32'h80000000, 32'd31,       32'h00000001);
        check(OP_SRL, 32'hFFFFFFFF, 32'd4,        32'h0FFFFFFF);  // lógico: entra 0
        check(OP_SRL, 32'h80000000, 32'd35,       32'h10000000);  // 35 -> shamt 3
        check(OP_SRA, 32'h80000000, 32'd0,        32'h80000000);
        check(OP_SRA, 32'h80000000, 32'd31,       32'hFFFFFFFF);
        check(OP_SRA, 32'hFFFFFFF0, 32'd2,        32'hFFFFFFFC);  // -16 >> 2 = -4
        check(OP_SRA, 32'h7FFFFFFF, 32'd31,       32'h00000000);  // positivo: entra 0
        check(OP_SRA, 32'h80000000, 32'd36,       32'hF8000000);  // 36 -> shamt 4
        check(OP_SRA, 32'hFFFFFFFF, 32'd31,       32'hFFFFFFFF);  // -1 >> n = -1

        // ---- lógicas ----
        check(OP_AND, 32'hF0F0F0F0, 32'h0FF00FF0, 32'h00F000F0);
        check(OP_AND, 32'hAAAAAAAA, 32'h55555555, 32'h00000000);
        check(OP_OR,  32'hF0F0F0F0, 32'h0FF00FF0, 32'hFFF0FFF0);
        check(OP_OR,  32'h00000000, 32'h00000000, 32'h00000000);
        check(OP_XOR, 32'hF0F0F0F0, 32'h0FF00FF0, 32'hFF00FF00);
        check(OP_XOR, 32'h12345678, 32'h12345678, 32'h00000000);
        check(OP_XOR, 32'h12345678, 32'hFFFFFFFF, 32'hEDCBA987);  // not

        // ---- slt vs sltu: mismo par de operandos, distinto signo ----
        check(OP_SLT,  32'hFFFFFFFF, 32'd1,        32'd1);        // -1 < 1
        check(OP_SLTU, 32'hFFFFFFFF, 32'd1,        32'd0);        // 0xFFFFFFFF > 1
        check(OP_SLT,  32'd1,        32'hFFFFFFFF, 32'd0);
        check(OP_SLTU, 32'd1,        32'hFFFFFFFF, 32'd1);
        check(OP_SLT,  32'h80000000, 32'h7FFFFFFF, 32'd1);        // min < max
        check(OP_SLTU, 32'h80000000, 32'h7FFFFFFF, 32'd0);
        check(OP_SLT,  32'h7FFFFFFF, 32'h80000000, 32'd0);
        check(OP_SLT,  32'hFFFFFFFE, 32'hFFFFFFFF, 32'd1);        // -2 < -1
        check(OP_SLTU, 32'hFFFFFFFE, 32'hFFFFFFFF, 32'd1);
        check(OP_SLT,  32'd7,        32'd7,        32'd0);        // iguales
        check(OP_SLTU, 32'd7,        32'd7,        32'd0);
        check(OP_SLTU, 32'd0,        32'd1,        32'd1);        // seqz: x < 1
        check(OP_SLTU, 32'd0,        32'd0,        32'd0);
        check(OP_SLT,  32'h80000000, 32'h80000000, 32'd0);

        // ---- pass_b (lui) ----
        check(OP_PASS_B, 32'hDEADBEEF, 32'h12345000, 32'h12345000);
        check(OP_PASS_B, 32'hFFFFFFFF, 32'h00000000, 32'h00000000);

        // ---- ops que no estan en la tabla: devuelven 0 ----
        check(4'b1010, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h0);
        check(4'b1011, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h0);
        check(4'b1100, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h0);
        check(4'b1110, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h0);
        check(4'b1111, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'h0);

        // ---- aleatorios: todas las ops (incluidas las no definidas) ----
        for (i = 0; i < 4000; i = i + 1)
            check_ref(i % 16, $random(seed), $random(seed));
        // Operandos chicos para que slt/sltu y sub den cero y uno seguido
        for (i = 0; i < 1000; i = i + 1)
            check_ref(i % 16, $random(seed) % 4, $random(seed) % 4);

        $display("%0d chequeos", checks);
        if (errors == 0) $display("TEST PASSED: 0 errores");
        else             $display("TEST FAILED: %0d errores", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
