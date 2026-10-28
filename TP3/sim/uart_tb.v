`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_tb - Testbench autochequeante de la UART sola (DBG-1)
//
// Corre los mismos casos a dos frecuencias de clock (100 MHz y 50 MHz) con
// 115200 baudios reales, para verificar que el divisor sale de CLK_FREQ/BAUD:
//
//   1. Loopback (tx -> rx): 0x00, 0xFF, 0xA5, 0x5A y una rafaga de 16 bytes
//      seguidos (llena la FIFO de Tx). Ademas un monitor decodifica la linea tx
//      con la temporizacion ideal de 115200 baudios.
//   2. Bytes enviados por el testbench con temporizacion ideal.
//   3. Error de trama forzado (bit de stop en 0): se levanta frame_err, el
//      byte se descarta y clr_err lo limpia.
//   4. Glitch de 1/4 de bit en la linea: no se recibe nada.
//   5. Overrun: 17 bytes sin leer la FIFO (16 lugares): se levanta rx_overrun
//      y los primeros 16 bytes llegan intactos.
//
// Con Icarus:  make sim TB=uart_tb
//////////////////////////////////////////////////////////////////////////////

module uart_tb;

    uart_tb_case #(.CLK_FREQ(100_000_000), .NAME("100 MHz")) c100 ();
    uart_tb_case #(.CLK_FREQ( 50_000_000), .NAME(" 50 MHz")) c50  ();

    initial begin
        wait (c100.done && c50.done);
        if (c100.errors + c50.errors == 0)
            $display("TEST PASSED: 0 errores");
        else
            $display("TEST FAILED: %0d errores", c100.errors + c50.errors);
        $finish;
    end

    // Watchdog: los dos casos terminan en ~5 ms de tiempo simulado
    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout del testbench");
        $finish;
    end

endmodule


module uart_tb_case
#(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200,
    parameter NAME     = "case"
);

    localparam real CLK_NS = 1.0e9 / CLK_FREQ;
    localparam real BIT_NS = 1.0e9 / BAUD;

    reg         clk = 1'b0;
    reg         reset;
    reg         wr_uart;
    reg  [7:0]  w_data;
    reg         clr_err;
    wire [7:0]  r_data;
    wire        rx_empty;
    wire        tx_full;
    wire        frame_err;
    wire        rx_overrun;
    wire        tx;

    reg         loopback;       // 1: rx = tx de la propia UART; 0: rx = tb_rx
    reg         tb_rx;          // linea manejada por el testbench
    reg         auto_read;      // 1: el testbench vacia la FIFO de Rx
    wire        rx_line = loopback ? tx : tb_rx;
    wire        rd_uart = auto_read & ~rx_empty;

    integer     errors = 0;
    reg         done   = 1'b0;

    // Bytes leidos de la FIFO de Rx y bytes decodificados de la linea tx
    reg  [7:0]  rx_buf  [0:63];
    integer     rx_cnt  = 0;
    reg  [7:0]  mon_buf [0:63];
    integer     mon_cnt = 0;
    reg  [7:0]  exp_buf [0:63];

    integer     i;
    integer     base;

    always #(CLK_NS / 2.0) clk = ~clk;

    uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .rd_uart    (rd_uart),
        .wr_uart    (wr_uart),
        .w_data     (w_data),
        .r_data     (r_data),
        .rx_empty   (rx_empty),
        .tx_full    (tx_full),
        .clr_err    (clr_err),
        .frame_err  (frame_err),
        .rx_overrun (rx_overrun),
        .rx         (rx_line),
        .tx         (tx)
    );

    // Consumidor de la FIFO de Rx
    always @(posedge clk) begin
        if (rd_uart) begin
            rx_buf[rx_cnt] <= r_data;
            rx_cnt         <= rx_cnt + 1;
        end
    end

    // Monitor de la linea tx con la temporizacion ideal de BAUD
    always begin : monitor_tx
        reg [7:0] b;
        integer   k;
        @(negedge tx);
        #(BIT_NS / 2.0);
        if (tx !== 1'b0) begin
            $display("[%s] ERROR: start invalido en tx", NAME);
            errors = errors + 1;
        end
        for (k = 0; k < 8; k = k + 1) begin
            #(BIT_NS);
            b[k] = tx;
        end
        #(BIT_NS);
        if (tx !== 1'b1) begin
            $display("[%s] ERROR: stop en 0 en tx (byte 0x%02h)", NAME, b);
            errors = errors + 1;
        end
        mon_buf[mon_cnt] = b;
        mon_cnt          = mon_cnt + 1;
    end

    // --- Tareas ---

    // Manda un byte por tb_rx con la temporizacion ideal. stop_bit=0 fuerza error de trama.
    task send_byte(input [7:0] b, input stop_bit);
        integer k;
        begin
            tb_rx = 1'b0;               // start
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                tb_rx = b[k];           // LSB primero
                #(BIT_NS);
            end
            tb_rx = stop_bit;
            #(BIT_NS);
            tb_rx = 1'b1;               // reposo
        end
    endtask

    // Escribe un byte en la FIFO de Tx (espera si esta llena)
    task write_tx(input [7:0] b);
        begin
            @(negedge clk);
            while (tx_full) @(negedge clk);
            wr_uart = 1'b1;
            w_data  = b;
            @(negedge clk);
            wr_uart = 1'b0;
        end
    endtask

    task pulse_clr_err;
        begin
            @(negedge clk);
            clr_err = 1'b1;
            @(negedge clk);
            clr_err = 1'b0;
        end
    endtask

    task wait_bits(input integer n);
        begin
            #(n * BIT_NS);
        end
    endtask

    task check(input cond, input [8*48-1:0] msg);
        begin
            if (!cond) begin
                $display("[%s] ERROR: %0s", NAME, msg);
                errors = errors + 1;
            end
        end
    endtask

    // Compara n bytes de rx_buf (desde first) con exp_buf
    task check_rx(input integer first, input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                if (rx_buf[first + k] !== exp_buf[k]) begin
                    $display("[%s] ERROR: rx[%0d] = 0x%02h, esperado 0x%02h",
                             NAME, first + k, rx_buf[first + k], exp_buf[k]);
                    errors = errors + 1;
                end
        end
    endtask

    // --- Secuencia de prueba ---
    initial begin
        reset     = 1'b1;
        wr_uart   = 1'b0;
        w_data    = 8'h00;
        clr_err   = 1'b0;
        loopback  = 1'b1;
        tb_rx     = 1'b1;
        auto_read = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk) reset = 1'b0;
        wait_bits(2);

        // 1. Loopback: patrones y rafaga de 16 bytes
        exp_buf[0] = 8'h00;
        exp_buf[1] = 8'hFF;
        exp_buf[2] = 8'hA5;
        exp_buf[3] = 8'h5A;
        for (i = 0; i < 16; i = i + 1)
            exp_buf[4 + i] = 8'h10 + i;
        for (i = 0; i < 20; i = i + 1)
            write_tx(exp_buf[i]);
        wait (rx_cnt == 20 || $time > 4_000_000);
        wait_bits(2);
        check(rx_cnt == 20,  "loopback: no llegaron los 20 bytes");
        check(mon_cnt == 20, "monitor tx: no se decodificaron 20 bytes");
        check_rx(0, 20);
        for (i = 0; i < 20; i = i + 1)
            if (mon_buf[i] !== exp_buf[i]) begin
                $display("[%s] ERROR: tx[%0d] = 0x%02h, esperado 0x%02h",
                         NAME, i, mon_buf[i], exp_buf[i]);
                errors = errors + 1;
            end
        check(!frame_err && !rx_overrun, "loopback: flag de error en 1");

        // 2. Bytes enviados por el testbench
        loopback = 1'b0;
        base     = rx_cnt;
        exp_buf[0] = 8'h3C;
        exp_buf[1] = 8'hC3;
        send_byte(8'h3C, 1'b1);
        send_byte(8'hC3, 1'b1);
        wait_bits(1);
        check(rx_cnt == base + 2, "tb -> rx: no llegaron 2 bytes");
        check_rx(base, 2);

        // 3. Error de trama
        base = rx_cnt;
        send_byte(8'h81, 1'b0);
        wait_bits(1);
        check(frame_err,          "frame_err no se levanto");
        check(rx_cnt == base,     "byte con error de trama llego a la FIFO");
        pulse_clr_err;
        check(!frame_err,         "clr_err no limpio frame_err");
        exp_buf[0] = 8'h42;
        send_byte(8'h42, 1'b1);
        wait_bits(1);
        check(rx_cnt == base + 1, "byte valido despues del error no llego");
        check_rx(base, 1);
        check(!frame_err,         "frame_err se levanto con un byte valido");

        // 4. Glitch de 1/4 de bit
        base  = rx_cnt;
        tb_rx = 1'b0;
        #(BIT_NS / 4.0);
        tb_rx = 1'b1;
        wait_bits(12);
        check(rx_cnt == base,     "glitch: se recibio un byte");
        check(!frame_err,         "glitch: se levanto frame_err");

        // 5. Overrun: 17 bytes sin leer
        auto_read = 1'b0;
        base      = rx_cnt;
        for (i = 0; i < 17; i = i + 1) begin
            exp_buf[i] = 8'h80 + i;
            send_byte(8'h80 + i, 1'b1);
        end
        wait_bits(1);
        check(rx_overrun,         "rx_overrun no se levanto");
        auto_read = 1'b1;
        wait_bits(1);
        check(rx_cnt == base + 16, "overrun: no quedaron 16 bytes en la FIFO");
        check_rx(base, 16);
        pulse_clr_err;
        check(!rx_overrun,        "clr_err no limpio rx_overrun");

        $display("[%s] %0d errores", NAME, errors);
        done = 1'b1;
    end

endmodule
