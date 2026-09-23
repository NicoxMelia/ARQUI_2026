`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// top_uart_alu_tb - Testbench autochequeante de sistema
//
// Habla con el top por la linea serie como lo haria la PC: manda A, B y OP
// bit a bit y despues decodifica la respuesta muestreando o_tx en el medio
// de cada bit. Compara contra un modelo de la ALU escrito en el testbench.
//
// Para que la simulacion no tarde una eternidad se baja el divisor del baud
// generator a 4 (en la placa es 326). El comportamiento de las FSM es el
// mismo: lo unico que cambia es cada cuantos ciclos llega el tick.
//////////////////////////////////////////////////////////////////////////////

module top_uart_alu_tb;

    localparam CLK_PERIOD = 10;                 // 100 MHz
    localparam DVSR_SIM   = 4;                  // divisor chico para simular
    localparam BIT_TIME   = 16 * DVSR_SIM * CLK_PERIOD;   // 640 ns por bit

    localparam [5:0] OP_ADD = 6'b100000;
    localparam [5:0] OP_SUB = 6'b100010;
    localparam [5:0] OP_AND = 6'b100100;
    localparam [5:0] OP_OR  = 6'b100101;
    localparam [5:0] OP_XOR = 6'b100110;
    localparam [5:0] OP_NOR = 6'b100111;
    localparam [5:0] OP_SRL = 6'b000010;
    localparam [5:0] OP_SRA = 6'b000011;

    reg         clk;
    reg         reset;
    reg         rx;
    wire        tx;
    wire [15:0] led;

    reg  [7:0]  rx_byte;
    integer     errors;
    integer     checks;
    integer     i;
    integer     op_sel;

    top_uart_alu #(
        .NB_DATA  (8),
        .NB_OP    (6),
        .DVSR     (DVSR_SIM),
        .DVSR_BIT (4)
    ) dut (
        .clk     (clk),
        .i_reset (reset),
        .i_rx    (rx),
        .o_tx    (tx),
        .o_led   (led)
    );

    // --- Clock ---
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // --- Modelo de la ALU (mismo criterio que el tb del TP1) ---
    function [8:0] alu_model;
        input [7:0] a;
        input [7:0] b;
        input [5:0] op;
        reg   [7:0] r;
        reg         c;
        begin
            r = 8'b0;
            c = 1'b0;
            case (op)
                OP_ADD: {c, r} = {1'b0, a} + {1'b0, b};
                OP_SUB: r = a - b;
                OP_AND: r = a & b;
                OP_OR:  r = a | b;
                OP_XOR: r = a ^ b;
                OP_NOR: r = ~(a | b);
                OP_SRL: r = a >> b;
                OP_SRA: r = $signed(a) >>> b;
                default: begin
                    r = 8'b0;
                    c = 1'b0;
                end
            endcase
            alu_model = {c, r};
        end
    endfunction

    function [5:0] pick_op;
        input integer sel;
        begin
            case (sel)
                0: pick_op = OP_ADD;
                1: pick_op = OP_SUB;
                2: pick_op = OP_AND;
                3: pick_op = OP_OR;
                4: pick_op = OP_XOR;
                5: pick_op = OP_NOR;
                6: pick_op = OP_SRL;
                default: pick_op = OP_SRA;
            endcase
        end
    endfunction

    // --- Manda un byte por la linea serie (start + 8 datos LSB first + stop)
    task send_byte;
        input [7:0] data;
        integer k;
        begin
            rx = 1'b0;                  // start
            #(BIT_TIME);
            for (k = 0; k < 8; k = k + 1) begin
                rx = data[k];
                #(BIT_TIME);
            end
            rx = 1'b1;                  // stop
            #(BIT_TIME);
        end
    endtask

    // --- Espera un byte en tx y lo decodifica ---
    task recv_byte;
        output [7:0] data;
        integer k;
        begin
            @(negedge tx);              // flanco del bit de start
            #(BIT_TIME + BIT_TIME/2);   // se para en el medio del bit 0
            for (k = 0; k < 8; k = k + 1) begin
                data[k] = tx;
                #(BIT_TIME);
            end
            // queda dentro del bit de stop
        end
    endtask

    // --- Una operacion completa: manda A, B, OP y chequea la respuesta ---
    task check_op;
        input [7:0] a;
        input [7:0] b;
        input [5:0] op;
        reg   [8:0] esperado;
        begin
            esperado = alu_model(a, b, op);

            fork
                begin
                    send_byte(a);
                    send_byte(b);
                    send_byte({2'b00, op});
                end
                recv_byte(rx_byte);
            join

            checks = checks + 1;
            if (rx_byte !== esperado[7:0]) begin
                errors = errors + 1;
                $display("ERROR t=%0t | A=%h B=%h OP=%b | recibido=%h esperado=%h",
                         $time, a, b, op, rx_byte, esperado[7:0]);
            end
            else begin
                $display("  OK   | A=%h B=%h OP=%b -> %h", a, b, op, rx_byte);
            end
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        rx     = 1'b1;              // linea en reposo
        reset  = 1'b1;
        repeat (10) @(posedge clk);
        reset  = 1'b0;
        repeat (10) @(posedge clk);

        $display("=====================================================");
        $display(" TP2 - UART + ALU : testbench de sistema");
        $display("=====================================================");

        // Casos dirigidos
        check_op(8'h05, 8'h03, OP_ADD);     // suma simple
        check_op(8'hFF, 8'h01, OP_ADD);     // suma con carry
        check_op(8'h10, 8'h03, OP_SUB);
        check_op(8'h00, 8'h01, OP_SUB);     // resta con borrow
        check_op(8'hAA, 8'h55, OP_AND);
        check_op(8'hAA, 8'h55, OP_OR);
        check_op(8'hAA, 8'hFF, OP_XOR);
        check_op(8'h00, 8'h00, OP_NOR);
        check_op(8'h80, 8'd1,  OP_SRL);
        check_op(8'h80, 8'd1,  OP_SRA);     // conserva el signo
        check_op(8'hFF, 8'd4,  OP_SRA);
        check_op(8'hAB, 8'hCD, 6'b111111);  // operacion invalida -> 00

        // Casos aleatorios
        for (i = 0; i < 20; i = i + 1) begin
            op_sel = $random & 7;
            check_op($random, $random, pick_op(op_sel));
        end

        $display("=====================================================");
        $display(" Operaciones chequeadas: %0d", checks);
        if (errors == 0)
            $display(" TEST PASSED: 0 errores");
        else
            $display(" TEST FAILED: %0d errores", errors);
        $display("=====================================================");
        $finish;
    end

    // Red de seguridad por si algo se cuelga
    initial begin
        #5_000_000;
        $display(" TIMEOUT: la simulacion no termino a tiempo");
        $finish;
    end

endmodule
