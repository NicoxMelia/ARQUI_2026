`timescale 1ns / 1ps
// fifo - Buffer circular parametrizable

// Desacopla el UART (que va lento, a baud rate) de la logica interna (que va a 100 MHz).
// Es la parte de almacenamiento del Interface Circuit


module fifo
#(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
)
(
    input  wire                     clk,
    input  wire                     reset,      // activo en alto
    input  wire                     rd,
    input  wire                     wr,
    input  wire [DATA_WIDTH-1:0]    w_data,
    output wire [DATA_WIDTH-1:0]    r_data,
    output wire                     empty,
    output wire                     full
);

    reg [DATA_WIDTH-1:0] array_reg [2**ADDR_WIDTH-1:0];

    reg [ADDR_WIDTH-1:0] w_ptr_reg, w_ptr_next;
    reg [ADDR_WIDTH-1:0] r_ptr_reg, r_ptr_next;
    reg [ADDR_WIDTH-1:0] w_ptr_succ, r_ptr_succ;
    reg                  full_reg,  full_next;
    reg                  empty_reg, empty_next;

    wire wr_en;

    // Memoria
    assign wr_en = wr & ~full_reg;      // nunca escribe si esta llena

    always @(posedge clk) begin
        if (wr_en)
            array_reg[w_ptr_reg] <= w_data;
    end

    assign r_data = array_reg[r_ptr_reg];

    // Registros de control
    always @(posedge clk) begin
        if (reset) begin
            w_ptr_reg <= {ADDR_WIDTH{1'b0}};
            r_ptr_reg <= {ADDR_WIDTH{1'b0}};
            full_reg  <= 1'b0;
            empty_reg <= 1'b1;
        end
        else begin
            w_ptr_reg <= w_ptr_next;
            r_ptr_reg <= r_ptr_next;
            full_reg  <= full_next;
            empty_reg <= empty_next;
        end
    end

    // Logica de proximo estado de los punteros
    always @(*) begin
        w_ptr_succ = w_ptr_reg + 1'b1;
        r_ptr_succ = r_ptr_reg + 1'b1;

        w_ptr_next = w_ptr_reg;
        r_ptr_next = r_ptr_reg;
        full_next  = full_reg;
        empty_next = empty_reg;

        case ({wr, rd})
            2'b01: begin                        // solo lectura
                if (~empty_reg) begin
                    r_ptr_next = r_ptr_succ;
                    full_next  = 1'b0;
                    if (r_ptr_succ == w_ptr_reg)
                        empty_next = 1'b1;
                end
            end

            2'b10: begin                        // solo escritura
                if (~full_reg) begin
                    w_ptr_next = w_ptr_succ;
                    empty_next = 1'b0;
                    if (w_ptr_succ == r_ptr_reg)
                        full_next = 1'b1;
                end
            end

            2'b11: begin                        // lectura y escritura a la vez
                if (empty_reg) begin            // aca no hay nada que leer
                    w_ptr_next = w_ptr_succ;
                    empty_next = 1'b0;
                end
                else if (full_reg) begin        // aca no hay lugar para escribir
                    r_ptr_next = r_ptr_succ;
                    full_next  = 1'b0;
                end
                else begin
                    w_ptr_next = w_ptr_succ;
                    r_ptr_next = r_ptr_succ;
                end
            end

            default: ;                          // 2'b00: no pasa nada
        endcase
    end

    assign full  = full_reg;
    assign empty = empty_reg;

endmodule
