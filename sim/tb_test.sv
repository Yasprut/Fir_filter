`timescale 1ns / 1ps
`include "tb_params.vh"

module tb_test;

    localparam int X_WIDTH     = `FIR_X_WIDTH;
    localparam int H_WIDTH     = `FIR_H_WIDTH;
    localparam int TAPS        = `FIR_TAPS;
    localparam int PIPE_MUL    = `FIR_PIPE_MUL;
    localparam int PIPE_SUM    = `FIR_PIPE_SUM;
    localparam int PIPE_ROUND  = `FIR_PIPE_ROUND;
    localparam int PIPE_STAGES = PIPE_MUL + PIPE_SUM + PIPE_ROUND + 1;
    localparam int LATENCY     = PIPE_STAGES - 1;
    localparam real CLK_PERIOD_NS = 8.0;

    logic clk;
    logic rst;
    logic ce;

    logic signed [X_WIDTH-1:0] x;
    logic [TAPS*H_WIDTH-1:0]   h;
    wire signed [X_WIDTH-1:0]  y;
    wire                      y_valid;

    logic signed [X_WIDTH-1:0] expected_pipeline [0:PIPE_STAGES-1];
    logic [PIPE_STAGES-1:0]    valid_pipeline;

    int unsigned error_count;
    int unsigned checked_count;
    int unsigned accepted_count;
    int unsigned discarded_count;
    bit          driver_done;
    string       data_dir;

    fir_filter #(
        .X_WIDTH    (X_WIDTH),
        .H_WIDTH    (H_WIDTH),
        .TAPS       (TAPS),
        .PIPE_MUL   (PIPE_MUL),
        .PIPE_SUM   (PIPE_SUM),
        .PIPE_ROUND (PIPE_ROUND)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .ce      (ce),
        .x       (x),
        .h       (h),
        .y       (y),
        .y_valid (y_valid)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    task automatic load_coefficients;
        int fh, code;
        logic signed [H_WIDTH-1:0] value;

        fh = $fopen({data_dir, "/coefficients.txt"}, "r");
        if (fh == 0)
            $fatal(1, "[TB] ERROR: cannot open coefficients.txt. Run sim/test_fir.py first.");

        // Первый коэффициент занимает младшие биты h.
        for (int i = 0; i < TAPS; i++) begin
            code = $fscanf(fh, "%d\n", value);
            if (code != 1)
                $fatal(1, "[TB] ERROR: missing / malformed coefficient %0d", i);
            h[i*H_WIDTH +: H_WIDTH] = value;
        end

        code = $fscanf(fh, "%d\n", value);
        if (code != -1)
            $fatal(1, "[TB] ERROR: extra / malformed coefficient after TAPS entries");
        $fclose(fh);
    endtask

    task automatic apply_cycle(input bit next_rst, input bit next_ce,
                               input logic signed [X_WIDTH-1:0] next_x,
                               input logic signed [X_WIDTH-1:0] next_expected);
        @(negedge clk);
        rst = next_rst;
        ce  = next_ce;
        x   = next_x;

        @(posedge clk);
        if (rst) begin
            // Последний результат уже проверен. Сброс отменяет только ожидающие.
            for (int i = 0; i < LATENCY; i++) begin
                if (valid_pipeline[i]) discarded_count++;
            end
            for (int i = 0; i < PIPE_STAGES; i++) begin
                expected_pipeline[i] = '0;
            end
            valid_pipeline = '0;
        end else if (ce) begin
            for (int i = PIPE_STAGES-1; i > 0; i--) begin
                expected_pipeline[i] = expected_pipeline[i-1];
                valid_pipeline[i] = valid_pipeline[i-1];
            end
            expected_pipeline[0] = next_expected;
            valid_pipeline[0] = 1'b1;
            if (!driver_done) accepted_count++;
        end

        #1; // Дождаться обновления регистров DUT после фронта.
        if (y_valid !== valid_pipeline[PIPE_STAGES-1]) begin
            $display("[TB] FAIL @ %0t : y_valid expected = %b, got = %b, rst = %b, ce = %b",
                      $time, valid_pipeline[PIPE_STAGES-1], y_valid, rst, ce);
            error_count++;
        end
        if (y !== expected_pipeline[PIPE_STAGES-1]) begin
            $display("[TB] FAIL @ %0t : y expected = %0d, got = %0d, rst = %b, ce = %b",
                      $time, expected_pipeline[PIPE_STAGES-1], y, rst, ce);
            error_count++;
        end

        if (!rst && ce && valid_pipeline[PIPE_STAGES-1]) checked_count++;
    endtask

    task automatic measure_latency;
        int cycles;
        apply_cycle(1, 0, '0, '0);
        cycles = 0;

        while (y_valid !== 1'b1) begin
            apply_cycle(0, 1, '0, '0);
            cycles++;
            if (cycles > PIPE_STAGES)
                $fatal(1, "[TB] ERROR: y_valid never asserted at the expected edge");
            if (!y_valid) apply_cycle(0, 0, '0, '0);
        end

        if (cycles != PIPE_STAGES) begin
            $display("[TB] FAIL : first valid after %0d enabled edges, expected %0d",
                      cycles, PIPE_STAGES);
            error_count++;
        end
    endtask

    task automatic run_stimulus;
        int in_fh, exp_fh, code, exp_code;
        int rst_value, ce_value, row_count;
        logic signed [X_WIDTH-1:0] input_value, expected_value;

        in_fh  = $fopen({data_dir, "/input_stimulus.txt"}, "r");
        exp_fh = $fopen({data_dir, "/expected_output.txt"}, "r");
        if (in_fh == 0 || exp_fh == 0)
            $fatal(1, "[TB] ERROR: cannot open stimulus / expected files. Run sim/test_fir.py first.");

        row_count = 0;
        while (!$feof(in_fh)) begin
            code = $fscanf(in_fh, "%d %d %d\n", rst_value, ce_value, input_value);
            if (code == 3) begin
                exp_code = $fscanf(exp_fh, "%d\n", expected_value);
                if (exp_code != 1)
                    $fatal(1, "[TB] ERROR: missing / malformed expected result at row %0d", row_count);
                if ((rst_value != 0 && rst_value != 1) || (ce_value != 0 && ce_value != 1))
                    $fatal(1, "[TB] ERROR: rst and ce must be 0 or 1 at row %0d", row_count);

                apply_cycle(rst_value != 0, ce_value != 0, input_value, expected_value);
                row_count++;
            end else if (code != -1) begin
                $fatal(1, "[TB] ERROR: malformed stimulus at row %0d", row_count);
            end
        end

        exp_code = $fscanf(exp_fh, "%d\n", expected_value);
        if (exp_code != -1)
            $fatal(1, "[TB] ERROR: extra / malformed expected result after the stimulus");
        if (accepted_count == 0)
            $fatal(1, "[TB] ERROR: stimulus contains no accepted samples");

        $fclose(in_fh);
        $fclose(exp_fh);
        driver_done = 1'b1;
    endtask

    task automatic drain_pipeline;
        // За LATENCY тактов на выход дойдут последние отсчёты из файла.
        repeat (LATENCY) apply_cycle(0, 1, '0, '0);
        if (checked_count + discarded_count != accepted_count)
            $fatal(1, "[TB] ERROR: count mismatch: accepted %0d, checked %0d, reset discarded %0d",
                      accepted_count, checked_count, discarded_count);
        if (checked_count == 0)
            $fatal(1, "[TB] ERROR: no output samples checked");
    endtask

    initial begin
        error_count     = 0;
        checked_count   = 0;
        accepted_count  = 0;
        discarded_count = 0;
        driver_done     = 1'b0;
        valid_pipeline  = '0;
        rst = 1'b1;
        ce  = 1'b0;
        x   = '0;
        h   = '0;

        if (!$value$plusargs("DATA_DIR=%s", data_dir)) data_dir = "sim/build";
        $dumpfile({data_dir, "/tb_test.vcd"});
        $dumpvars(0, tb_test);
        load_coefficients();

        measure_latency();

        apply_cycle(1, 0, '0, '0);
        // Заново считаем отсчёты, сохраняя ошибки проверки задержки.
        checked_count   = 0;
        accepted_count  = 0;
        discarded_count = 0;

        run_stimulus();
        drain_pipeline();

        if (error_count != 0)
            $fatal(1, "[TB] RESULT : FAIL (%0d error(s), %0d outputs checked)",
                      error_count, checked_count);
        $display("[TB] RESULT : PASS (%0d outputs matched, %0d pending results discarded by reset)",
                  checked_count, discarded_count);
        $finish(0);
    end

    initial begin
        #(CLK_PERIOD_NS * 2000000);
        $fatal(1, "[TB] ERROR: global simulation timeout reached");
    end

endmodule
