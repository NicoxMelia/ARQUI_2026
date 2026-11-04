`timescale 1ns / 1ps

// imem: memoria de programa de 1024 palabras de 32 bits (4 KB) detras de un
// wrapper (D7), para poder cambiar la implementacion (BRAM inferida, IP, etc.)
// sin tocar el core.
//
// Puerto de escritura (loader de la Debug Unit):
//   wr_en/wr_addr/wr_data. wr_addr es indice de PALABRA (0..1023). No depende
//   de ce: se escribe con el core detenido.
//
// Puerto de lectura (fetch del core):
//   rd_addr es la direccion de BYTE (el PC); los bits [1:0] se ignoran.
//   Lectura sincronica: rd_data es un registro que cambia solo con rd_en y
//   funciona como el campo instr del latch IF/ID.
//   rd_clr (prioridad sobre rd_en) pone rd_data en cero de forma sincronica:
//   es la burbuja de flush/reset del pipeline.
//   Un PC fuera de la imem (rd_addr[31:12] != 0) devuelve 0x00000000, que el
//   core trata como instruccion ilegal (D3).
//
// Si se escribe y se lee la misma palabra en el mismo ciclo, la lectura
// devuelve el valor viejo (read-first).
//
// INIT_FILE: archivo para $readmemh (vacio = memoria en cero). Es el estado
// inicial de la configuracion; la Debug Unit rellena con ceros al hacer LOAD.

module imem #(
    parameter INIT_FILE = ""
) (
    input  wire        clk,

    // Escritura (loader)
    input  wire        wr_en,
    input  wire [9:0]  wr_addr,
    input  wire [31:0] wr_data,

    // Lectura (fetch)
    input  wire        rd_en,
    input  wire        rd_clr,
    input  wire [31:0] rd_addr,
    output wire [31:0] rd_data
);

    reg [31:0] mem [0:1023];
    reg [31:0] mem_q;
    reg        oob_q;
    integer    k;

    initial begin
        for (k = 0; k < 1024; k = k + 1) mem[k] = 32'h0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk)
        if (wr_en) mem[wr_addr] <= wr_data;

    always @(posedge clk) begin
        if (rd_clr) begin
            mem_q <= 32'h0;
            oob_q <= 1'b0;
        end else if (rd_en) begin
            mem_q <= mem[rd_addr[11:2]];
            oob_q <= (rd_addr[31:12] != 20'd0);
        end
    end

    assign rd_data = oob_q ? 32'h0 : mem_q;

endmodule
