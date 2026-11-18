import argparse
import os
import random

X_WIDTH = 14
H_WIDTH = 14
TAPS = 15
PIPE_MUL = 1
PIPE_SUM = 1
PIPE_ROUND = 1

# Разные знаки крайних коэффициентов позволяют обнаружить обратный порядок отводов.
DEFAULT_COEFFS = [
    128, 256, 512, 768, 1024, 1536, 2048, 2304,
    2048, 1536, 1024, 768, 512, 256, -128,
]

assert len(DEFAULT_COEFFS) == TAPS


def saturate(value: int, width: int) -> int:
    max_val = (1 << (width - 1)) - 1
    min_val = -(1 << (width - 1))
    if value > max_val:
        return max_val
    if value < min_val:
        return min_val
    return value

def round_even(value: int, fraction_bits: int) -> int:
    """Округление к ближайшему целому с половинами к чётному."""
    scale = 1 << fraction_bits
    quotient, remainder = divmod(value, scale)
    if 2 * remainder > scale or (2 * remainder == scale and quotient % 2):
        quotient += 1
    return quotient


def fir_convolve(cycles, coeffs, data_width, coeff_width):
    """Эталон до задержки конвейера. При сбросе и паузе пишется ноль."""
    delay_line = [0] * len(coeffs)
    outputs = []

    for rst, ce, x in cycles:
        if rst:
            delay_line = [0] * len(coeffs)
            outputs.append(0)
        elif ce:
            delay_line = [x] + delay_line[:-1]
            total = sum(sample * coeff for sample, coeff in zip(delay_line, coeffs))
            rounded = round_even(total, coeff_width - 1)
            outputs.append(saturate(rounded, data_width))
        else:
            outputs.append(0)

    return outputs

def generate_stimulus(num_samples: int, data_width: int, num_taps: int, seed: int):
    rng = random.Random(seed)
    max_val = (1 << (data_width - 1)) - 1
    min_val = -(1 << (data_width - 1))

    # Импульс и две ступени предельной амплитуды.
    samples = [max_val]
    samples.extend([0] * (num_taps + 2))
    samples.extend([max_val] * (num_taps + 2))
    samples.extend([min_val] * (num_taps + 2))

    # Нечётные отсчёты дают половины при коэффициенте 0,5.
    edge_cases = [0, max_val, min_val, 1, -1, 3, -3, 5, -5]
    samples.extend(saturate(x, data_width) for x in edge_cases)

    while len(samples) < num_samples:
        samples.append(rng.randint(min_val, max_val))

    return samples[:num_samples]

def generate_cycles(samples, data_width: int, seed: int):
    rng = random.Random(seed + 1)
    max_val = (1 << (data_width - 1)) - 1
    min_val = -(1 << (data_width - 1))
    cycles = [(1, 0, 0), (1, 1, 0), (0, 0, max_val)]

    for idx, x in enumerate(samples):
        if idx == len(samples) // 2:
            # Сброс при обоих значениях ce.
            cycles.extend([(1, 0, min_val), (1, 1, max_val), (0, 0, min_val)])

        if rng.randrange(5) == 0:
            for _ in range(rng.randint(1, 3)):
                cycles.append((0, 0, rng.randint(min_val, max_val)))

        cycles.append((0, 1, x))

    cycles.extend([(0, 0, max_val), (0, 0, min_val)])
    return cycles


def main():
    parser = argparse.ArgumentParser(description="Generate test data for the FIR filter")
    parser.add_argument("--num-samples", type=int, default=200,
                        help="Number of accepted input samples; short runs truncate directed tests")
    parser.add_argument("--seed", type=int, default=42, help="RNG seed")
    parser.add_argument("--x-width", type=int, default=X_WIDTH, help="Input / output width")
    parser.add_argument("--h-width", type=int, default=H_WIDTH, help="Coefficient width")
    parser.add_argument("--coeffs", type=int, nargs="+", default=DEFAULT_COEFFS,
                        help="Signed coefficient codes, h_0 first; their count sets TAPS")
    parser.add_argument("--pipe-mul", type=int, choices=(0, 1), default=PIPE_MUL)
    parser.add_argument("--pipe-sum", type=int, choices=(0, 1), default=PIPE_SUM)
    parser.add_argument("--pipe-round", type=int, choices=(0, 1), default=PIPE_ROUND)
    parser.add_argument("--outdir", type=str,
                        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "build"),
                        help="Output directory for generated files")
    args = parser.parse_args()

    if args.num_samples < 1 or args.x_width < 1 or args.h_width < 1:
        parser.error("num-samples, x-width and h-width must be positive")
    if any(c != saturate(c, args.h_width) for c in args.coeffs):
        parser.error("every coefficient must fit in h-width signed bits; use --coeffs")

    num_taps = len(args.coeffs)
    samples = generate_stimulus(args.num_samples, args.x_width, num_taps, args.seed)
    cycles = generate_cycles(samples, args.x_width, args.seed)
    expected = fir_convolve(cycles, args.coeffs, args.x_width, args.h_width)

    os.makedirs(args.outdir, exist_ok=True)

    with open(os.path.join(args.outdir, "input_stimulus.txt"), "w") as f:
        for rst, ce, x in cycles:
            f.write(f"{rst} {ce} {x}\n")

    with open(os.path.join(args.outdir, "expected_output.txt"), "w") as f:
        for y in expected:
            f.write(f"{y}\n")

    with open(os.path.join(args.outdir, "coefficients.txt"), "w") as f:
        for c in args.coeffs:
            f.write(f"{c}\n")

    params = {
        "X_WIDTH": args.x_width,
        "H_WIDTH": args.h_width,
        "TAPS": num_taps,
        "PIPE_MUL": args.pipe_mul,
        "PIPE_SUM": args.pipe_sum,
        "PIPE_ROUND": args.pipe_round,
    }
    with open(os.path.join(args.outdir, "tb_params.vh"), "w") as f:
        for name, value in params.items():
            f.write(f"`define FIR_{name} {value}\n")

    print(f"Test data written to {args.outdir}")


if __name__ == "__main__":
    main()
