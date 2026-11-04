`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// debug_unit_tb - Testbench autochequeante de la Debug Unit (DBG-2, DBG-4)
//
// Sistema completo por la linea serie:
//   UART "PC" (la maneja el testbench) <-> UART + debug_unit <-> core_stub
// Para que la simulacion sea corta se usa BAUD = 3,125 Mbaud (DVSR = 2, un
// byte cada 320 ciclos) y un timeout de 2000 ciclos (unos 6 tiempos de byte).
//
// Casos:
//   1. PING -> ACK.
//   2. Comando desconocido -> NACK 0x01.
//   3. STEP: ce en 1 exactamente un ciclo por STEP; el volcado muestra el PC
//      avanzando de a 4 y el status del stub.
//   4. DUMP: no mueve ce.
//   5. RUN hasta ebreak: termina solo con halted && pipeline_empty.
//   6. STEP con el core detenido: no cambia el estado.
//   7. STOP fuera de RUN -> ACK. RESET -> ACK y PC = 0.
//   8. RUN sin HALT: los bytes que no son STOP se descartan y STOP detiene.
//   9. Tramas truncadas (LOAD y READ_DMEM) -> NACK 0x02 por timeout.
//  10. LOAD con len fuera de rango -> un unico NACK 0x03 (se descartan datos).
//  11. Error de trama en IDLE y a mitad de trama -> NACK 0x05.
//  12. Nunca sube ce con reset_busy ni con core_reset.
//  13. Volcado (DBG-4): todos los DUMP se comparan byte a byte (185 B) contra
//      un modelo. Entre el stub y la DU el banco de registros pasa por un
//      registro (latencia real de 1 ciclo, el peor caso del contrato) y con
//      pat_en los latches y registros toman patrones distintos byte a byte
//      para verificar el orden. Cambiar los latches mientras se transmite no
//      altera el volcado (snapshot).
// Despues de cada error se verifica con PING que la FSM no quedo colgada.
//
// Con Icarus:  make sim TB=debug_unit_tb
//////////////////////////////////////////////////////////////////////////////

module debug_unit_tb;

    localparam CLK_FREQ = 100_000_000;
    localparam BAUD     = 3_125_000;
    localparam TMO      = 2000;                 // ciclos de timeout de la DU
    localparam real BIT_NS = 1.0e9 / BAUD;      // 320 ns

    localparam [31:0] NOP    = 32'h00000013;
    localparam [31:0] EBREAK = 32'h00100073;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

    // ------------------------------------------------------------------
    // UART del lado de la PC
    // ------------------------------------------------------------------
    reg        pc_wr = 1'b0;
    reg  [7:0] pc_wdata = 8'h00;
    wire [7:0] pc_rdata;
    wire       pc_rx_empty, pc_tx_full, pc_tx;
    wire       pc_frame_err, pc_rx_overrun;
    wire       du_tx;

    uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_pc_uart (
        .clk(clk), .reset(rst),
        .rd_uart(~pc_rx_empty), .wr_uart(pc_wr), .w_data(pc_wdata),
        .r_data(pc_rdata), .rx_empty(pc_rx_empty), .tx_full(pc_tx_full),
        .clr_err(1'b0), .frame_err(pc_frame_err), .rx_overrun(pc_rx_overrun),
        .rx(du_tx), .tx(pc_tx)
    );

    // Bytes recibidos por la PC
    reg  [7:0] rx_buf [0:16383];
    integer    rx_cnt = 0;
    integer    rx_pos = 0;          // proximo byte a verificar

    always @(posedge clk) begin
        if (~pc_rx_empty) begin
            if (rx_cnt == 16384) begin
                $display("TEST FAILED: se lleno el buffer de recepcion del testbench");
                $finish;
            end
            rx_buf[rx_cnt] <= pc_rdata;
            rx_cnt         <= rx_cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // UART + Debug Unit + core_stub
    // ------------------------------------------------------------------
    reg        force_en   = 1'b0;   // 1: el testbench maneja la linea rx de la DU
    reg        force_line = 1'b1;
    wire       du_rx = force_en ? force_line : pc_tx;

    wire       du_rd, du_wr, du_rx_empty, du_tx_full, du_clr_err;
    wire       du_frame_err, du_rx_overrun;
    wire [7:0] du_rdata, du_wdata;

    uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_du_uart (
        .clk(clk), .reset(rst),
        .rd_uart(du_rd), .wr_uart(du_wr), .w_data(du_wdata),
        .r_data(du_rdata), .rx_empty(du_rx_empty), .tx_full(du_tx_full),
        .clr_err(du_clr_err), .frame_err(du_frame_err), .rx_overrun(du_rx_overrun),
        .rx(du_rx), .tx(du_tx)
    );

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
    wire [10:0]  fsm_state;

    // Lo que ve la Debug Unit: el stub o, con pat_en, patrones conocidos
    reg          pat_en  = 1'b0;
    reg  [63:0]  pat_if_id;
    reg  [159:0] pat_id_ex;
    reg  [79:0]  pat_ex_mem, pat_mem_wb;
    reg  [31:0]  reg_q;                         // banco con latencia de 1 ciclo

    wire [63:0]  du_if_id   = pat_en ? pat_if_id  : dbg_if_id;
    wire [159:0] du_id_ex   = pat_en ? pat_id_ex  : dbg_id_ex;
    wire [79:0]  du_ex_mem  = pat_en ? pat_ex_mem : dbg_ex_mem;
    wire [79:0]  du_mem_wb  = pat_en ? pat_mem_wb : dbg_mem_wb;
    wire [383:0] lat_live   = {du_mem_wb, du_ex_mem, du_id_ex, du_if_id};

    // Valor de x[a] visto por la DU. Sin pat_en es el banco falso del stub
    // (x_i = i); con pat_en cada byte es distinto.
    function [31:0] reg_model(input [4:0] a);
        reg [7:0] b;
        begin
            b = {3'd0, a};
            reg_model = pat_en ? {~b, b + 8'h40, b ^ 8'hC3, b} : dbg_reg_data;
        end
    endfunction

    always @(posedge clk)
        reg_q <= reg_model(dbg_reg_addr);

    debug_unit #(.CLK_FREQ(CLK_FREQ), .TIMEOUT_CYCLES(TMO)) dut (
        .clk(clk), .reset(rst),
        .rd_uart(du_rd), .rx_empty(du_rx_empty), .r_data(du_rdata),
        .wr_uart(du_wr), .tx_full(du_tx_full), .w_data(du_wdata),
        .clr_err(du_clr_err), .frame_err(du_frame_err), .rx_overrun(du_rx_overrun),
        .ce(ce), .core_reset(core_reset), .reset_busy(reset_busy),
        .imem_we(imem_we), .imem_addr(imem_addr), .imem_wdata(imem_wdata),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(reg_q),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_data(dbg_dmem_data),
        .halted(halted), .illegal(illegal), .pipeline_empty(pipeline_empty),
        .dmem_hwm(dmem_hwm), .dbg_valid(dbg_valid),
        .dbg_pc(dbg_pc), .dbg_if_id(du_if_id), .dbg_id_ex(du_id_ex),
        .dbg_ex_mem(du_ex_mem), .dbg_mem_wb(du_mem_wb),
        .fsm_state(fsm_state)
    );

    core_stub #(.RESET_CYCLES(16)) u_core (
        .clk(clk), .rst(rst), .ce(ce), .core_reset(core_reset),
        .imem_we(imem_we), .imem_addr(imem_addr), .imem_wdata(imem_wdata),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_data(dbg_dmem_data),
        .halted(halted), .illegal(illegal), .pipeline_empty(pipeline_empty),
        .reset_busy(reset_busy), .dmem_hwm(dmem_hwm), .dbg_valid(dbg_valid),
        .dbg_pc(dbg_pc), .dbg_if_id(dbg_if_id), .dbg_id_ex(dbg_id_ex),
        .dbg_ex_mem(dbg_ex_mem), .dbg_mem_wb(dbg_mem_wb)
    );

    // ------------------------------------------------------------------
    // Monitores
    // ------------------------------------------------------------------
    integer ce_cnt = 0;             // ciclos con ce = 1

    always @(posedge clk) begin
        if (ce) ce_cnt <= ce_cnt + 1;
        if (~rst && ce && reset_busy) begin
            $display("ERROR: ce en 1 con reset_busy (t=%0t)", $time);
            errors = errors + 1;
        end
        if (~rst && ((fsm_state & (fsm_state - 11'd1)) != 11'd0 || fsm_state == 11'd0)) begin
            $display("ERROR: fsm_state no es one-hot: %b (t=%0t)", fsm_state, $time);
            errors = errors + 1;
        end
    end

    // ------------------------------------------------------------------
    // Tareas
    // ------------------------------------------------------------------
    task send(input [7:0] b);
        begin
            @(negedge clk);
            while (pc_tx_full) @(negedge clk);
            pc_wr    = 1'b1;
            pc_wdata = b;
            @(negedge clk);
            pc_wr    = 1'b0;
        end
    endtask

    // Byte con temporizacion ideal directo en la linea rx de la DU.
    // stop_bit = 0 fuerza un error de trama.
    task send_raw(input [7:0] b, input stop_bit);
        integer k;
        begin
            force_en   = 1'b1;
            force_line = 1'b0;
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                force_line = b[k];
                #(BIT_NS);
            end
            force_line = stop_bit;
            #(BIT_NS);
            force_line = 1'b1;
            #(2 * BIT_NS);
            force_en   = 1'b0;
        end
    endtask

    task wait_cycles(input integer n);
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    // Espera n bytes nuevos (con limite) y los compara con exp (byte 0 = exp[7:0])
    task expect_bytes(input [8*64-1:0] name, input integer n, input [8*16-1:0] exp);
        integer k, lim;
        begin
            lim = 0;
            while (rx_cnt < rx_pos + n && lim < 200_000) begin
                @(negedge clk);
                lim = lim + 1;
            end
            if (rx_cnt < rx_pos + n) begin
                $display("ERROR %0s: llegaron %0d de %0d bytes", name, rx_cnt - rx_pos, n);
                errors = errors + 1;
                rx_pos = rx_cnt;
            end
            else begin
                for (k = 0; k < n; k = k + 1)
                    if (rx_buf[rx_pos + k] !== exp[8*k +: 8]) begin
                        $display("ERROR %0s: byte %0d = %02h, esperado %02h",
                                 name, k, rx_buf[rx_pos + k], exp[8*k +: 8]);
                        errors = errors + 1;
                    end
                rx_pos = rx_pos + n;
            end
        end
    endtask

    // Verifica que no llegue nada durante n ciclos
    task expect_silence(input [8*64-1:0] name, input integer n);
        begin
            wait_cycles(n);
            if (rx_cnt != rx_pos) begin
                $display("ERROR %0s: llegaron %0d bytes inesperados (primero %02h)",
                         name, rx_cnt - rx_pos, rx_buf[rx_pos]);
                errors = errors + 1;
                rx_pos = rx_cnt;
            end
        end
    endtask

    task check(input [8*64-1:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("ERROR %0s: obtenido %0h, esperado %0h", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task expect_ack(input [8*64-1:0] name, input [7:0] cmd);
        expect_bytes(name, 5, {cmd, 8'h00, 8'h01, 8'h10, 8'hAA});
    endtask

    task expect_nack(input [8*64-1:0] name, input [7:0] cmd, input [7:0] code);
        expect_bytes(name, 6, {code, cmd, 8'h00, 8'h02, 8'h11, 8'hAA});
    endtask

    // Espera n bytes nuevos; ok = 0 si no llegaron
    task wait_bytes(input [8*64-1:0] name, input integer n, output ok);
        integer lim;
        begin
            lim = 0;
            while (rx_cnt < rx_pos + n && lim < 400_000) begin
                @(negedge clk);
                lim = lim + 1;
            end
            ok = (rx_cnt >= rx_pos + n);
            if (!ok) begin
                $display("ERROR %0s: llegaron %0d de %0d bytes", name, rx_cnt - rx_pos, n);
                errors = errors + 1;
                rx_pos = rx_cnt;
            end
        end
    endtask

    // Compara la trama DUMP (185 B) ya recibida con el modelo:
    // [AA][20][B5 00][status][PC][x0..x31][IF/ID][ID/EX][EX/MEM][MEM/WB]
    reg [7:0] exp_frame [0:184];
    task compare_dump(input [8*64-1:0] name, input [7:0] status, input [31:0] pc,
                      input [383:0] lat);
        integer k, bad;
        reg [31:0] r;
        begin
            exp_frame[0] = 8'hAA;
            exp_frame[1] = 8'h20;
            exp_frame[2] = 8'd181;
            exp_frame[3] = 8'h00;
            exp_frame[4] = status;
            for (k = 0; k < 4; k = k + 1)
                exp_frame[5 + k] = pc[8*k +: 8];
            for (k = 0; k < 128; k = k + 1) begin
                r = pat_en ? reg_model(k / 4) : (k / 4);
                exp_frame[9 + k] = r[8*(k % 4) +: 8];
            end
            for (k = 0; k < 48; k = k + 1)
                exp_frame[137 + k] = lat[8*k +: 8];
            bad = 0;
            for (k = 0; k < 185; k = k + 1)
                if (rx_buf[rx_pos + k] !== exp_frame[k]) begin
                    if (bad < 4)
                        $display("ERROR %0s: byte %0d = %02h, esperado %02h",
                                 name, k, rx_buf[rx_pos + k], exp_frame[k]);
                    bad = bad + 1;
                end
            if (bad > 0) begin
                $display("ERROR %0s: %0d bytes distintos en el volcado", name, bad);
                errors = errors + 1;
            end
            rx_pos = rx_pos + 185;
        end
    endtask

    task expect_dump(input [8*64-1:0] name, input [7:0] status, input [31:0] pc,
                     input [383:0] lat);
        reg ok;
        begin
            wait_bytes(name, 185, ok);
            if (ok) compare_dump(name, status, pc, lat);
        end
    endtask

    // Volcado de un core ya detenido: PC y latches tienen que ser los actuales
    task expect_dump_live(input [8*64-1:0] name, input [7:0] status);
        reg ok;
        begin
            wait_bytes(name, 185, ok);
            if (ok) compare_dump(name, status, dbg_pc, lat_live);
        end
    endtask

    // Latches del stub con IF/ID valido: solo IF/ID = {instr, pc}
    function [383:0] lat_ifid(input [31:0] instr, input [31:0] pc);
        lat_ifid = {320'd0, instr, pc};
    endfunction

    task ping(input [8*64-1:0] name);
        begin
            send(8'h01);
            expect_ack(name, 8'h01);
        end
    endtask

    // ------------------------------------------------------------------
    // Estimulos
    // ------------------------------------------------------------------
    integer ce0;

    initial begin
        // Programa en la imem del stub: 4 NOP y ebreak (el loader llega en DBG-3)
        for (i = 0; i < 4; i = i + 1) u_core.imem[i] = NOP;
        u_core.imem[4] = EBREAK;

        wait_cycles(5);
        rst = 1'b0;

        // 1. PING (todavia con reset_busy del reset de placa: no importa)
        ping("PING");

        // 2. Comando desconocido
        send(8'h7F);
        expect_nack("cmd desconocido", 8'h7F, 8'h01);
        send(8'h00);
        expect_nack("cmd 0x00", 8'h00, 8'h01);
        ping("PING tras desconocido");

        // 3. STEP x3: ce un solo ciclo por STEP
        for (i = 1; i <= 3; i = i + 1) begin
            ce0 = ce_cnt;
            send(8'h04);
            expect_dump("STEP", 8'h08, 4 * i, lat_ifid(NOP, 4 * (i - 1)));
            check("ciclos de ce en STEP", ce_cnt - ce0, 1);
        end

        // 4. DUMP no mueve el core
        ce0 = ce_cnt;
        send(8'h07);
        expect_dump("DUMP", 8'h08, 12, lat_ifid(NOP, 8));
        check("ciclos de ce en DUMP", ce_cnt - ce0, 0);

        // 5. RUN hasta ebreak: busca NOP (pc 12) y ebreak (pc 16), y ebreak lo detiene
        ce0 = ce_cnt;
        send(8'h05);
        expect_dump("RUN hasta HALT", 8'h05, 20, 384'd0);   // halted + pipeline_empty
        check("ciclos de ce en RUN", ce_cnt - ce0, 3);

        // 6. STEP con el core detenido
        send(8'h04);
        expect_dump("STEP detenido", 8'h05, 20, 384'd0);
        send(8'h05);
        expect_dump("RUN detenido", 8'h05, 20, 384'd0);

        // 7. STOP fuera de RUN y RESET
        send(8'h06);
        expect_ack("STOP fuera de RUN", 8'h06);
        send(8'h03);
        expect_ack("RESET", 8'h03);
        check("reset_busy tras ACK de RESET", reset_busy, 0);
        send(8'h07);
        expect_dump("DUMP tras RESET", 8'h04, 0, 384'd0);   // pipeline_empty

        // 8. RUN sin HALT (todo NOP): solo STOP lo detiene
        for (i = 0; i < 1024; i = i + 1) u_core.imem[i] = NOP;
        send(8'h05);
        wait_cycles(1000);
        send(8'h01);                                // se descarta
        send(8'h7F);                                // se descarta
        expect_silence("bytes durante RUN", 2000);
        check("ce sigue en 1 durante RUN", ce, 1);
        send(8'h06);
        // El PC depende del instante del STOP: tiene que coincidir con el del core
        expect_dump_live("STOP en RUN", 8'h08);
        check("IF/ID coherente con el PC tras STOP", dbg_if_id[31:0], dbg_pc - 4);
        ce0 = ce_cnt;
        wait_cycles(500);
        check("ce queda en 0 tras STOP", ce_cnt - ce0, 0);
        check("PC alineado tras STOP", dbg_pc[1:0], 0);
        if (dbg_pc < 32'd40) begin
            $display("ERROR: el core no corrio durante RUN (PC=%0h)", dbg_pc);
            errors = errors + 1;
        end
        ping("PING tras RUN/STOP");

        // 9. Tramas truncadas
        send(8'h02);
        send(8'h05);                                // falta el byte alto de len
        expect_silence("LOAD truncado antes del timeout", TMO - 400);
        expect_nack("LOAD truncado", 8'h02, 8'h02);
        send(8'h08);
        send(8'h00); send(8'h00); send(8'h04);      // falta un byte de count
        expect_nack("READ_DMEM truncado", 8'h08, 8'h02);
        send(8'h02);                                // sin argumentos
        expect_nack("LOAD sin len", 8'h02, 8'h02);
        ping("PING tras timeouts");

        // 10. LOAD con len fuera de rango: un unico NACK, los datos se descartan
        send(8'h02); send(8'h00); send(8'h00);      // len = 0
        expect_nack("LOAD len=0", 8'h02, 8'h03);
        send(8'h02); send(8'h01); send(8'h04);      // len = 1025
        for (i = 0; i < 8; i = i + 1) send(8'h01);  // datos con pinta de PING
        expect_nack("LOAD len=1025", 8'h02, 8'h03);
        expect_silence("datos de LOAD descartados", 3 * TMO);
        ping("PING tras BAD_ARG");

        // 11. Errores de trama
        send_raw(8'h01, 1'b0);                      // PING con stop en 0
        expect_nack("error de trama en IDLE", 8'h00, 8'h05);
        send(8'h02);
        wait_cycles(400);
        send_raw(8'h10, 1'b0);                      // len con stop en 0
        send_raw(8'h00, 1'b1);
        expect_nack("error de trama en LOAD", 8'h02, 8'h05);
        expect_silence("un solo NACK por error", 3 * TMO);
        ping("PING tras error de trama");

        // 13. Volcado con patrones conocidos en latches y registros
        pat_if_id  = 64'h0706050403020100;
        pat_id_ex  = 160'h1B1A191817161514131211100F0E0D0C0B0A0908;
        pat_ex_mem = 80'h2524232221201F1E1D1C;
        pat_mem_wb = 80'h2F2E2D2C2B2A29282726;
        pat_en     = 1'b1;
        send(8'h07);
        expect_dump_live("DUMP con patrones", 8'h08);

        // Snapshot: cambiar los latches mientras se transmite no altera el volcado
        send(8'h07);
        wait (rx_cnt >= rx_pos + 10);
        pat_if_id  = ~pat_if_id;
        pat_id_ex  = ~pat_id_ex;
        pat_ex_mem = ~pat_ex_mem;
        pat_mem_wb = ~pat_mem_wb;
        expect_dump("DUMP con latches cambiando", 8'h08, dbg_pc,
                    {~pat_mem_wb, ~pat_ex_mem, ~pat_id_ex, ~pat_if_id});
        pat_en = 1'b0;

        // 12. Termina en IDLE
        check("fsm_state en IDLE", fsm_state, 11'b1);

        if (errors == 0)
            $display("TEST PASSED: 0 errores");
        else
            $display("TEST FAILED: %0d errores", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout del testbench");
        $finish;
    end

endmodule
