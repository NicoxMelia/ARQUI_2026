`timescale 1ns / 1ps
// Generador de Baud Rate

// Contador modulo-M que genera un tick de 1 ciclo de ancho cada M ciclos de clock.
// El tick corre a 16x el baud rate porque el receptor sobremuestrea la linea 16 veces
// por bit para poder ubicarse en el medio de cada bit.

// M = Clock / (BaudRate * 16)

// Clock = 100 MHz, BaudRate = 19200 -> M = 100_000_000 / (19200 * 16) = 326

module baud_gen
#(
    parameter M = 326,          // modulo del contador
    parameter N = 9             // cantidad de bits que se necesitan para contar hasta M-1
)
(
    input  wire clk,
    input  wire reset,          // reset sincronico, activo en alto
    output wire tick
);

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
