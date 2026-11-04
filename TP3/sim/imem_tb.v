`timescale 1ns / 1ps

// Testbench autochequeante de imem: escritura del loader, lectura sincronica
// con rd_en, retencion con rd_en=0, rd_clr, read-first, PC fuera de rango
// y primera/ultima palabra.

module imem_tb;

    reg         clk = 0;
    reg         wr_en = 0;
    reg  [9:0]  wr_addr = 0;
    reg  [31:0] wr_data = 0;
    reg         rd_en = 0;
    reg         rd_clr = 0;
    reg  [31:0] rd_addr = 0;
    wire [31:0] rd_data;

    imem dut (
        .clk(clk),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_clr(rd_clr), .rd_addr(rd_addr), .rd_data(rd_data)
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
            wr_en = 1; wr_addr = a; wr_data = w;
            @(negedge clk);
            wr_en = 0;
        end
    endtask

    // Lee la direccion de byte a con un pulso de rd_en y deja el resultado en rd_data
    task read(input [31:0] a);
        begin
            @(negedge clk);
            rd_en = 1; rd_addr = a;
            @(negedge clk);
            rd_en = 0;
        end
    endtask

    initial begin
        // Contenido inicial en cero
        read(32'h0);
        check("inicial[0]", rd_data, 0);
        read(32'hFFC);
        check("inicial[1023]", rd_data, 0);

        // Escritura y lectura de varias palabras
        write_word(0,    32'h00500093);
        write_word(1,    32'h00308113);
        write_word(2,    32'h00100073);
        write_word(1023, 32'hDEADBEEF);

        read(32'h0);   check("w0",    rd_data, 32'h00500093);
        read(32'h4);   check("w1",    rd_data, 32'h00308113);
        read(32'h8);   check("w2",    rd_data, 32'h00100073);
        read(32'hFFC); check("w1023", rd_data, 32'hDEADBEEF);

        // Los bits [1:0] de la direccion se ignoran
        read(32'h7);   check("addr no alineada", rd_data, 32'h00308113);

        // La salida es sincronica: con rd_en=0 no cambia aunque cambie rd_addr
        @(negedge clk); rd_addr = 32'h0;
        #1 check("retiene con rd_en=0", rd_data, 32'h00308113);
        repeat (2) @(negedge clk);
        check("sigue reteniendo", rd_data, 32'h00308113);

        // rd_clr pone la salida en cero y tiene prioridad sobre rd_en
        @(negedge clk); rd_clr = 1; rd_en = 1; rd_addr = 32'h0;
        @(negedge clk); rd_clr = 0; rd_en = 0;
        check("rd_clr", rd_data, 0);

        // PC fuera de la imem (4 KB): devuelve 0
        read(32'h1000); check("fuera de rango 0x1000",     rd_data, 0);
        read(32'h80000000); check("fuera de rango bit 31", rd_data, 0);
        read(32'h0);    check("vuelve a leer bien",        rd_data, 32'h00500093);

        // Read-first: escribir y leer la misma palabra en el mismo ciclo
        @(negedge clk);
        wr_en = 1; wr_addr = 10'd0; wr_data = 32'h11111111;
        rd_en = 1; rd_addr = 32'h0;
        @(negedge clk);
        wr_en = 0; rd_en = 0;
        check("read-first devuelve el valor viejo", rd_data, 32'h00500093);
        read(32'h0);
        check("despues de escribir", rd_data, 32'h11111111);

        // Reescritura completa del rango: la ultima escritura gana
        for (i = 0; i < 1024; i = i + 1) write_word(i[9:0], i);
        read(32'h0);                check("barrido[0]",    rd_data, 0);
        read(32'h4 * 500);          check("barrido[500]",  rd_data, 500);
        read(32'h4 * 1023);         check("barrido[1023]", rd_data, 1023);

        if (errors == 0) $display("TEST PASSED: 0 errores");
        else             $display("TEST FAILED: %0d errores", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
