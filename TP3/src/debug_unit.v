`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// debug_unit - Debug Unit: FSM que atiende los comandos de la PC (DBG-2)
//
// Se conecta del lado de la UART a la interfaz tipo cola de uart.v
// (r_data/rd_uart/rx_empty, w_data/wr_uart/tx_full, frame_err/rx_overrun/
// clr_err) y del lado del core a la interfaz de doc/interfaz_core.md.
//
// Controla el core SOLO con ce, core_reset y la escritura de la imem: el
// clock nunca se toca (D1). Protocolo en doc/protocolo_uart.md:
//
//   PING  (0x01) -> ACK
//   RESET (0x03) -> pulso de core_reset, espera !reset_busy, ACK
//   STEP  (0x04) -> ce=1 exactamente un ciclo, DUMP
//   RUN   (0x05) -> ce=1 hasta halted && pipeline_empty o hasta STOP, DUMP
//                   (mientras corre solo se atiende STOP, D12)
//   STOP  (0x06) -> fuera de RUN responde ACK
//   DUMP  (0x07) -> DUMP
//   LOAD  (0x02) y READ_DMEM (0x08): se reciben y validan los argumentos;
//                   la ejecucion la agregan DBG-3 y DBG-5 (hoy: NACK 0x01).
//
// Timeout: si dentro de una trama pasan TIMEOUT_CYCLES (10 ms) sin recibir
// un byte, se responde NACK 0x02 y se vuelve a IDLE.
// Errores a mitad de trama (BAD_ARG, UART_ERR): se descarta lo que siga
// llegando hasta TIMEOUT_CYCLES de silencio y recien ahi se responde el
// NACK, asi el resto de la trama no se interpreta como comandos (D14).
//
// Volcado: despues de bajar ce se espera un ciclo (HOLD), se copia el estado
// a un snapshot (SNAP) y se serializa desde esa copia. Cada byte de la
// respuesta usa dos ciclos (TX_PREP + TX_WR) para respetar la latencia de
// 1 ciclo de los puertos de lectura de debug del core.
// Payload del DUMP (DBG-4, 181 B, interfaz_core.md seccion 4):
//   status | PC | x0..x31 | IF/ID | ID/EX | EX/MEM | MEM/WB
// status, PC y latches salen del snapshot; los registros se leen por
// dbg_reg_addr/dbg_reg_data mientras se transmite (con ce=0 no cambian).
//
// fsm_state expone el estado one-hot para los LEDs de la placa (INT-1).
//////////////////////////////////////////////////////////////////////////////

module debug_unit
#(
    parameter CLK_FREQ       = 100_000_000,     // Hz
    parameter TIMEOUT_CYCLES = CLK_FREQ / 100   // 10 ms entre bytes de una trama
)
(
    input  wire          clk,
    input  wire          reset,          // sincronico, activo en alto

    // --- UART (interfaz de uart.v) ---
    output reg           rd_uart,
    input  wire          rx_empty,
    input  wire [7:0]    r_data,
    output reg           wr_uart,
    input  wire          tx_full,
    output reg  [7:0]    w_data,
    output reg           clr_err,
    input  wire          frame_err,
    input  wire          rx_overrun,

    // --- Control del core ---
    output reg           ce,
    output reg           core_reset,
    input  wire          reset_busy,

    // --- Escritura de la imem (loader) ---
    output reg           imem_we,
    output reg  [9:0]    imem_addr,
    output reg  [31:0]   imem_wdata,

    // --- Lectura de debug ---
    output wire [4:0]    dbg_reg_addr,
    input  wire [31:0]   dbg_reg_data,
    output wire [9:0]    dbg_dmem_addr,
    input  wire [31:0]   dbg_dmem_data,

    // --- Estado del core ---
    input  wire          halted,
    input  wire          illegal,
    input  wire          pipeline_empty,
    input  wire [12:0]   dmem_hwm,
    input  wire [3:0]    dbg_valid,
    input  wire [31:0]   dbg_pc,
    input  wire [63:0]   dbg_if_id,
    input  wire [159:0]  dbg_id_ex,
    input  wire [79:0]   dbg_ex_mem,
    input  wire [79:0]   dbg_mem_wb,

    // --- LEDs ---
    output wire [10:0]   fsm_state
);

    // ------------------------------------------------------------------
    // Constantes del protocolo (doc/protocolo_uart.md)
    // ------------------------------------------------------------------
    localparam [7:0] CMD_PING      = 8'h01,
                     CMD_LOAD      = 8'h02,
                     CMD_RESET     = 8'h03,
                     CMD_STEP      = 8'h04,
                     CMD_RUN       = 8'h05,
                     CMD_STOP      = 8'h06,
                     CMD_DUMP      = 8'h07,
                     CMD_READ_DMEM = 8'h08;

    localparam [7:0] SOF           = 8'hAA;
    localparam [7:0] T_ACK         = 8'h10,
                     T_NACK        = 8'h11,
                     T_DUMP        = 8'h20;

    localparam [7:0] E_UNKNOWN_CMD = 8'h01,
                     E_TIMEOUT     = 8'h02,
                     E_BAD_ARG     = 8'h03,
                     E_UART_ERR    = 8'h05;

    localparam [15:0] DUMP_LEN     = 16'd181;    // 133 + L, L = 8 + 20 + 10 + 10
    localparam [15:0] IMEM_WORDS   = 16'd1024;

    localparam TW = $clog2(TIMEOUT_CYCLES + 1);  // bits del contador de timeout

    // ------------------------------------------------------------------
    // Estados (one-hot)
    // ------------------------------------------------------------------
    localparam [10:0] S_IDLE     = 11'b00000000001,  // espera un comando
                      S_ARGS     = 11'b00000000010,  // recibe argumentos (LOAD, READ_DMEM)
                      S_DRAIN    = 11'b00000000100,  // descarta el resto de una trama con error
                      S_RST      = 11'b00000001000,  // pulso de core_reset
                      S_RST_WAIT = 11'b00000010000,  // espera !reset_busy
                      S_STEP     = 11'b00000100000,  // ce=1 un ciclo
                      S_RUN      = 11'b00001000000,  // ce=1 hasta HALT o STOP
                      S_HOLD     = 11'b00010000000,  // un ciclo con ce=0 antes del snapshot
                      S_SNAP     = 11'b00100000000,  // copia el estado del core
                      S_TX_PREP  = 11'b01000000000,  // prepara el byte (latencia de lectura)
                      S_TX_WR    = 11'b10000000000;  // escribe el byte en la FIFO de Tx

    // ------------------------------------------------------------------
    // Registros
    // ------------------------------------------------------------------
    reg [10:0]   state_reg,    state_next;
    reg [7:0]    cmd_reg,      cmd_next;       // comando en curso
    reg [2:0]    argc_reg,     argc_next;      // bytes de argumento recibidos
    reg [31:0]   args_reg,     args_next;      // argumentos (little-endian)
    reg [TW-1:0] tmo_reg,      tmo_next;       // ciclos sin recibir
    reg [7:0]    err_reg,      err_next;       // codigo de NACK pendiente (DRAIN)

    // Respuesta en curso: [SOF][rsp_type][rsp_len 2 B][payload]
    reg [7:0]    rsp_type_reg, rsp_type_next;
    reg [15:0]   rsp_len_reg,  rsp_len_next;
    reg [31:0]   rsp_pl_reg,   rsp_pl_next;    // payload de ACK/NACK (hasta 4 B)
    reg [7:0]    tx_idx_reg,   tx_idx_next;    // byte de la trama que se envia

    // Snapshot del volcado
    reg [7:0]    snap_status_reg, snap_status_next;
    reg [31:0]   snap_pc_reg,     snap_pc_next;
    reg [383:0]  snap_lat_reg,    snap_lat_next;   // {MEM/WB, EX/MEM, ID/EX, IF/ID}

    // ------------------------------------------------------------------
    // Senales auxiliares
    // ------------------------------------------------------------------
    wire         uart_err   = frame_err | rx_overrun;
    wire         tmo_done   = (tmo_reg == TIMEOUT_CYCLES - 1);
    wire [TW-1:0] tmo_inc   = tmo_reg + 1'b1;
    wire         core_done  = halted & pipeline_empty;
    wire         stop_head  = ~rx_empty & (r_data == CMD_STOP);
    wire [2:0]   argc_need  = (cmd_reg == CMD_LOAD) ? 3'd2 : 3'd4;
    wire [15:0]  frame_len  = rsp_len_reg + 16'd4;
    wire [7:0]   pl_idx     = tx_idx_reg - 8'd4;           // indice dentro del payload

    // len de LOAD: el byte alto es el que llega en este ciclo
    wire [15:0]  load_len   = {r_data, args_reg[7:0]};

    // Byte del payload del DUMP segun su offset (interfaz_core.md, seccion 4)
    //   0        status
    //   1..4     PC
    //   5..132   x0..x31 (registro (p-5)/4, byte (p-5)%4)
    //   133..180 latches (byte p-133 del snapshot)
    wire [7:0]   pc_off     = pl_idx - 8'd1;
    wire [7:0]   reg_off    = pl_idx - 8'd5;
    wire [7:0]   lat_off    = pl_idx - 8'd133;

    reg  [7:0]   dump_byte;
    always @(*) begin
        if (pl_idx == 8'd0)
            dump_byte = snap_status_reg;
        else if (pl_idx < 8'd5)
            dump_byte = snap_pc_reg[8*pc_off[1:0] +: 8];
        else if (pl_idx < 8'd133)
            dump_byte = dbg_reg_data[8*reg_off[1:0] +: 8];
        else
            dump_byte = snap_lat_reg[8*lat_off[5:0] +: 8];
    end

    // Byte de la trama de respuesta que corresponde a tx_idx
    reg  [7:0]   frame_byte;
    always @(*) begin
        case (tx_idx_reg)
            8'd0:    frame_byte = SOF;
            8'd1:    frame_byte = rsp_type_reg;
            8'd2:    frame_byte = rsp_len_reg[7:0];
            8'd3:    frame_byte = rsp_len_reg[15:8];
            default: frame_byte = (rsp_type_reg == T_DUMP) ? dump_byte
                                                           : rsp_pl_reg[8*pl_idx[1:0] +: 8];
        endcase
    end

    // Registro a leer: queda fijo desde TX_PREP, asi el dato se muestrea en
    // TX_WR un ciclo despues de poner la direccion (latencia de 1 ciclo, D8)
    assign dbg_reg_addr  = reg_off[6:2];

    // La lectura de la dmem llega con READ_DMEM (DBG-5)
    assign dbg_dmem_addr = 10'd0;

    // ------------------------------------------------------------------
    // Memoria
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state_reg       <= S_IDLE;
            cmd_reg         <= 8'h00;
            argc_reg        <= 3'd0;
            args_reg        <= 32'h0;
            tmo_reg         <= {TW{1'b0}};
            err_reg         <= 8'h00;
            rsp_type_reg    <= 8'h00;
            rsp_len_reg     <= 16'd0;
            rsp_pl_reg      <= 32'h0;
            tx_idx_reg      <= 8'd0;
            snap_status_reg <= 8'h00;
            snap_pc_reg     <= 32'h0;
            snap_lat_reg    <= 384'h0;
        end
        else begin
            state_reg       <= state_next;
            cmd_reg         <= cmd_next;
            argc_reg        <= argc_next;
            args_reg        <= args_next;
            tmo_reg         <= tmo_next;
            err_reg         <= err_next;
            rsp_type_reg    <= rsp_type_next;
            rsp_len_reg     <= rsp_len_next;
            rsp_pl_reg      <= rsp_pl_next;
            tx_idx_reg      <= tx_idx_next;
            snap_status_reg <= snap_status_next;
            snap_pc_reg     <= snap_pc_next;
            snap_lat_reg    <= snap_lat_next;
        end
    end

    // ------------------------------------------------------------------
    // Logica de proximo estado
    // ------------------------------------------------------------------

    // Arma una respuesta ACK/NACK y pasa a transmitirla
    task respond(input [7:0] typ, input [15:0] len, input [31:0] pl);
        begin
            rsp_type_next = typ;
            rsp_len_next  = len;
            rsp_pl_next   = pl;
            tx_idx_next   = 8'd0;
            state_next    = S_TX_PREP;
        end
    endtask

    // Error a mitad de trama: descartar hasta silencio y despues NACK
    task drain(input [7:0] code);
        begin
            err_next   = code;
            tmo_next   = {TW{1'b0}};
            state_next = S_DRAIN;
        end
    endtask

    always @(*) begin
        state_next       = state_reg;
        cmd_next         = cmd_reg;
        argc_next        = argc_reg;
        args_next        = args_reg;
        tmo_next         = tmo_reg;
        err_next         = err_reg;
        rsp_type_next    = rsp_type_reg;
        rsp_len_next     = rsp_len_reg;
        rsp_pl_next      = rsp_pl_reg;
        tx_idx_next      = tx_idx_reg;
        snap_status_next = snap_status_reg;
        snap_pc_next     = snap_pc_reg;
        snap_lat_next    = snap_lat_reg;

        rd_uart    = 1'b0;
        wr_uart    = 1'b0;
        w_data     = frame_byte;
        clr_err    = 1'b0;
        ce         = 1'b0;
        core_reset = 1'b0;
        imem_we    = 1'b0;
        imem_addr  = 10'd0;
        imem_wdata = 32'h0;

        case (state_reg)
            S_IDLE: begin
                if (uart_err) begin
                    // Llego basura: no hay comando valido para informar
                    clr_err  = 1'b1;
                    cmd_next = 8'h00;
                    drain(E_UART_ERR);
                end
                else if (~rx_empty) begin
                    rd_uart   = 1'b1;
                    cmd_next  = r_data;
                    argc_next = 3'd0;
                    args_next = 32'h0;
                    tmo_next  = {TW{1'b0}};
                    case (r_data)
                        CMD_PING:      respond(T_ACK, 16'd1, {24'h0, CMD_PING});
                        CMD_LOAD:      state_next = S_ARGS;
                        CMD_RESET:     state_next = S_RST;
                        CMD_STEP:      state_next = S_STEP;
                        CMD_RUN:       state_next = S_RUN;
                        CMD_STOP:      respond(T_ACK, 16'd1, {24'h0, CMD_STOP});
                        CMD_DUMP:      state_next = S_HOLD;
                        CMD_READ_DMEM: state_next = S_ARGS;
                        default:       respond(T_NACK, 16'd2, {16'h0, E_UNKNOWN_CMD, r_data});
                    endcase
                end
            end

            S_ARGS: begin
                if (uart_err) begin
                    clr_err = 1'b1;
                    drain(E_UART_ERR);
                end
                else if (~rx_empty) begin
                    rd_uart                    = 1'b1;
                    tmo_next                   = {TW{1'b0}};
                    args_next[8*argc_reg +: 8] = r_data;
                    argc_next                  = argc_reg + 3'd1;
                    if (argc_reg + 3'd1 == argc_need) begin
                        if (cmd_reg == CMD_LOAD) begin
                            if (load_len == 16'd0 || load_len > IMEM_WORDS)
                                drain(E_BAD_ARG);       // los datos van a llegar igual
                            else
                                drain(E_UNKNOWN_CMD);   // PROVISORIO: LOAD llega en DBG-3
                        end
                        else begin
                            // READ_DMEM: la trama ya termino, la ejecucion es de DBG-5
                            respond(T_NACK, 16'd2, {16'h0, E_UNKNOWN_CMD, cmd_reg});
                        end
                    end
                end
                else if (tmo_done)
                    respond(T_NACK, 16'd2, {16'h0, E_TIMEOUT, cmd_reg});
                else
                    tmo_next = tmo_inc;
            end

            S_DRAIN: begin
                clr_err = 1'b1;
                if (~rx_empty) begin
                    rd_uart  = 1'b1;
                    tmo_next = {TW{1'b0}};
                end
                else if (tmo_done)
                    respond(T_NACK, 16'd2, {16'h0, err_reg, cmd_reg});
                else
                    tmo_next = tmo_inc;
            end

            S_RST: begin
                core_reset = 1'b1;
                state_next = S_RST_WAIT;
            end

            S_RST_WAIT: begin
                if (~reset_busy)
                    respond(T_ACK, 16'd1, {24'h0, CMD_RESET});
            end

            S_STEP: begin
                // Mientras el core se limpia ignora ce: esperar
                if (~reset_busy) begin
                    ce         = 1'b1;
                    state_next = S_HOLD;
                end
            end

            S_RUN: begin
                // Solo se atiende STOP; el resto se descarta (D12)
                clr_err = 1'b1;
                if (~rx_empty)
                    rd_uart = 1'b1;
                if (stop_head | core_done)
                    state_next = S_HOLD;            // ce baja en este mismo ciclo
                else
                    ce = ~reset_busy;
            end

            S_HOLD: begin
                state_next = S_SNAP;
            end

            S_SNAP: begin
                snap_status_next = {1'b0, dbg_valid, pipeline_empty, illegal, halted};
                snap_pc_next     = dbg_pc;
                snap_lat_next    = {dbg_mem_wb, dbg_ex_mem, dbg_id_ex, dbg_if_id};
                respond(T_DUMP, DUMP_LEN, 32'h0);
            end

            S_TX_PREP: begin
                // Un ciclo para que los puertos de debug entreguen el dato
                state_next = S_TX_WR;
            end

            S_TX_WR: begin
                if (~tx_full) begin
                    wr_uart     = 1'b1;
                    tx_idx_next = tx_idx_reg + 8'd1;
                    if ({8'd0, tx_idx_reg} == frame_len - 16'd1)
                        state_next = S_IDLE;
                    else
                        state_next = S_TX_PREP;
                end
            end

            default: state_next = S_IDLE;           // recuperacion ante fallos
        endcase
    end

    assign fsm_state = state_reg;

endmodule
