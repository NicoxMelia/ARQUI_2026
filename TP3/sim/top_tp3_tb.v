`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// top_tp3_tb - Prueba de aceptacion del hito M1 sobre top_tp3 (INT-1)
//
// La PC es una uart.v manejada por el testbench, conectada a i_rx/o_tx del
// top. Se usa BAUD = 3,125 Mbaud (un byte cada 320 ns) y un timeout de la DU
// de 2000 ciclos para que la simulacion sea corta.
//
// Casos (los de la issue #19):
//   1. PING -> ACK.
//   2. LOAD de 8 palabras -> ACK con words y xor.
//   3. 3 STEP: el DUMP muestra PC y el IF/ID del stub avanzando con las
//      palabras cargadas; x0..x31 valen x_i = i.
//   4. RESET y LOAD de 2 palabras: queda solo el programa nuevo (el core se
//      detiene en la tercera palabra, que es cero: illegal).
//   5. RUN hasta ebreak (halted), y RUN sin HALT + STOP (1024 NOP).
//   6. LEDs: fsm_state one-hot en LD0..LD12, halted/illegal/pipeline_empty.
//
// Con Icarus:  make sim TB=top_tp3_tb
//////////////////////////////////////////////////////////////////////////////

module top_tp3_tb;

    localparam CLK_FREQ = 100_000_000;
    localparam BAUD     = 3_125_000;
    localparam TMO      = 2000;

    localparam [31:0] NOP    = 32'h00000013;
    localparam [31:0] EBREAK = 32'h00100073;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg i_reset = 1'b1;
    wire i_rx, o_tx;
    wire [15:0] o_led;

    top_tp3 #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .TIMEOUT_CYCLES(TMO)) dut (
        .clk(clk), .i_reset(i_reset), .i_rx(i_rx), .o_tx(o_tx), .o_led(o_led)
    );

    integer errors = 0;
    integer i, k;

    // ------------------------------------------------------------------
    // UART del lado de la PC
    // ------------------------------------------------------------------
    reg        pc_wr = 1'b0;
    reg  [7:0] pc_wdata = 8'h00;
    wire [7:0] pc_rdata;
    wire       pc_rx_empty, pc_tx_full;
    wire       pc_frame_err, pc_rx_overrun;

    uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_pc_uart (
        .clk(clk), .reset(i_reset),
        .rd_uart(~pc_rx_empty), .wr_uart(pc_wr), .w_data(pc_wdata),
        .r_data(pc_rdata), .rx_empty(pc_rx_empty), .tx_full(pc_tx_full),
        .clr_err(1'b0), .frame_err(pc_frame_err), .rx_overrun(pc_rx_overrun),
        .rx(o_tx), .tx(i_rx)
    );

    reg  [7:0] rx_buf [0:16383];
    integer    rx_cnt = 0;
    integer    rx_pos = 0;          // proximo byte a verificar

    always @(posedge clk) begin
        if (~pc_rx_empty) begin
            rx_buf[rx_cnt] <= pc_rdata;
            rx_cnt         <= rx_cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // Utilidades
    // ------------------------------------------------------------------
    task send(input [7:0] b);
        begin
            @(negedge clk);
            while (pc_tx_full) @(negedge clk);
            pc_wdata = b; pc_wr = 1;
            @(negedge clk);
            pc_wr = 0;
        end
    endtask

    task send_word(input [31:0] w);
        begin
            send(w[7:0]); send(w[15:8]); send(w[23:16]); send(w[31:24]);
        end
    endtask

    // Espera n bytes nuevos
    task wait_bytes(input integer n);
        integer t;
        begin
            t = 0;
            while (rx_cnt - rx_pos < n && t < 400000) begin
                @(posedge clk); t = t + 1;
            end
            if (rx_cnt - rx_pos < n) begin
                errors = errors + 1;
                $display("ERROR: timeout esperando %0d bytes (llegaron %0d)", n, rx_cnt - rx_pos);
            end
        end
    endtask

    task expect_byte(input integer off, input [7:0] exp, input [255:0] what);
        begin
            if (rx_buf[rx_pos + off] !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: byte %0d = %h, esperado %h", what, off, rx_buf[rx_pos + off], exp);
            end
        end
    endtask

    task expect_word(input integer off, input [31:0] exp, input [255:0] what);
        begin
            expect_byte(off,     exp[7:0],   what);
            expect_byte(off + 1, exp[15:8],  what);
            expect_byte(off + 2, exp[23:16], what);
            expect_byte(off + 3, exp[31:24], what);
        end
    endtask

    // Respuesta ACK de un byte de payload: AA 10 01 00 cmd
    task expect_ack(input [7:0] cmd);
        begin
            wait_bytes(5);
            expect_byte(0, 8'hAA, "ack sof");
            expect_byte(1, 8'h10, "ack tipo");
            expect_byte(2, 8'h01, "ack len");
            expect_byte(3, 8'h00, "ack len");
            expect_byte(4, cmd,   "ack cmd");
            rx_pos = rx_pos + 5;
        end
    endtask

    // DUMP: AA 20 B5 00 + 181 B. Verifica encabezado, status, PC, x_i = i y el IF/ID.
    task expect_dump(input [7:0] status, input [31:0] pc, input [31:0] ifid_pc,
                     input [31:0] ifid_instr, input [255:0] what);
        begin
            wait_bytes(185);
            expect_byte(0, 8'hAA, what);
            expect_byte(1, 8'h20, what);
            expect_byte(2, 8'hB5, what);
            expect_byte(3, 8'h00, what);
            expect_byte(4, status, what);
            expect_word(5, pc, what);
            for (k = 0; k < 32; k = k + 1) expect_word(9 + 4*k, k, what);
            expect_word(137, ifid_pc, what);
            expect_word(141, ifid_instr, what);
            rx_pos = rx_pos + 185;
        end
    endtask

    // status = {0, v_mw, v_xm, v_dx, v_fd, empty, illegal, halted}; el stub solo usa IF/ID
    function [7:0] status_of(input halted, input illegal, input empty, input v_fd);
        status_of = {3'b000, v_fd, empty, illegal, halted};
    endfunction

    reg [31:0] prog [0:7];
    reg [7:0]  x;

    // ------------------------------------------------------------------
    // LEDs: fsm_state one-hot
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!i_reset && (o_led[12:0] == 13'd0 || (o_led[12:0] & (o_led[12:0] - 13'd1)) != 13'd0)) begin
            errors = errors + 1;
            $display("ERROR: fsm_state en los LEDs no es one-hot: %b", o_led[12:0]);
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        i_reset = 0;
        repeat (50) @(negedge clk);

        // --- 1. PING ---
        send(8'h01);
        expect_ack(8'h01);

        // --- 2. LOAD de 8 palabras: addi x(i),x0,i ---
        x = 8'h00;
        for (i = 0; i < 8; i = i + 1) begin
            prog[i] = ((i + 1) << 20) | ((i + 1) << 7) | 32'h13;
            x = x ^ prog[i][7:0] ^ prog[i][15:8] ^ prog[i][23:16] ^ prog[i][31:24];
        end
        send(8'h02); send(8'h08); send(8'h00);
        for (i = 0; i < 8; i = i + 1) send_word(prog[i]);
        wait_bytes(8);
        expect_byte(0, 8'hAA, "load ack");
        expect_byte(1, 8'h10, "load ack");
        expect_byte(2, 8'h04, "load ack");
        expect_byte(3, 8'h00, "load ack");
        expect_byte(4, 8'h02, "load ack");
        expect_byte(5, 8'h08, "load ack");
        expect_byte(6, 8'h00, "load ack");
        expect_byte(7, x,     "load ack xor");
        rx_pos = rx_pos + 8;

        // --- 3. Tres STEP ---
        for (i = 1; i <= 3; i = i + 1) begin
            send(8'h04);
            // tras el STEP i: PC = 4i, IF/ID = {pc 4(i-1), prog[i-1]}
            expect_dump(status_of(0, 0, 0, 1), 4 * i, 4 * (i - 1), prog[i - 1], "step");
        end
        // DUMP bajo demanda no mueve el core
        send(8'h07);
        expect_dump(status_of(0, 0, 0, 1), 12, 8, prog[2], "dump");

        // --- 4. RESET y segundo LOAD, mas corto ---
        send(8'h03);
        expect_ack(8'h03);
        send(8'h07);
        expect_dump(status_of(0, 0, 1, 0), 0, 0, 0, "dump tras reset");

        send(8'h02); send(8'h02); send(8'h00);
        send_word(NOP); send_word(NOP);
        wait_bytes(8);
        expect_byte(7, 8'h00, "load2 xor");   // NOP ^ NOP = 0
        rx_pos = rx_pos + 8;

        // RUN: ejecuta 2 NOP y se detiene en la tercera palabra (cero = illegal)
        send(8'h05);
        expect_dump(status_of(1, 1, 1, 0), 12, 0, 0, "run illegal");

        // --- 5. RUN hasta ebreak ---
        send(8'h02); send(8'h03); send(8'h00);
        send_word(NOP); send_word(NOP); send_word(EBREAK);
        wait_bytes(8);
        rx_pos = rx_pos + 8;
        send(8'h05);
        expect_dump(status_of(1, 0, 1, 0), 12, 0, 0, "run ebreak");

        // STEP con el core detenido: no cambia nada
        send(8'h04);
        expect_dump(status_of(1, 0, 1, 0), 12, 0, 0, "step detenido");

        // STOP fuera de RUN -> ACK
        send(8'h06);
        expect_ack(8'h06);

        // --- 6. RUN sin HALT + STOP ---
        send(8'h02); send(8'h00); send(8'h04);        // len = 1024
        for (i = 0; i < 1024; i = i + 1) send_word(NOP);
        wait_bytes(8);
        rx_pos = rx_pos + 8;
        send(8'h05);
        repeat (200) @(negedge clk);     // el stub se detiene solo al salir de la imem (~1030 ciclos)
        if (rx_cnt != rx_pos) begin
            errors = errors + 1;
            $display("ERROR: RUN respondio antes de STOP");
        end
        send(8'h06);
        wait_bytes(185);
        expect_byte(0, 8'hAA, "stop dump");
        expect_byte(1, 8'h20, "stop dump");
        expect_byte(4, status_of(0, 0, 0, 1), "stop dump status");
        rx_pos = rx_pos + 185;

        // Despues de todo, la FSM sigue viva
        send(8'h01);
        expect_ack(8'h01);

        if (errors == 0) $display("TEST PASSED: 0 errores");
        else             $display("TEST FAILED: %0d errores", errors);
        $finish;
    end

    initial begin
        #200000000;
        $display("TEST FAILED: timeout global");
        $finish;
    end

endmodule
