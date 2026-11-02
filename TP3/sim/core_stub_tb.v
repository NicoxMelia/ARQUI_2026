`timescale 1ns / 1ps

// Testbench autochequeante de core_stub: PC con ce, IF/ID, regfile falso,
// halt por ebreak, illegal por 0x00000000, reset_busy y que ce=0 congela todo.

module core_stub_tb;

    reg         clk = 0;
    reg         rst = 1;
    reg         ce = 0;
    reg         core_reset = 0;
    reg         imem_we = 0;
    reg  [9:0]  imem_addr = 0;
    reg  [31:0] imem_wdata = 0;
    reg  [4:0]  dbg_reg_addr = 0;
    reg  [9:0]  dbg_dmem_addr = 0;

    wire [31:0]  dbg_reg_data, dbg_dmem_data, dbg_pc;
    wire         halted, illegal, pipeline_empty, reset_busy;
    wire [12:0]  dmem_hwm;
    wire [3:0]   dbg_valid;
    wire [63:0]  dbg_if_id;
    wire [159:0] dbg_id_ex;
    wire [79:0]  dbg_ex_mem, dbg_mem_wb;

    core_stub #(.RESET_CYCLES(4)) dut (
        .clk(clk), .rst(rst), .ce(ce), .core_reset(core_reset),
        .imem_we(imem_we), .imem_addr(imem_addr), .imem_wdata(imem_wdata),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_data(dbg_dmem_data),
        .halted(halted), .illegal(illegal), .pipeline_empty(pipeline_empty),
        .reset_busy(reset_busy), .dmem_hwm(dmem_hwm), .dbg_valid(dbg_valid),
        .dbg_pc(dbg_pc), .dbg_if_id(dbg_if_id), .dbg_id_ex(dbg_id_ex),
        .dbg_ex_mem(dbg_ex_mem), .dbg_mem_wb(dbg_mem_wb)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: obtenido %h, esperado %h", what, got, exp);
            end
        end
    endtask

    task write_word(input [9:0] a, input [31:0] w);
        begin
            @(negedge clk);
            imem_we = 1; imem_addr = a; imem_wdata = w;
            @(negedge clk);
            imem_we = 0;
        end
    endtask

    // Un pulso de ce de exactamente un ciclo
    task step;
        begin
            @(negedge clk); ce = 1;
            @(negedge clk); ce = 0;
        end
    endtask

    task do_core_reset;
        begin
            @(negedge clk); core_reset = 1;
            #1 check("reset_busy en el pulso", {31'd0, reset_busy}, 1);
            @(negedge clk); core_reset = 0;
            while (reset_busy) @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        while (reset_busy) @(negedge clk);

        // Programa: addi x1,x0,5 ; addi x2,x1,3 ; ebreak ; (resto en cero)
        write_word(0, 32'h00500093);
        write_word(1, 32'h00308113);
        write_word(2, 32'h00100073);
        do_core_reset;

        // Estado inicial
        check("pc inicial",        dbg_pc, 0);
        check("valid inicial",     {28'd0, dbg_valid}, 0);
        check("halted inicial",    {31'd0, halted}, 0);
        check("empty inicial",     {31'd0, pipeline_empty}, 1);

        // ce=0 congela
        repeat (3) @(negedge clk);
        check("pc con ce=0",       dbg_pc, 0);

        // Paso 1: IF/ID = {addi x1, pc 0}
        step;
        check("pc paso 1",         dbg_pc, 4);
        check("if_id paso 1",      dbg_if_id[31:0], 0);
        check("instr paso 1",      dbg_if_id[63:32], 32'h00500093);
        check("valid paso 1",      {28'd0, dbg_valid}, 1);
        check("empty paso 1",      {31'd0, pipeline_empty}, 0);

        // Paso 2
        step;
        check("pc paso 2",         dbg_pc, 8);
        check("pc en IF/ID paso 2", dbg_if_id[31:0], 4);
        check("instr paso 2",      dbg_if_id[63:32], 32'h00308113);

        // Paso 3: entra el ebreak
        step;
        check("pc paso 3",         dbg_pc, 12);
        check("instr paso 3",      dbg_if_id[63:32], 32'h00100073);
        check("halted paso 3",     {31'd0, halted}, 0);

        // Paso 4: se detecta el ebreak
        step;
        check("halted paso 4",     {31'd0, halted}, 1);
        check("illegal paso 4",    {31'd0, illegal}, 0);
        check("empty paso 4",      {31'd0, pipeline_empty}, 1);
        check("pc paso 4",         dbg_pc, 12);

        // STEP estando detenido no cambia nada
        step;
        check("pc paso 5",         dbg_pc, 12);
        check("halted paso 5",     {31'd0, halted}, 1);
        check("if_id paso 5",      dbg_if_id[31:0], 0);

        // Registros falsos x_i = i y dmem falsa
        for (i = 0; i < 32; i = i + 1) begin
            dbg_reg_addr = i[4:0];
            #1 check("x_i", dbg_reg_data, i);
        end
        dbg_dmem_addr = 10'd7;
        #1 check("dmem[7]", dbg_dmem_data, 32'hD0000007);
        check("hwm", {19'd0, dmem_hwm}, 0);

        // Latches no implementados en cero
        check("id_ex",  {31'd0, |dbg_id_ex},  0);
        check("ex_mem", {31'd0, |dbg_ex_mem}, 0);
        check("mem_wb", {31'd0, |dbg_mem_wb}, 0);

        // ce durante reset_busy se ignora; core_reset limpia halted
        do_core_reset;
        check("halted tras reset", {31'd0, halted}, 0);
        check("pc tras reset",     dbg_pc, 0);
        @(negedge clk); core_reset = 1;
        @(negedge clk); core_reset = 0; ce = 1;
        @(negedge clk); ce = 0;
        check("ce ignorado en reset_busy", dbg_pc, 0);
        while (reset_busy) @(negedge clk);

        // Palabra 0x00000000: illegal + halted (D3). Programa sin HALT.
        write_word(0, 32'h00500093);
        write_word(1, 32'h00000000);
        do_core_reset;
        step; step; step;
        check("illegal: instr en IF/ID", dbg_if_id[63:32], 0);
        step;
        check("illegal", {31'd0, illegal}, 1);
        check("illegal => halted", {31'd0, halted}, 1);

        if (errors == 0) $display("TEST PASSED: 0 errores");
        else             $display("TEST FAILED: %0d errores", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
