`timescale 1ns / 1ps
// Generador de Baud Rate

// Contador modulo-M que genera un tick de 1 ciclo de ancho cada M ciclos de clock.
// El tick corre a 16x el baud rate porque el receptor sobremuestrea la linea 16 veces
// por bit para poder ubicarse en el medio de cada bit.

// M = CLK_FREQ / (BAUD * 16), redondeado al entero mas cercano (D9)
//   100 MHz, 115200 -> M = 54  (error 0,47 %)
//    50 MHz, 115200 -> M = 27  (error 0,47 %)

// A diferencia de TP2, M y el ancho del contador se calculan solos a partir de
// CLK_FREQ y BAUD: si cambia el clock (TIME-3) alcanza con cambiar CLK_FREQ.

module baud_gen
#(
    parameter CLK_FREQ = 100_000_000,   // frecuencia del clock en Hz
    parameter BAUD     = 115200         // baud rate
)
(
    input  wire clk,
    input  wire reset,          // reset sincronico, activo en alto
    output wire tick
);

    localparam M = (CLK_FREQ + 8 * BAUD) / (16 * BAUD);     // division redondeada
    localparam N = (M > 1) ? $clog2(M) : 1;                 // bits para contar hasta M-1

    reg [N-1:0] count_reg;

    always @(posedge clk) begin
        if (reset)
            count_reg <= {N{1'b0}};
        else if (count_reg == (M - 1))
            count_reg <= {N{1'b0}};
        else
            count_reg <= count_reg + 1'b1;
    end

    // El tick vale 1 solo en el ultimo ciclo de la cuenta
    assign tick = (count_reg == (M - 1));

endmodule
