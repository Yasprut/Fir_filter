module fir_filter #(
    parameter integer X_WIDTH = 14,
    parameter integer H_WIDTH = 14,
    parameter integer TAPS = 15,
    parameter integer PIPE_MUL = 1,
    parameter integer PIPE_SUM = 1,
    parameter integer PIPE_ROUND = 1
)(
    input wire clk,
    input wire rst,
    input wire ce,
    input wire signed [X_WIDTH-1:0] x,
    // h[k*H_WIDTH +: H_WIDTH] — signed-код коэффициента при x[n-k].
    // Реальное значение коэффициента: signed-код / 2**(H_WIDTH-1).
    input wire [TAPS*H_WIDTH-1:0] h,
    output reg signed [X_WIDTH-1:0] y,
    // Достоверность y после заполнения конвейера. При ce=0 сохраняется;
    // высокий уровень на паузе не означает появление нового результата.
    output wire y_valid
);

    localparam integer PIPE_STAGES =
        (PIPE_MUL == 1) + (PIPE_SUM == 1) + (PIPE_ROUND == 1) + 1;

    // Число разрешённых тактовых интервалов от захвата x до обновления y.
    localparam integer LATENCY = PIPE_STAGES - 1;

    localparam integer SUM_WIDTH = X_WIDTH + H_WIDTH + $clog2(TAPS);

    localparam integer D = H_WIDTH - 1; // Число дробных битов коэффициента.

    localparam signed [X_WIDTH-1:0] MAX_CODE = (2 ** (X_WIDTH-1)) - 1;

    localparam signed [X_WIDTH-1:0] MIN_CODE = -(2 ** (X_WIDTH-1));



    integer i;
    integer j;
    genvar g;

    reg [PIPE_STAGES-1:0] valid_pipeline;
    integer valid_index;

    always @(posedge clk) begin
        if (rst)
            valid_pipeline <= 0;
        else if (ce) begin
            valid_pipeline[0] <= 1'b1;
            for (valid_index = 1; valid_index < PIPE_STAGES;
                 valid_index = valid_index + 1) begin
                valid_pipeline[valid_index] <= valid_pipeline[valid_index-1];
            end
        end
    end

    assign y_valid = valid_pipeline[PIPE_STAGES-1];



    wire signed [X_WIDTH-1:0] samples [0:TAPS-1];

    wire signed [X_WIDTH+H_WIDTH-1:0] products [0:TAPS-1];

    assign samples[0] = x;

    generate
        if (TAPS > 1) begin : with_history


            reg signed [X_WIDTH-1:0] history [0:TAPS-2];

            always @(posedge clk) begin
                if (rst) begin
                    for (i = 0; i < TAPS-1; i = i + 1) begin
                        history[i] <= 0;

                    end
                end else if (ce) begin

                    history[0] <= x;

                    for (i = 1; i < TAPS-1; i = i + 1) begin
                        history[i] <= history[i-1];

                    end
                end
            end

            for (g = 1; g < TAPS; g = g + 1) begin : delayed
                assign samples[g] = history[g-1];
            end
        end

        for (g = 0; g < TAPS; g = g + 1) begin : result

            wire signed [X_WIDTH+H_WIDTH-1:0] product;
            assign product = samples[g] * $signed(h[g*H_WIDTH +: H_WIDTH]);

            if (PIPE_MUL == 1) begin : with_pipeline

                reg signed [X_WIDTH+H_WIDTH-1:0] product_reg;


                always @(posedge clk) begin
                    if (rst)
                        product_reg <= 0;
                    else if (ce)
                        product_reg <= product;
                end

                assign products[g] = product_reg;

            end else begin : without_pipeline

                assign products[g] = product;

            end
        end
    endgenerate


    reg signed [SUM_WIDTH-1:0] sum;


    always @* begin
        sum = 0;

        for (j = 0; j < TAPS; j = j + 1) begin
            sum = sum + products[j];
        end
    end



    wire signed [SUM_WIDTH-1:0] sum_stage;
    wire signed [SUM_WIDTH-1:0] round_value;
    wire signed [SUM_WIDTH-1:0] rounded_stage;
    wire signed [X_WIDTH-1:0] saturated_value;


    generate
        if (PIPE_SUM == 1) begin : sum_with

            reg signed [SUM_WIDTH-1:0] sum_reg;

            always @(posedge clk) begin
                if (rst)
                    sum_reg <= 0;
                else if (ce)
                    sum_reg <= sum;
            end

            assign sum_stage = sum_reg;

        end else begin : sum_without

            assign sum_stage = sum;

        end
    endgenerate

    generate
        if (D > 0) begin : with_fraction

            localparam signed [SUM_WIDTH:0] ROUND_BIAS = 2 ** (D-1);
            wire [D-1:0] R; // Отбрасываемые дробные биты.
            wire signed [SUM_WIDTH-1:0] scaled_sum;

            assign scaled_sum = sum_stage >>> D;
            assign R = sum_stage[D-1:0];

            // Округление до ближайшего, при равенстве — к чётному.
            assign round_value =
                (R > ROUND_BIAS)        ? scaled_sum + 1 :
                (R < ROUND_BIAS)        ? scaled_sum :
                (scaled_sum[0] == 1'b1) ? scaled_sum + 1 :
                                         scaled_sum;

        end else begin : without_fraction

            // При H_WIDTH=1 дробных битов нет, округление не требуется.
            assign round_value = sum_stage;

        end
    endgenerate

    generate
        if (PIPE_ROUND == 1) begin : sum_withr

            reg signed [SUM_WIDTH-1:0] rounded_reg;

            always @(posedge clk) begin
                if (rst)
                    rounded_reg <= 0;
                else if (ce)
                    rounded_reg <= round_value;
            end

            assign rounded_stage = rounded_reg;

        end else begin : sum_withoutr

            assign rounded_stage = round_value;

        end
    endgenerate



    
    assign saturated_value =
        (rounded_stage > MAX_CODE) ? MAX_CODE :
        (rounded_stage < MIN_CODE) ? MIN_CODE : rounded_stage[X_WIDTH-1:0];



    always @(posedge clk) begin
        if (rst)
            y <= 0;
        else if (ce)
            y <= saturated_value;
    end

endmodule
