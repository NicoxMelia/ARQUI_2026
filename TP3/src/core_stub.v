`timescale 1ns / 1ps

// core_stub: core vacio con la interfaz definida en doc/interfaz_core.md.
//
// Sirve para desarrollar y probar la Debug Unit y la imem (hito M1) antes de
// que exista el pipeline real. Hace algo verificable:
//   - el PC avanza de a 4 con cada pulso de ce;
//   - lee la imem y guarda {instr, pc} en IF/ID;
//   - banco de registros falso: x_i = i;
//   - memoria de datos falsa: la palabra i vale 0xD0000000 | i;
//   - ebreak (0x00100073) levanta halted; la palabra 0x00000000 levanta
//     halted + illegal (D3). Despues de eso el PC no avanza y IF/ID se vacia.
// Los demas latches (ID/EX, EX/MEM, MEM/WB) quedan en cero.
//
// La imem es el wrapper imem.v (MEM-1, D7), el mismo que usara el core real,
// que reemplaza a este modulo con los mismos puertos.

module core_stub #(
    // Ciclos que dura el barrido de limpieza tras core_reset (el core real
    // barre la dmem de 1024 palabras). Bajarlo en los testbenches.
    parameter RESET_CYCLES = 1024
) (
    input  wire         clk,
    input  wire         rst,            // reset global de placa
    input  wire         ce,             // clock enable global (D1)
    input  wire         core_reset,     // lleva el core al estado inicial

    // Escritura de la memoria de programa (loader)
    input  wire         imem_we,
    input  wire [9:0]   imem_addr,      // indice de palabra
    input  wire [31:0]  imem_wdata,

    // Lectura de debug
    input  wire [4:0]   dbg_reg_addr,
    output wire [31:0]  dbg_reg_data,
    input  wire [9:0]   dbg_dmem_addr,  // indice de palabra
    output wire [31:0]  dbg_dmem_data,

    // Estado
    output wire         halted,
    output wire         illegal,
    output wire         pipeline_empty,
    output wire         reset_busy,
    output wire [12:0]  dmem_hwm,
    output wire [3:0]   dbg_valid,      // {MEM/WB, EX/MEM, ID/EX, IF/ID}

    // Buses planos
    output wire [31:0]  dbg_pc,
    output wire [63:0]  dbg_if_id,
    output wire [159:0] dbg_id_ex,
    output wire [79:0]  dbg_ex_mem,
    output wire [79:0]  dbg_mem_wb
);

    localparam [31:0] EBREAK = 32'h00100073;

    reg [31:0] pc;
    reg [31:0] if_id_pc;
    wire [31:0] if_id_instr;
    reg        if_id_valid;
    reg        halt_seen;
    reg        illegal_r;
    reg [15:0] sweep;

    wire clr = rst | core_reset;

    // Combinacional con clr para que la Debug Unit lo vea en el mismo ciclo
    // del pulso de core_reset y no tenga que esperar un ciclo "a ciegas".
    assign reset_busy = clr | (sweep != 16'd0);

    wire ce_eff   = ce & ~reset_busy;
    wire is_halt  = if_id_valid & (if_id_instr == EBREAK);
    wire is_ill   = if_id_valid & (if_id_instr == 32'h0);
    wire stop     = halt_seen | is_halt | is_ill;

    // La salida registrada de la imem es el campo instr de IF/ID: se carga con
    // la lectura y se pone en cero con la burbuja (reset o instruccion de parada).
    wire fetch = ce_eff & ~stop;

    imem u_imem (
        .clk(clk),
        .wr_en(imem_we), .wr_addr(imem_addr), .wr_data(imem_wdata),
        .rd_en(fetch & ~clr),
        .rd_clr(clr | (ce_eff & stop)),
        .rd_addr(pc),
        .rd_data(if_id_instr)
    );

    always @(posedge clk) begin
        if (clr) begin
            sweep <= RESET_CYCLES[15:0];
        end else if (sweep != 16'd0) begin
            sweep <= sweep - 16'd1;
        end
    end

    always @(posedge clk) begin
        if (clr) begin
            pc          <= 32'h0;
            if_id_pc    <= 32'h0;
            if_id_valid <= 1'b0;
            halt_seen   <= 1'b0;
            illegal_r   <= 1'b0;
        end else if (ce_eff) begin
            if (stop) begin
                if_id_pc    <= 32'h0;
                if_id_valid <= 1'b0;
                if (is_halt | is_ill) halt_seen <= 1'b1;
                if (is_ill)           illegal_r <= 1'b1;
            end else begin
                if_id_pc    <= pc;
                if_id_valid <= 1'b1;
                pc          <= pc + 32'd4;
            end
        end
    end

    assign halted         = halt_seen;
    assign illegal        = illegal_r;
    assign pipeline_empty = ~if_id_valid;
    assign dmem_hwm       = 13'd0;
    assign dbg_valid      = {3'b000, if_id_valid};

    assign dbg_reg_data   = {27'd0, dbg_reg_addr};
    assign dbg_dmem_data  = 32'hD0000000 | {22'd0, dbg_dmem_addr};

    assign dbg_pc         = pc;
    assign dbg_if_id      = {if_id_instr, if_id_pc};
    assign dbg_id_ex      = 160'd0;
    assign dbg_ex_mem     = 80'd0;
    assign dbg_mem_wb     = 80'd0;

endmodule
