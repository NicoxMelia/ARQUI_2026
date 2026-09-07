`timescale 1ns/1ps

// Testbench autochequeante para la ALU.
module alu_tb;

    localparam NB_DATA = 8;
    localparam NB_OP   = 6;
    localparam N_RAND  = 2000;

    localparam [NB_OP-1:0] OP_ADD = 6'b100000;
    localparam [NB_OP-1:0] OP_SUB = 6'b100010;
    localparam [NB_OP-1:0] OP_AND = 6'b100100;
    localparam [NB_OP-1:0] OP_OR  = 6'b100101;
    localparam [NB_OP-1:0] OP_XOR = 6'b100110;
    localparam [NB_OP-1:0] OP_SRA = 6'b000011;
    localparam [NB_OP-1:0] OP_SRL = 6'b000010;
    localparam [NB_OP-1:0] OP_NOR = 6'b100111;

    reg  [NB_DATA-1:0] tb_data_a;
    reg  [NB_DATA-1:0] tb_data_b;
    reg  [NB_OP-1:0]   tb_op;
    wire [NB_DATA-1:0] tb_result;
    wire               tb_carry;

    wire [NB_DATA:0]   exp_bus;
    wire [NB_DATA-1:0] exp_result;
    wire               exp_carry;

    integer i;
    integer errors;
    integer checks;
    integer op_sel;

    ALU #(
        .N_BITS (NB_DATA),
        .N_OP   (NB_OP)
    ) u_alu (
        .in_a     (tb_data_a),
        .in_b     (tb_data_b),
        .in_op    (tb_op),
        .o_result (tb_result),
        .o_carry  (tb_carry)
    );

    function [NB_DATA:0] alu_model;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        input [NB_OP-1:0]   op;
        reg [NB_DATA-1:0] r;
        reg               c;
        begin
            r = {NB_DATA{1'b0}};
            c = 1'b0;
            case (op)
                OP_ADD: {c, r} = {1'b0, a} + {1'b0, b};
                OP_SUB: r = a - b;
                OP_AND: r = a & b;
                OP_OR:  r = a | b;
                OP_XOR: r = a ^ b;
                OP_SRA: r = $signed(a) >>> b;
                OP_SRL: r = a >> b;
                OP_NOR: r = ~(a | b);
                default: begin
                    r = {NB_DATA{1'b0}};
                    c = 1'b0;
                end
            endcase
            alu_model = {c, r};
        end
    endfunction

    assign exp_bus    = alu_model(tb_data_a, tb_data_b, tb_op);
    assign exp_result = exp_bus[NB_DATA-1:0];
    assign exp_carry  = exp_bus[NB_DATA];

    function [NB_OP-1:0] pick_op;
        input integer sel;
        begin
            case (sel)
                0: pick_op = OP_ADD;
                1: pick_op = OP_SUB;
                2: pick_op = OP_AND;
                3: pick_op = OP_OR;
                4: pick_op = OP_XOR;
                5: pick_op = OP_SRA;
                6: pick_op = OP_SRL;
                7: pick_op = OP_NOR;
                default: pick_op = OP_ADD;
            endcase
        end
    endfunction

    task check;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        input [NB_OP-1:0]   op;
        begin
            tb_data_a = a;
            tb_data_b = b;
            tb_op     = op;
            #5;
            checks = checks + 1;
            if (tb_result !== exp_result || tb_carry !== exp_carry) begin
                errors = errors + 1;
                $display("ERROR t=%0t | A=%h B=%h OP=%b | DUT res=%h carry=%b | ESP res=%h carry=%b",
                         $time, a, b, op, tb_result, tb_carry,
                         exp_result, exp_carry);
            end
            #5;
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        tb_data_a = 0;
        tb_data_b = 0;
        tb_op = OP_ADD;
        #10;

        check(8'h00, 8'h00, OP_ADD);
        check(8'hFF, 8'h01, OP_ADD);
        check(8'h80, 8'h80, OP_ADD);
        check(8'h7F, 8'h01, OP_ADD);
        check(8'h00, 8'h01, OP_SUB);
        check(8'h10, 8'h10, OP_SUB);
        check(8'hF0, 8'h0F, OP_SUB);
        check(8'hAA, 8'h55, OP_AND);
        check(8'hAA, 8'h55, OP_OR);
        check(8'hAA, 8'hFF, OP_XOR);
        check(8'h00, 8'h00, OP_NOR);
        check(8'h80, 8'd1, OP_SRA);
        check(8'hFF, 8'd4, OP_SRA);
        check(8'h40, 8'd2, OP_SRA);
        check(8'h80, 8'd1, OP_SRL);
        check(8'hFF, 8'd4, OP_SRL);
        check(8'hFF, 8'd8, OP_SRL);
        check(8'hAB, 8'hCD, 6'b111111);

        for (i = 0; i < N_RAND; i = i + 1) begin
            op_sel = $random & 7;
            check($random, $random, pick_op(op_sel));
        end

        for (i = 0; i < 200; i = i + 1)
            check($random, $random, $random);

        $display("=====================================================");
        $display(" Chequeos ejecutados: %0d", checks);
        if (errors == 0)
            $display(" TEST PASSED: 0 errores");
        else
            $display(" TEST FAILED: %0d errores", errors);
        $display("=====================================================");
        $finish;
    end

endmodule
