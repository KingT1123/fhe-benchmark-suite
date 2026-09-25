// bench_seal.cpp
//
// Benchmark harness for Microsoft SEAL (BFV, CKKS, BGV), implementing the
// protocol defined in Chapter 3 (Methodology) of the thesis:
//   - parameter grid from ../../config/param_grid.csv (N x NIST category),
//     shared by all three schemes — BGV reuses the exact same rows as BFV
//     (same plain-modulus/batching setup, same coeff-modulus chains); SEAL
//     4.1.2 needs no BGV-specific grid, confirmed against its source (see
//     build_context() below)
//   - fresh ciphertexts generated each iteration (matches HEProfiler's own
//     convention, chosen deliberately after the 4x cache-effect discrepancy
//     found during the earlier HEProfiler reproduction phase)
//   - one CLI invocation = one (scheme, N, category, operation) cell
//   - writes ONE ROW PER ITERATION (no aggregation here — aggregate.py does
//     mean/std/95% CI/median/IQR and warm-up discarding, so statistics live
//     in exactly one place)
//
// Usage:
//   ./bench_seal --scheme=BFV --N=8192 --category=1 --operation=multiply \
//                --reps=100 --warmup=5 --out=results/raw/seal_bfv_8192_c1_multiply.csv
//
// Operations: keygen, encrypt, decrypt, add, multiply, relinearize, size,
// noise_trace, ckks_error, config_metadata, rotate, dot_product, poly_eval
// Multiply-family operations (multiply, relinearize) are skipped with a
// clear message when the EFFECTIVE depth for that (N, category) is 0 — see
// "grid depth vs. effective depth" below and Chapter 3 Section 3.4 for why
// multiply-family ops are undefined at depth 0 in the first place.
//
// grid depth vs. effective depth: param_grid.csv's `depth` column counts
// modulus-chain length. For CKKS that number IS the multiply-then-rescale
// ceiling by construction, so CKKS keeps using grid.depth everywhere,
// unchanged. For BFV/BGV, chain length is only an upper bound — the real
// ceiling is wherever invariant_noise_budget() actually hits 0, which can
// differ from the chain-length count. compute_effective_depth() (BFV/BGV
// only) measures this directly by probing multiply+relinearize rounds on a
// throwaway ciphertext; its result (not grid.depth) is what gates the
// depth==0 skip and how many rounds run_noise_trace chains through for
// BFV/BGV. Both numbers are logged side by side (grid_depth, effective_depth)
// in the noise_trace CSV so they're never silently conflated.
//
// --operation=size: Chapter 3's storage metric (serialized ciphertext/key
// size). Deterministic given a config, so unlike the six operations above
// it does NOT run the warmup/reps loop — one row per artifact
// (ciphertext, public_key, secret_key, relin_keys), written by a fully
// separate code path (see run_size_operation) that returns before the
// timing loop even starts, so it cannot affect the isolated per-operation
// timing logic used by Standard/Constrained/Edge-Batch. Sizes are measured
// with compr_mode_type::none explicitly, so the reported number is raw
// serialized bytes regardless of which compression library (zstd/zlib/
// none) this particular SEAL build happened to default to.
//
// --operation=noise_trace: Chapter 3's noise-budget-evolution metric,
// BFV/BGV only (SEAL's Decryptor::invariant_noise_budget throws for
// CKKS — CKKS gets a clean skipped_not_applicable_ckks row instead, no
// context is even built for it). This is a genuinely CHAINED
// measurement, by design different from the isolated-operation timing
// above — the isolation convention that keeps ops untouched-by-each-other
// exists to protect TIMING purity, and this operation measures a bit
// count, not wall-clock, so chaining is exactly the point here. Traces
// fresh -> 1x add -> effective_depth x (multiply -> relinearize), where
// effective_depth is compute_effective_depth()'s measured noise-budget
// ceiling for this (N, category), NOT grid.depth (chain length) — see the
// "grid depth vs. effective depth" note at the top of this file. NOTE this
// is a deliberate change from tracing exactly grid.depth rounds: since
// effective_depth is itself defined as "the deepest round that still had
// budget left", the trace by construction no longer probes past where the
// budget runs out, so it can no longer surface a "grid claimed depth D but
// budget actually died before round D" mismatch the way it used to — that
// comparison now has to be read off grid_depth vs. effective_depth (both
// logged per row) instead of off where the trace's own numbers hit zero.
// Runs --trace-reps trials (default 10, independent of --reps/--warmup,
// since this is a near-deterministic bit count, not a noisy wall-clock
// measurement needing 100 statistical repetitions).
// Fully separate code path (run_noise_trace), like --operation=size.
//
// --operation=ckks_error: Chapter 3's CKKS-error-accumulation metric,
// CKKS only (BFV/BGV are exact schemes with no rounding error by
// construction — BFV/BGV get a clean skipped_not_applicable_bfv row
// instead, no context built). SEAL has no CKKS noise-budget equivalent
// (Decryptor::invariant_noise_budget throws for CKKS), so this measures
// error the only way available: track a known plaintext vector alongside
// the encrypted computation, and diff decrypt+decode against it at each
// step. Same chained shape and depth-stopping rule as noise_trace (fresh
// -> 1x add -> grid.depth x (multiply -> relinearize)), but with one
// deliberate divergence from every timed CKKS operation elsewhere in this
// file: this trace rescales after every multiply
// (evaluator->rescale_to_next_inplace), even though build_context's own
// comment explains the timed operations never rescale, by design, to
// isolate each operation's raw per-op cost. That isolation goal doesn't
// apply to an error-accumulation trace — without rescaling, the scale
// keeps squaring every round and the trace would mostly measure how fast
// an unrescaled scale explodes, not realistic CKKS error accumulation.
// Fully separate code path (run_ckks_error_trace), like size/noise_trace.
//
// --batch-size=B (default 1, Scenario A/B behavior unchanged at B=1):
//   Edge/Batch scenario (Chapter 3: "packs multiple values per ciphertext
//   and measures throughput on the baseline workstation" — a multi-user/
//   streaming scenario, not IoT, despite the name). Each timed trial
//   processes B independent items back-to-back, sharing one key (generated
//   once, same as any real batch-processing deployment would do — this does
//   NOT reuse ciphertexts across items, so the "fresh ciphertext every
//   iteration" convention still holds per item). One row in the output CSV
//   is now the total wall time for one B-item trial, not one item; deriving
//   per-item throughput from that is aggregate.py's job, not this harness's
//   (statistics stay in exactly one place, per convention). batch-size has
//   no effect on keygen — its cost doesn't depend on how large a batch is
//   processed after the keys exist, so it always runs as a single untimed-
//   setup-free operation; amortizing it across a batch size is a downstream
//   aggregate.py computation, not something measured here.
//
// --inner-loop=K (default 1000, encrypt/decrypt/add/multiply/relinearize
//   only — not keygen, already coarse-grained enough not to need it):
//   Standard/Constrained's single-call-per-rep timing was too coarse for
//   fast ops relative to Clock::now()'s resolution and OS jitter (83/112
//   measurements flagged HIGH_VARIANCE in the first full report). Instead
//   of timing 1 call, each timed region now runs batch_size * K calls
//   back-to-back against batch_size*K distinct freshly-generated items
//   (setup still entirely untimed, before t0 — same fresh-ciphertext-per-
//   call convention as ever, just applied K times more per rep), takes ONE
//   t0/t1 for the whole inner loop, and returns total_ms / K. At K=1 this
//   is byte-for-byte the old single-call-per-rep behavior, so batch_size's
//   existing "total wall time for one B-item trial" semantics are exactly
//   preserved (K just averages that total over K repetitions of it to kill
//   timer noise) — this is why run_edge_batch_docker.sh pins --inner-loop=1
//   explicitly: Edge/Batch's per-invocation RAPL/peak-memory accounting
//   assumes one B-item trial per process, and K>1 would both multiply that
//   accounting's denominator wrongly and blow up an already-expensive sweep
//   (B=100 * K=1000 would be 100,000 fresh ciphertexts per rep).
//
// --fill-pct=X (0.0 <= X <= 1.0, encrypt/add/multiply/size only): Packing
//   scenario -- how many of a ciphertext's AVAILABLE slots hold a real value
//   vs. zero-padding, as opposed to Edge/Batch's axis (how many SEPARATE
//   ciphertexts). Deliberately independent of --batch-size: this file's
//   generic --batch-size/--inner-loop machinery is untouched by this flag,
//   and every packing run uses batch-size=1. Given slot_count (BFV/BGV: N;
//   CKKS: N/2, from BatchEncoder/CKKSEncoder::slot_count(), same values
//   config_metadata already logs), computes
//     n_real = max(1, round(fill_pct * slot_count))
//   and encodes a vector with n_real real (sequential, nonzero, non-trivial)
//   values followed by zero-padding out to slot_count, then encrypts that as
//   normal. fill_pct=0.0 is the "single real value" level (n_real=1, a
//   literal count, not a percentage) -- it isn't special-cased; it falls out
//   of the same max(1, round(...)) floor used for every other level. Uses
//   its own dedicated ciphertext generator (fresh_ciphertext_partial_fill)
//   and timed functions (time_*_partial_fill), entirely separate from
//   fresh_ciphertext()/time_encrypt()/time_add()/time_multiply() above, so
//   this addition cannot change the encoded content or measured cost of any
//   existing scenario (Standard/Constrained/Edge-Batch/noise_trace/
//   ckks_error all still call the untouched originals). Only
//   encrypt/add/multiply/size are supported under --fill-pct (keygen/
//   decrypt/relinearize aren't central to the packing question -- see
//   run_packing_docker.sh); multiply still respects the same depth==0
//   undefined-operation skip as the generic path. size measures whether the
//   serialized ciphertext size actually depends on fill level or is fixed
//   regardless (measured, not assumed) -- own CSV schema
//   (library,scheme,N,category,fill_pct,n_real,slot_count,artifact,
//   size_bytes,status), one row (artifact=ciphertext) per call, same
//   deterministic-no-timing-loop shape as --operation=size above. Timed rows
//   use their own schema too (library,scheme,N,category,operation,fill_pct,
//   n_real,slot_count,iteration,latency_ms,status) -- n_real/slot_count
//   logged on every row per the packing question, alongside the usual
//   columns, not replacing them.
//
// --operation=rotate / dot_product / poly_eval: Composite scenario --
//   chained (multi-operation) workloads, testing whether single-operation
//   timing (Standard scenario) predicts multi-operation cost, as opposed to
//   every other operation in this file, which is deliberately ISOLATED
//   (one SEAL call per timed region). All three are scoped by
//   run_composite_docker.sh to N=8192/category=1 only.
//
//   --operation=rotate: a real, isolated, single rotate-by-1 measurement --
//   built so Composite's predictions are built from a REAL measured
//   rotation cost, not approximated by another operation's cost. Setup
//   (context/keys, INCLUDING a separately-generated GaloisKeys) happens
//   once, untimed, before the reps loop, same isolation convention as every
//   other operation; only the single rotate_rows/rotate_vector call is
//   timed. Galois key generation is deliberately timed SEPARATELY from
//   build_context()'s other key generation (which already covers public/
//   secret/relin key cost via --operation=keygen) via its own KeyGenerator
//   built from the SAME secret key -- this is a genuinely NEW cost this
//   file didn't measure before. Its generation time (galois_keygen_ms) and
//   serialized size (galois_keys_size_bytes, via the same serialized_size()
//   helper relin_keys' own size measurement already uses) are logged as
//   constant companion columns on every row of THIS operation's own CSV --
//   not added to the shared --operation=size output, so Standard/
//   Constrained/Edge-Batch/Packing's existing size measurements for every
//   other scheme/config stay completely unchanged.
//
//   --operation=dot_product (needs --vec-len=N, a literal slot count, NOT a
//   percentage -- distinct from Packing's --fill-pct): encodes two
//   vec_len-length vectors (BFV/BGV integers, CKKS doubles), zero-padded to
//   slot_count, then times the WHOLE chain as ONE unit: elementwise
//   multiply -> relinearize -> ceil(log2(vec_len)) rotate-and-add steps
//   (the standard SIMD doubling sum-reduction), leaving the dot product
//   total in slot 0 ONLY. CORRECTION (extra-rigor item 1's real
//   correctness check caught this): an earlier version of this comment
//   claimed the total also lands in "every other summed slot" as a side
//   effect -- verified false by direct measurement (N=8192/BFV, vec_len=8:
//   slot 0 = the correct total 240, slot 1 = 238, slot 2 = 232, ...,
//   monotonically decreasing partial sums, not copies of the total). With
//   zero-padding (vec_len < slot_count, the normal case here), only slot 0
//   is guaranteed correct; the real correctness check below verifies slot
//   0 only, not a false "every slot" claim. BFV/BGV row-crossing note: BatchEncoder
//   presents N total slots as a 2x(N/2) matrix; rotate_rows only rotates
//   WITHIN a row (wraps at N/2), rotate_columns swaps the two rows (no step
//   parameter). For vec_len <= N/2 the whole vector fits in one row and
//   plain rotate_rows doubling is exact. Only vec_len == the full slot
//   count (== N, spanning both rows -- this file's only such case) needs
//   the LAST doubling step to be rotate_columns instead of rotate_rows:
//   since every vec_len this file sweeps is an exact power of two, that
//   crossing always lands on exactly one whole step (shift == row_size
//   exactly), never a partial/misaligned case -- CKKS never hits this
//   branch at all (CKKSEncoder has no row split; rotate_vector treats all
//   slot_count() slots as one flat cyclic vector). For BFV/BGV, the
//   resulting ciphertext's noise budget is read immediately after the
//   chain completes (reusing invariant_noise_budget(), the same call
//   noise_trace already uses) and logged per row -- untimed, after the
//   chain's t0/t1 window, so it cannot affect the latency measurement;
//   empty for CKKS (invariant_noise_budget throws for CKKS, same
//   limitation noise_trace already documents).
//
//   --operation=poly_eval: a*x^2 + b*x + c (a=2, b=3, c=5 -- arbitrary
//   small nonzero constants, chosen and documented here since this file is
//   the only place they're set) on a single fully-packed x, no --vec-len
//   (purely elementwise, no rotation -- a length sweep isn't expected to
//   show anything new for an elementwise-only chain, so this stays a single
//   fixed measurement, deliberately kept simple). Evaluated via Horner's
//   method ((a*x+b)*x+c) rather than computing x^2 and b*x as two separate
//   branches to combine -- Horner keeps every step on ONE monotonically-
//   growing CKKS scale path (each constant is encoded at the exact scale
//   the running ciphertext will have at the point it's combined), so no
//   rescale/mod-switch is needed and this still respects the file's "timed
//   CKKS ops never rescale" isolation convention (unlike ckks_error's own
//   deliberate, documented exception).
//
//   --operation=rotate_only / add_only (needs --vec-len=N, same convention
//   as dot_product: k=ceil_log2(vec_len)): BFV/BGV-only isolated noise
//   controls (extra-rigor item 3) -- run ONLY k rotations or ONLY k adds
//   (same k, same shifts, as dot_product's own combined chain at that
//   vec_len), tracking noise_budget_bits and a real correctness check
//   (decrypt->decode->compare every slot) after every step. Purpose: the
//   combined dot_product chain's noise-budget decline alone can't say
//   whether rotations or adds are responsible -- these let the report
//   attribute it to whichever actually causes it. Fully separate code
//   path (run_rotate_only_trace / run_add_only_trace), same shape as
//   noise_trace.
//
// Real correctness checking (extra-rigor item 1): noise_trace, dot_product
// (BFV/BGV), rotate_only/add_only, and ckks_error all record a REAL
// decrypt->decode->compare verdict (BFV/BGV: exact match on every slot,
// tracked independently in plaintext mod the actual plain_modulus;
// CKKS: max_abs_error < CKKS_CORRECTNESS_THRESHOLD, see that constant's
// own comment for the reasoning) alongside their existing noise_budget_bits
// / max_abs_error numbers -- replacing "noise budget stayed above zero" or
// "didn't throw" as an implicit correctness proxy with an explicit,
// independently-verified one.
//
// --vec-len=N (dot_product only): see above. Validated against the
//   context's actual slot_count once the context is built (not at CLI-parse
//   time, since slot_count depends on scheme/N, not knowable from args alone).
//
// --operation=config_metadata: logs the parameter facts a reader needs to
//   interpret every other metric (poly_modulus_degree, coeff_modulus chain,
//   secret/error distribution, batching, and scheme-specific fields) that
//   were previously only partially captured (N/chain/depth) or not written
//   anywhere at all. Deterministic given a config, one row per (scheme, N,
//   category) — same "own CSV schema, own function, header written before
//   the possibly-throwing call, returns before the timing loop" shape as
//   size/noise_trace/ckks_error.

#include <seal/seal.h>
#include <chrono>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <random>
#include <iostream>
#include <stdexcept>
#include <cmath>
#include <algorithm>
#include <utility>

using namespace seal;
using Clock = std::chrono::steady_clock;

// ---------- CLI parsing ----------

struct Args {
    std::string scheme;      // "BFV", "CKKS", or "BGV"
    int N = 0;
    int category = 0;        // 1, 3, or 5
    std::string operation;   // keygen, encrypt, decrypt, add, multiply, relinearize
    int reps = 100;
    int warmup = 5;
    int batch_size = 1;      // Edge/Batch scenario: items processed per timed
                              // trial. 1 == identical behavior to Scenario A/B.
    int trace_reps = 10;     // --operation=noise_trace / ckks_error only: trial
                              // count, independent of --reps (bit-count/error
                              // trace, not a noisy wall-clock measurement).
    int inner_loop = 1000;   // encrypt/decrypt/add/multiply/relinearize only:
                              // calls averaged per timed rep, see header comment.
    bool fill_pct_set = false;  // Packing scenario: true only when --fill-pct=
                                 // was explicitly passed -- gates a completely
                                 // separate code path in main(), see header comment.
    double fill_pct = 1.0;      // fraction of slot_count that holds a real value
                                 // (0.0 == the n_real=1 single-value level).
    int vec_len = 0;            // --operation=dot_product only: literal real-
                                 // value count (NOT a percentage -- distinct
                                 // from --fill-pct), 0 == unset.
    std::string out;
    std::string grid_path = "../../config/param_grid.csv";
};

static std::string arg_value(const std::string &a) {
    auto pos = a.find('=');
    if (pos == std::string::npos) throw std::runtime_error("Bad argument: " + a);
    return a.substr(pos + 1);
}

Args parse_args(int argc, char **argv) {
    Args args;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("--scheme=", 0) == 0) args.scheme = arg_value(a);
        else if (a.rfind("--N=", 0) == 0) args.N = std::stoi(arg_value(a));
        else if (a.rfind("--category=", 0) == 0) args.category = std::stoi(arg_value(a));
        else if (a.rfind("--operation=", 0) == 0) args.operation = arg_value(a);
        else if (a.rfind("--reps=", 0) == 0) args.reps = std::stoi(arg_value(a));
        else if (a.rfind("--warmup=", 0) == 0) args.warmup = std::stoi(arg_value(a));
        else if (a.rfind("--batch-size=", 0) == 0) args.batch_size = std::stoi(arg_value(a));
        else if (a.rfind("--trace-reps=", 0) == 0) args.trace_reps = std::stoi(arg_value(a));
        else if (a.rfind("--inner-loop=", 0) == 0) args.inner_loop = std::stoi(arg_value(a));
        else if (a.rfind("--fill-pct=", 0) == 0) { args.fill_pct = std::stod(arg_value(a)); args.fill_pct_set = true; }
        else if (a.rfind("--vec-len=", 0) == 0) args.vec_len = std::stoi(arg_value(a));
        else if (a.rfind("--out=", 0) == 0) args.out = arg_value(a);
        else if (a.rfind("--grid=", 0) == 0) args.grid_path = arg_value(a);
        else throw std::runtime_error("Unknown argument: " + a);
    }
    if (args.scheme.empty() || args.N == 0 || args.category == 0 ||
        args.operation.empty() || args.out.empty()) {
        throw std::runtime_error(
            "Required: --scheme= --N= --category= --operation= --out=");
    }
    if (args.batch_size < 1) {
        throw std::runtime_error("--batch-size must be >= 1");
    }
    if (args.inner_loop < 1) {
        throw std::runtime_error("--inner-loop must be >= 1");
    }
    if (args.fill_pct_set && (args.fill_pct < 0.0 || args.fill_pct > 1.0)) {
        throw std::runtime_error("--fill-pct must be in [0.0, 1.0]");
    }
    return args;
}

// ---------- param_grid.csv lookup ----------

struct GridRow {
    int N, category, security_bits, logq_used, depth;
    std::string chain;
};

// "60+40*7+60" -> {60,40,40,40,40,40,40,40,60}
std::vector<int> parse_chain(const std::string &chain) {
    std::vector<int> bits;
    std::stringstream ss(chain);
    std::string token;
    while (std::getline(ss, token, '+')) {
        auto star = token.find('*');
        if (star == std::string::npos) {
            bits.push_back(std::stoi(token));
        } else {
            int bit = std::stoi(token.substr(0, star));
            int count = std::stoi(token.substr(star + 1));
            for (int i = 0; i < count; i++) bits.push_back(bit);
        }
    }
    return bits;
}

GridRow load_grid_row(const std::string &path, int N, int category) {
    std::ifstream f(path);
    if (!f.is_open()) throw std::runtime_error("Cannot open param grid: " + path);
    std::string line;
    std::getline(f, line);  // header
    while (std::getline(f, line)) {
        std::stringstream ss(line);
        std::string cell;
        std::vector<std::string> cells;
        while (std::getline(ss, cell, ',')) cells.push_back(cell);
        if (cells.size() < 6) continue;
        GridRow row;
        row.N = std::stoi(cells[0]);
        row.category = std::stoi(cells[1]);
        row.security_bits = std::stoi(cells[2]);
        row.chain = cells[3];
        row.logq_used = std::stoi(cells[4]);
        row.depth = std::stoi(cells[5]);
        if (row.N == N && row.category == category) return row;
    }
    throw std::runtime_error("No param grid row for N=" + std::to_string(N) +
                              " category=" + std::to_string(category));
}

// ---------- context setup ----------

struct Ctx {
    std::shared_ptr<SEALContext> context;
    SecretKey secret_key;
    PublicKey public_key;
    RelinKeys relin_keys;
    GaloisKeys galois_keys;   // Composite scenario only (rotate/dot_product);
                              // empty/unused by every other operation.
    std::unique_ptr<Encryptor> encryptor;
    std::unique_ptr<Evaluator> evaluator;
    std::unique_ptr<Decryptor> decryptor;
    std::unique_ptr<BatchEncoder> batch_encoder;   // BFV only
    std::unique_ptr<CKKSEncoder> ckks_encoder;     // CKKS only
    double ckks_scale = 0.0;
};

// Plaintext modulus for BFV/BGV cells. Every cell uses SEAL's standard
// 20-bit batching prime -- NOT one fixed constant across the whole grid:
// PlainModulus::Batching(N, 20) is a real search for a prime t of at most
// 20 bits with t = 1 (mod 2N), and that congruence depends on N, so the
// prime it lands on depends on N too. Confirmed directly (--operation=
// config_metadata, reading the value back from the built SEALContext, not
// just assumed from the call site): N in {2048, 4096, 8192} all land on
// t=1032193; N=16384 lands on a different prime, t=786433 (786433 mod
// 32768 = 1, so it's a genuine, correctly-congruent 20-bit batching prime
// for that N, not a mistake or a fallback). Separately from that, three
// cells' coeff-modulus chains were shrunk to meet the 2024/2025
// security-guideline re-verification (Chapter 3, security-level
// validation): at the standard 20-bit t, those three specific chains leave
// zero real noise budget (fresh ciphertexts already fail to decrypt
// correctly), so they use a smaller batching-compatible prime instead --
// the smallest that restores a real, positive margin (see
// sec_methodology.tex's Table~\ref{tab:configmeta-bfvbgv} note). Every
// other cell, including every other N=2048/4096 category and all of
// N=16384, is unaffected by that second exception.
Modulus bfv_bgv_plain_modulus(int N, int category) {
    if (N == 2048 && (category == 1 || category == 5)) return PlainModulus::Batching(N, 14);  // 12289
    if (N == 4096 && category == 5) return PlainModulus::Batching(N, 16);  // 40961
    // N in {2048,4096,8192} -> 1032193; N=16384 -> 786433 (both confirmed
    // via config_metadata, see comment above -- same call, N-dependent result).
    return PlainModulus::Batching(N, 20);
}

// CKKS initial scale (bits). Every cell uses the shared formula computed
// in build_context() below (min(40, (total_bits-10)/2), reserving headroom
// for one future multiply) EXCEPT five cells whose reduced chain (Chapter
// 3, security-level validation) made that formula either unusably
// imprecise or needlessly conservative. Each override here is the
// empirically best scale found by direct round-trip testing against the
// new chain (see sec_methodology.tex's Table~\ref{tab:configmeta-ckks}
// note), not re-derived from a formula -- the shared formula's own
// multiply-safety margin is exactly what most of these needed to deviate
// from (four of the five are depth-0 and never multiply, so that reserved
// margin was precision they didn't need to give up).
int ckks_scale_bits_override(int N, int category, int default_bits) {
    if (N == 2048 && category == 1) return 24;
    if (N == 2048 && category == 3) return 15;  // best achievable at this
        // N/chain -- total_coeff_modulus_bit_count()=17, one bit below the
        // structural ceiling (16 already throws "scale out of bounds" in
        // SEAL). Still leaves ~8% max decode error: a genuine structural
        // limitation of this cell, not a clean fix -- see
        // sec_methodology.tex's Table~\ref{tab:configmeta-ckks} note.
        // Report this cell's CKKS results with that caveat attached.
    if (N == 4096 && category == 3) return 32;
    if (N == 4096 && category == 5) return 24;
    if (N == 8192 && category == 5) return 40;  // strictly better than the
        // 24 bits the plain formula would otherwise allow here -- brings
        // this cell in line with every other comfortably-precise cell
        // instead of leaving it borderline.
    return default_bits;  // N=4096/cat=1 and N=8192/cat=3 keep the shared
                           // formula unchanged -- both already work well.
}

Ctx build_context(const Args &args, const GridRow &grid) {
    Ctx c;
    std::vector<int> chain_bits = parse_chain(grid.chain);

    if (args.scheme == "BFV") {
        EncryptionParameters parms(scheme_type::bfv);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        parms.set_plain_modulus(bfv_bgv_plain_modulus(args.N, args.category));
        c.context = std::make_shared<SEALContext>(parms);
        c.batch_encoder = std::make_unique<BatchEncoder>(*c.context);
    } else if (args.scheme == "BGV") {
        // Mirrors the BFV branch exactly: BGV supports batching identically
        // (BatchEncoder accepts scheme_type::bgv, confirmed against SEAL
        // 4.1.2's own batchencoder.cpp), uses the same PlainModulus::Batching
        // NTT-friendly-prime helper, and reuses the same param_grid.csv rows
        // (chain lengths there are a function of security level and N, not
        // scheme). BGV ciphertexts are NTT-form by construction (SEAL's
        // encryptor.cpp sets is_ntt_form=true for both ckks and bgv), which
        // is also exactly what Decryptor::invariant_noise_budget requires
        // for BGV — see compute_effective_depth() below.
        EncryptionParameters parms(scheme_type::bgv);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        parms.set_plain_modulus(bfv_bgv_plain_modulus(args.N, args.category));
        c.context = std::make_shared<SEALContext>(parms);
        c.batch_encoder = std::make_unique<BatchEncoder>(*c.context);
    } else if (args.scheme == "CKKS") {
        EncryptionParameters parms(scheme_type::ckks);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        c.context = std::make_shared<SEALContext>(parms);
        c.ckks_encoder = std::make_unique<CKKSEncoder>(*c.context);
    } else {
        throw std::runtime_error("Unsupported scheme (SEAL implements BFV/CKKS/BGV only): " + args.scheme);
    }

    if (!c.context->parameters_set()) {
        throw std::runtime_error("Invalid SEAL parameters for N=" + std::to_string(args.N) +
                                  " category=" + std::to_string(args.category) +
                                  " (" + c.context->parameter_error_message() + ")");
    }

    if (args.scheme == "CKKS") {
        // The scale must satisfy log2(scale) < total_coeff_modulus_bit_count()
        // at encode time, AND after one multiply the scale is SQUARED, so
        // 2*log2(scale) must also stay under that same bound (we don't
        // rescale in these micro-benchmarks, by design, to isolate each
        // operation's raw cost). SEAL's "data level" budget already excludes
        // the chain's last prime (reserved for key-switching) -- e.g. for
        // N=4096 category 1 (chain 36+37+36) the nominal sum is 109 bits but
        // the actual usable budget is 73 bits. A fixed 2^40 scale silently
        // assumed enough headroom for every config; it doesn't for small N.
        int total_bits = c.context->first_context_data()->total_coeff_modulus_bit_count();
        int usable_bits = total_bits - 10;  // safety margin
        int default_scale_bits = std::min(40, usable_bits / 2);
        if (default_scale_bits < 1) default_scale_bits = 1;
        int scale_bits = ckks_scale_bits_override(args.N, args.category, default_scale_bits);
        c.ckks_scale = std::pow(2.0, scale_bits);
    }

    KeyGenerator keygen(*c.context);
    c.secret_key = keygen.secret_key();
    keygen.create_public_key(c.public_key);
    if (grid.depth > 0) keygen.create_relin_keys(c.relin_keys);
    // Galois keys (rotate/dot_product, Composite scenario) are generated
    // separately, per-operation, minimal to the exact steps each one uses
    // (item 4) -- not here, and not via the library's expensive no-argument
    // default. See main()'s "rotate" and "dot_product" dispatch branches.

    c.encryptor = std::make_unique<Encryptor>(*c.context, c.public_key);
    c.evaluator = std::make_unique<Evaluator>(*c.context);
    c.decryptor = std::make_unique<Decryptor>(*c.context, c.secret_key);
    return c;
}

// ---------- fresh plaintext/ciphertext generators (per iteration) ----------

std::mt19937_64 rng(12345);  // fixed seed: reproducibility across runs

// Returns both the ciphertext AND the exact plaintext vector it encodes --
// needed by real correctness checking (item 1: noise_trace/dot_product must
// compare decoded output against an independently-tracked expected value,
// not just assume correctness from noise budget > 0). fresh_ciphertext()
// below is refactored to call this and discard the vector for BFV/BGV, so
// every existing caller's random draw sequence is byte-identical to before.
std::pair<Ciphertext, std::vector<uint64_t>> fresh_bfv_pair(Ctx &c, const Args &args) {
    size_t slots = c.batch_encoder->slot_count();
    std::vector<uint64_t> data(slots);
    for (auto &v : data) v = rng() % 2;  // small values, avoids overflow noise
    Plaintext pt;
    c.batch_encoder->encode(data, pt);
    Ciphertext ct;
    c.encryptor->encrypt(pt, ct);
    return {std::move(ct), std::move(data)};
}

Ciphertext fresh_ciphertext(Ctx &c, const Args &args) {
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        return fresh_bfv_pair(c, args).first;
    }
    size_t slots = c.ckks_encoder->slot_count();
    std::vector<double> data(slots);
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    for (auto &v : data) v = dist(rng);
    Plaintext pt;
    c.ckks_encoder->encode(data, c.ckks_scale, pt);
    Ciphertext ct;
    c.encryptor->encrypt(pt, ct);
    return ct;
}

// ---------- Packing scenario: partial-fill ciphertext generator ----------
// Fills the first n_real slots with real, distinguishable (sequential,
// nonzero) test values and zero-pads the rest out to slot_count -- simulates
// a caller who only has n_real real values to pack into one ciphertext, as
// opposed to fresh_ciphertext()'s "every slot real" content and Edge/Batch's
// separate "how many ciphertexts" axis. Deliberately a distinct function
// from fresh_ciphertext() (used by every other scenario in this file), so
// this addition cannot change existing scenarios' encoded content. n_real
// and slot_count are handed back to the caller (out params) for logging,
// per the packing question -- see the --fill-pct header comment.
Ciphertext fresh_ciphertext_partial_fill(Ctx &c, const Args &args, double fill_pct,
                                          std::size_t &n_real_out, std::size_t &slot_count_out) {
    Plaintext pt;
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        std::size_t slots = c.batch_encoder->slot_count();
        std::size_t n_real = std::max<std::size_t>(
            1, static_cast<std::size_t>(std::llround(fill_pct * static_cast<double>(slots))));
        std::vector<uint64_t> data(slots, 0);
        for (std::size_t i = 0; i < n_real; i++) data[i] = static_cast<uint64_t>(i + 1);
        c.batch_encoder->encode(data, pt);
        n_real_out = n_real; slot_count_out = slots;
    } else {
        std::size_t slots = c.ckks_encoder->slot_count();
        std::size_t n_real = std::max<std::size_t>(
            1, static_cast<std::size_t>(std::llround(fill_pct * static_cast<double>(slots))));
        std::vector<double> data(slots, 0.0);
        for (std::size_t i = 0; i < n_real; i++) data[i] = static_cast<double>(i + 1) * 0.1;
        c.ckks_encoder->encode(data, c.ckks_scale, pt);
        n_real_out = n_real; slot_count_out = slots;
    }
    Ciphertext ct;
    c.encryptor->encrypt(pt, ct);
    return ct;
}

// ---------- effective multiplicative depth (BFV/BGV only) ----------
// grid.depth (modulus-chain length) is CKKS's real multiply-then-rescale
// ceiling by construction, but for BFV/BGV it's only an upper bound — the
// actual ceiling is wherever the noise budget runs out. This probes that
// directly on a throwaway ciphertext: repeat (multiply by a fresh factor,
// relinearize), checking invariant_noise_budget() after each round, and
// return the last round that still left a nonzero budget. grid.depth==0
// means the chain has no relin-key infrastructure at all (build_context
// only creates relin_keys when grid.depth>0), so there's nothing to probe
// and the answer is trivially 0 without touching the decryptor.
int compute_effective_depth(Ctx &c, const Args &args, const GridRow &grid) {
    if (grid.depth == 0) return 0;

    Ciphertext ct = fresh_ciphertext(c, args);
    int last_good_depth = 0;
    for (int round = 1; ; round++) {
        Ciphertext factor = fresh_ciphertext(c, args);
        c.evaluator->multiply_inplace(ct, factor);
        c.evaluator->relinearize_inplace(ct, c.relin_keys);
        if (c.decryptor->invariant_noise_budget(ct) <= 0) break;
        last_good_depth = round;
    }
    return last_good_depth;
}

// ---------- timed operations ----------
// Each returns elapsed time in milliseconds for ONE iteration.

double time_keygen(const Args &args, const GridRow &grid) {
    // Deliberately NOT batch_size-aware: keygen happens once regardless of
    // how large a batch is processed afterwards, so this always measures
    // one full keygen. Amortizing this cost across a batch size is a
    // downstream aggregate.py computation (keygen_ms / batch_size), not
    // something this harness re-measures per batch size.
    // Full context + key generation from scratch, mirrors real-world cost.
    std::vector<int> chain_bits = parse_chain(grid.chain);
    auto t0 = Clock::now();
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        EncryptionParameters parms(args.scheme == "BFV" ? scheme_type::bfv : scheme_type::bgv);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        parms.set_plain_modulus(bfv_bgv_plain_modulus(args.N, args.category));
        SEALContext context(parms);
        KeyGenerator keygen(context);
        PublicKey pk; keygen.create_public_key(pk);
        if (grid.depth > 0) { RelinKeys rk; keygen.create_relin_keys(rk); }
    } else {
        EncryptionParameters parms(scheme_type::ckks);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        SEALContext context(parms);
        KeyGenerator keygen(context);
        PublicKey pk; keygen.create_public_key(pk);
        if (grid.depth > 0) { RelinKeys rk; keygen.create_relin_keys(rk); }
    }
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// batch_size * inner_loop items are set up (encoded/encrypted/multiplied, as
// needed) BEFORE t0, matching the isolation convention of Scenario A/B — the
// timed region below contains only the core op, repeated batch_size *
// inner_loop times, so at inner_loop=1 the timed cost (before the final /
// inner_loop) is byte-for-byte identical to before. The return value is the
// TOTAL wall time for one batch_size-item trial, AVERAGED over inner_loop
// repetitions of that trial to reduce timer/OS-jitter noise on fast ops
// (see the --inner-loop header comment); aggregate.py derives throughput/
// amortized cost from it exactly as before. inner_loop=1 (as
// run_edge_batch_docker.sh pins it) makes this identical to the old
// single-pass-per-batch behavior.

double time_encrypt(Ctx &c, const Args &args, int batch_size, int inner_loop) {
    int total = batch_size * inner_loop;
    std::vector<Plaintext> pts(total);
    for (int k = 0; k < total; k++) {
        if (args.scheme == "BFV" || args.scheme == "BGV") {
            std::vector<uint64_t> data(c.batch_encoder->slot_count(), 1);
            c.batch_encoder->encode(data, pts[k]);
        } else {
            std::vector<double> data(c.ckks_encoder->slot_count(), 0.5);
            c.ckks_encoder->encode(data, c.ckks_scale, pts[k]);
        }
    }
    Ciphertext ct;
    auto t0 = Clock::now();
    for (int k = 0; k < total; k++) c.encryptor->encrypt(pts[k], ct);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / inner_loop;
}

double time_decrypt(Ctx &c, const Args &args, int batch_size, int inner_loop) {
    int total = batch_size * inner_loop;
    std::vector<Ciphertext> cts;
    cts.reserve(total);
    for (int k = 0; k < total; k++) cts.push_back(fresh_ciphertext(c, args));
    Plaintext pt;
    auto t0 = Clock::now();
    for (int k = 0; k < total; k++) c.decryptor->decrypt(cts[k], pt);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / inner_loop;
}

double time_add(Ctx &c, const Args &args, int batch_size, int inner_loop) {
    int total = batch_size * inner_loop;
    std::vector<Ciphertext> as, bs;
    as.reserve(total); bs.reserve(total);
    for (int k = 0; k < total; k++) {
        as.push_back(fresh_ciphertext(c, args));
        bs.push_back(fresh_ciphertext(c, args));
    }
    Ciphertext result;
    auto t0 = Clock::now();
    for (int k = 0; k < total; k++) c.evaluator->add(as[k], bs[k], result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / inner_loop;
}

double time_multiply(Ctx &c, const Args &args, int batch_size, int inner_loop) {
    int total = batch_size * inner_loop;
    std::vector<Ciphertext> as, bs;
    as.reserve(total); bs.reserve(total);
    for (int k = 0; k < total; k++) {
        as.push_back(fresh_ciphertext(c, args));
        bs.push_back(fresh_ciphertext(c, args));
    }
    Ciphertext result;
    auto t0 = Clock::now();
    for (int k = 0; k < total; k++) c.evaluator->multiply(as[k], bs[k], result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / inner_loop;
}

double time_relinearize(Ctx &c, const Args &args, int batch_size, int inner_loop) {
    int total = batch_size * inner_loop;
    std::vector<Ciphertext> products;
    products.reserve(total);
    for (int k = 0; k < total; k++) {
        Ciphertext a = fresh_ciphertext(c, args);
        Ciphertext b = fresh_ciphertext(c, args);
        Ciphertext product;
        c.evaluator->multiply(a, b, product);  // untimed setup step
        products.push_back(std::move(product));
    }
    auto t0 = Clock::now();
    for (int k = 0; k < total; k++)
        c.evaluator->relinearize_inplace(products[k], c.relin_keys);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / inner_loop;
}

// ---------- Packing scenario: timed operations ----------
// Single-call-per-rep (no --batch-size/--inner-loop dimension -- Packing's
// only axis is fill_pct, kept deliberately separate and contained, see the
// --fill-pct header comment). Setup (encode/encrypt the operands) happens
// before t0, same isolation convention as every timed operation above; only
// the core op itself is inside the timed region. n_real/slot_count are
// handed back for logging -- deterministic given (scheme, slot_count,
// fill_pct), so it's safe that add/multiply below overwrite the out params
// twice (once per operand) with the same value.

double time_encrypt_partial_fill(Ctx &c, const Args &args, double fill_pct,
                                  std::size_t &n_real_out, std::size_t &slot_count_out) {
    Plaintext pt;
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        std::size_t slots = c.batch_encoder->slot_count();
        std::size_t n_real = std::max<std::size_t>(
            1, static_cast<std::size_t>(std::llround(fill_pct * static_cast<double>(slots))));
        std::vector<uint64_t> data(slots, 0);
        for (std::size_t i = 0; i < n_real; i++) data[i] = static_cast<uint64_t>(i + 1);
        c.batch_encoder->encode(data, pt);
        n_real_out = n_real; slot_count_out = slots;
    } else {
        std::size_t slots = c.ckks_encoder->slot_count();
        std::size_t n_real = std::max<std::size_t>(
            1, static_cast<std::size_t>(std::llround(fill_pct * static_cast<double>(slots))));
        std::vector<double> data(slots, 0.0);
        for (std::size_t i = 0; i < n_real; i++) data[i] = static_cast<double>(i + 1) * 0.1;
        c.ckks_encoder->encode(data, c.ckks_scale, pt);
        n_real_out = n_real; slot_count_out = slots;
    }
    Ciphertext ct;
    auto t0 = Clock::now();
    c.encryptor->encrypt(pt, ct);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_add_partial_fill(Ctx &c, const Args &args, double fill_pct,
                              std::size_t &n_real_out, std::size_t &slot_count_out) {
    Ciphertext a = fresh_ciphertext_partial_fill(c, args, fill_pct, n_real_out, slot_count_out);
    Ciphertext b = fresh_ciphertext_partial_fill(c, args, fill_pct, n_real_out, slot_count_out);
    Ciphertext result;
    auto t0 = Clock::now();
    c.evaluator->add(a, b, result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_multiply_partial_fill(Ctx &c, const Args &args, double fill_pct,
                                   std::size_t &n_real_out, std::size_t &slot_count_out) {
    Ciphertext a = fresh_ciphertext_partial_fill(c, args, fill_pct, n_real_out, slot_count_out);
    Ciphertext b = fresh_ciphertext_partial_fill(c, args, fill_pct, n_real_out, slot_count_out);
    Ciphertext result;
    auto t0 = Clock::now();
    c.evaluator->multiply(a, b, result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ---------- Composite scenario: chained workloads ----------
// See the --operation=rotate/dot_product/poly_eval header comment for the
// full design rationale (row-crossing handling, Horner's method, etc.).

// ceil(log2(n)) via repeated doubling -- avoids floating-point log2's
// rounding risk (e.g. log2(512) landing a hair above 9.0 and pushing ceil()
// to 10). Every vec_len this file sweeps is an exact power of two, so this
// always returns the exact bit position.
int ceil_log2(int n) {
    int bits = 0;
    int v = 1;
    while (v < n) { v *= 2; bits++; }
    return bits;
}

double time_rotate(Ctx &c, const Args &args) {
    // Isolated single rotate-by-1 -- same timed-region convention as every
    // other operation (setup, here one fully-packed fresh ciphertext,
    // happens before t0).
    Ciphertext ct = fresh_ciphertext(c, args);
    Ciphertext rotated;
    auto t0 = Clock::now();
    if (args.scheme == "CKKS") {
        c.evaluator->rotate_vector(ct, 1, c.galois_keys, rotated);
    } else {
        c.evaluator->rotate_rows(ct, 1, c.galois_keys, rotated);
    }
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

struct DotProductResult {
    double latency_ms;
    int noise_budget_bits;  // BFV/BGV only; -1 means "not applicable" (CKKS).
    std::string correctness;  // BFV/BGV only: real check against the
                               // independently-computed exact dot product
                               // (item 1); empty for CKKS (see header note
                               // on why this isn't extended to CKKS here).
};

DotProductResult time_dot_product(Ctx &c, const Args &args, int vec_len, std::size_t slot_count) {
    // ---- untimed setup: encode+encrypt two zero-padded vec_len-length
    // vectors ----
    Plaintext pt_a, pt_b;
    uint64_t expected_dot = 0;  // BFV/BGV only: sum_{i<vec_len} a[i]*b[i] mod t,
                                 // computed independently in plaintext -- the
                                 // real correctness check compares this against
                                 // the decoded ciphertext (item 1), replacing
                                 // "noise budget > 0 implies correct".
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        std::vector<uint64_t> a(slot_count, 0), b(slot_count, 0);
        for (int i = 0; i < vec_len; i++) { a[i] = static_cast<uint64_t>(i + 1); b[i] = static_cast<uint64_t>(i + 2); }
        c.batch_encoder->encode(a, pt_a);
        c.batch_encoder->encode(b, pt_b);
        uint64_t t = c.context->first_context_data()->parms().plain_modulus().value();
        for (int i = 0; i < vec_len; i++) expected_dot = (expected_dot + (a[i] * b[i]) % t) % t;
    } else {
        std::vector<double> a(slot_count, 0.0), b(slot_count, 0.0);
        for (int i = 0; i < vec_len; i++) { a[i] = static_cast<double>(i + 1) * 0.01; b[i] = static_cast<double>(i + 2) * 0.01; }
        c.ckks_encoder->encode(a, c.ckks_scale, pt_a);
        c.ckks_encoder->encode(b, c.ckks_scale, pt_b);
    }
    Ciphertext ca, cb;
    c.encryptor->encrypt(pt_a, ca);
    c.encryptor->encrypt(pt_b, cb);

    // BFV/BGV: row_size is HALF of slot_count (BatchEncoder's 2x(N/2)
    // matrix); CKKS: no row split, so row_size == slot_count and the
    // rotate_columns branch below is simply never reached (see header
    // comment).
    int row_size = (args.scheme == "CKKS") ? static_cast<int>(slot_count)
                                             : static_cast<int>(slot_count) / 2;
    int steps = ceil_log2(vec_len);

    // ---- timed region: multiply -> relinearize -> rotate-and-add chain ----
    auto t0 = Clock::now();
    Ciphertext sum;
    c.evaluator->multiply(ca, cb, sum);
    c.evaluator->relinearize_inplace(sum, c.relin_keys);
    for (int i = 0; i < steps; i++) {
        int shift = 1 << i;
        Ciphertext rotated;
        if (args.scheme == "CKKS") {
            c.evaluator->rotate_vector(sum, shift, c.galois_keys, rotated);
        } else if (shift < row_size) {
            c.evaluator->rotate_rows(sum, shift, c.galois_keys, rotated);
        } else {
            // shift == row_size exactly (only possible on the final step,
            // only when vec_len spans both rows) -- combine the two rows.
            c.evaluator->rotate_columns(sum, c.galois_keys, rotated);
        }
        c.evaluator->add_inplace(sum, rotated);
    }
    auto t1 = Clock::now();

    DotProductResult result;
    result.latency_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    // Noise-budget read is deliberately AFTER t1 (untimed, post-hoc
    // diagnostic -- cannot affect the latency measurement above), reusing
    // the same invariant_noise_budget() call noise_trace already uses.
    result.noise_budget_bits = (args.scheme == "CKKS")
        ? -1 : c.decryptor->invariant_noise_budget(sum);

    // Real correctness check (item 1), BFV/BGV only: only slot 0 is
    // guaranteed to hold the correct dot-product total -- verified directly
    // (N=8192/BFV, vec_len=8: slot 0 decoded to the correct 240; slots 1-7
    // decoded to 238, 232, 220, ... -- partial sums, not copies of the
    // total). An earlier version of this check compared every slot, which
    // always reported MISMATCH regardless of actual correctness (see the
    // header comment's correction) -- fixed to check slot 0 only, matching
    // what the algorithm actually guarantees, not what a stale comment
    // assumed it did.
    if (args.scheme != "CKKS") {
        Plaintext pt_dec;
        c.decryptor->decrypt(sum, pt_dec);
        std::vector<uint64_t> decoded;
        c.batch_encoder->decode(pt_dec, decoded);
        result.correctness = (decoded[0] == expected_dot) ? "correct" : "MISMATCH";
    }
    return result;
}

double time_poly_eval(Ctx &c, const Args &args) {
    const double A = 2.0, B = 3.0, C = 5.0;  // arbitrary small nonzero
                                               // constants -- see header comment.
    Ciphertext x = fresh_ciphertext(c, args);  // fully-packed, untimed setup

    Plaintext pa, pb, pc;
    if (args.scheme == "BFV" || args.scheme == "BGV") {
        std::size_t slots = c.batch_encoder->slot_count();
        c.batch_encoder->encode(std::vector<uint64_t>(slots, static_cast<uint64_t>(A)), pa);
        c.batch_encoder->encode(std::vector<uint64_t>(slots, static_cast<uint64_t>(B)), pb);
        c.batch_encoder->encode(std::vector<uint64_t>(slots, static_cast<uint64_t>(C)), pc);
    } else {
        // Horner's method scale bookkeeping (see header comment): pa
        // matches x's own scale (for the first multiply_plain), pb matches
        // the resulting scale after that (s1^2), pc matches the scale after
        // the ciphertext-ciphertext multiply by x (s1^3).
        double s1 = x.scale();
        double s2 = s1 * s1;
        double s3 = s2 * s1;
        c.ckks_encoder->encode(A, s1, pa);
        c.ckks_encoder->encode(B, s2, pb);
        c.ckks_encoder->encode(C, s3, pc);
    }

    auto t0 = Clock::now();
    Ciphertext step1, result;
    c.evaluator->multiply_plain(x, pa, step1);        // a*x
    c.evaluator->add_plain_inplace(step1, pb);         // a*x + b
    c.evaluator->multiply(step1, x, result);           // (a*x+b)*x
    c.evaluator->relinearize_inplace(result, c.relin_keys);
    c.evaluator->add_plain_inplace(result, pc);        // (a*x+b)*x + c
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ---------- serialized size measurement (--operation=size) ----------
// Not a timed operation: reuses build_context/fresh_ciphertext but never
// touches Clock::now(). One artifact row per call; relin_keys is only
// created (and only measured) when grid.depth > 0, matching build_context's
// own depth-gated relin-key creation.

struct SizeRow {
    std::string artifact;
    std::size_t size_bytes;
    std::string status;
};

template <typename SaveFn>
std::size_t serialized_size(SaveFn save_fn) {
    std::ostringstream oss(std::ios::binary);
    std::streamoff bytes = save_fn(oss);
    return static_cast<std::size_t>(bytes);
}

std::vector<SizeRow> measure_sizes(const Args &args, const GridRow &grid) {
    Ctx c = build_context(args, grid);
    std::vector<SizeRow> rows;

    Ciphertext ct = fresh_ciphertext(c, args);
    rows.push_back({"ciphertext",
        serialized_size([&](std::ostream &os) { return ct.save(os, compr_mode_type::none); }),
        "measured"});

    rows.push_back({"public_key",
        serialized_size([&](std::ostream &os) { return c.public_key.save(os, compr_mode_type::none); }),
        "measured"});

    rows.push_back({"secret_key",
        serialized_size([&](std::ostream &os) { return c.secret_key.save(os, compr_mode_type::none); }),
        "measured"});

    if (grid.depth > 0) {
        rows.push_back({"relin_keys",
            serialized_size([&](std::ostream &os) { return c.relin_keys.save(os, compr_mode_type::none); }),
            "measured"});
    } else {
        rows.push_back({"relin_keys", 0, "skipped_depth0"});
    }
    return rows;
}

// ---------- Packing scenario: fill-aware size measurement ----------
// Answers the packing question measure_sizes() above can't: does serialized
// ciphertext size actually depend on fill level, or is it fixed regardless
// (measured here, not assumed)? Only the ciphertext artifact is fill-
// dependent -- public_key/secret_key/relin_keys don't depend on plaintext
// content at all, and are already covered per-(scheme,N,category) by
// --operation=size, so this doesn't re-measure them.

struct PackingSizeRow {
    double fill_pct;
    std::size_t n_real;
    std::size_t slot_count;
    std::string artifact;
    std::size_t size_bytes;
    std::string status;
};

std::vector<PackingSizeRow> measure_packing_size(const Args &args, const GridRow &grid, double fill_pct) {
    Ctx c = build_context(args, grid);
    std::size_t n_real = 0, slot_count = 0;
    Ciphertext ct = fresh_ciphertext_partial_fill(c, args, fill_pct, n_real, slot_count);
    std::vector<PackingSizeRow> rows;
    rows.push_back({fill_pct, n_real, slot_count, "ciphertext",
        serialized_size([&](std::ostream &os) { return ct.save(os, compr_mode_type::none); }),
        "measured"});
    return rows;
}

// ---------- noise budget evolution (--operation=noise_trace) ----------
// BFV/BGV only; the CKKS skip is handled entirely in main() before this is
// ever called, so this function only ever runs for BFV. Chained by design
// (see header comment) — keys/context built once, only ciphertexts are
// freshly generated per step, matching the "fresh ciphertext every
// iteration" convention applied at the ciphertext (not key) level.

struct NoiseTraceRow {
    int trial;
    int step_index;
    std::string step_name;
    int noise_budget_bits;
    std::string correctness;  // "correct" or "MISMATCH" -- real decrypt->decode->
                               // compare-every-slot check (item 1), independent
                               // of noise_budget_bits, which stays as a separate
                               // column, not replaced.
    std::string status;
};

// Real BFV/BGV correctness check: decrypt -> decode -> compare EVERY slot
// exactly against expected (tracked independently in plaintext, mod t).
// Replaces "noise budget > 0 implies correct" as the actual pass/fail
// criterion -- noise_budget_bits alone never verifies the decoded VALUE.
std::string check_bfv_correctness(Ctx &c, const Ciphertext &ct, const std::vector<uint64_t> &expected) {
    Plaintext pt;
    c.decryptor->decrypt(ct, pt);
    std::vector<uint64_t> decoded;
    c.batch_encoder->decode(pt, decoded);
    for (size_t i = 0; i < expected.size(); i++) {
        if (decoded[i] != expected[i]) return "MISMATCH";
    }
    return "correct";
}

// effective_depth (out param): the BFV/BGV noise-budget ceiling measured by
// compute_effective_depth(), NOT grid.depth (chain length) — see the "grid
// depth vs. effective depth" note at the top of this file. Computed once
// per call (not per trial: keys/chain are fixed for the whole file, so the
// ceiling doesn't vary trial-to-trial) and reported back so main() can log
// it alongside grid.depth in the CSV.
std::vector<NoiseTraceRow> run_noise_trace(const Args &args, const GridRow &grid, int &effective_depth) {
    Ctx c = build_context(args, grid);
    effective_depth = compute_effective_depth(c, args, grid);
    std::vector<NoiseTraceRow> rows;
    uint64_t t = c.context->first_context_data()->parms().plain_modulus().value();

    for (int trial = 0; trial < args.trace_reps; trial++) {
        int step_index = 0;

        auto fresh = fresh_bfv_pair(c, args);
        Ciphertext ct = std::move(fresh.first);
        std::vector<uint64_t> expected = std::move(fresh.second);
        rows.push_back({trial, step_index++, "fresh",
                         c.decryptor->invariant_noise_budget(ct),
                         check_bfv_correctness(c, ct, expected), "measured"});

        auto addend = fresh_bfv_pair(c, args);
        c.evaluator->add_inplace(ct, addend.first);
        for (size_t i = 0; i < expected.size(); i++) expected[i] = (expected[i] + addend.second[i]) % t;
        rows.push_back({trial, step_index++, "after_add",
                         c.decryptor->invariant_noise_budget(ct),
                         check_bfv_correctness(c, ct, expected), "measured"});

        for (int m = 1; m <= effective_depth; m++) {
            auto factor = fresh_bfv_pair(c, args);
            c.evaluator->multiply_inplace(ct, factor.first);
            for (size_t i = 0; i < expected.size(); i++) expected[i] = (expected[i] * factor.second[i]) % t;
            rows.push_back({trial, step_index++, "after_multiply_" + std::to_string(m),
                             c.decryptor->invariant_noise_budget(ct),
                             check_bfv_correctness(c, ct, expected), "measured"});

            c.evaluator->relinearize_inplace(ct, c.relin_keys);
            rows.push_back({trial, step_index++, "after_relinearize_" + std::to_string(m),
                             c.decryptor->invariant_noise_budget(ct),
                             check_bfv_correctness(c, ct, expected), "measured"});
        }
    }
    return rows;
}

// ---------- Composite scenario: isolated rotate-only / add-only noise
// controls (extra-rigor item 3) ----------
// dot_product's combined chain interleaves k = ceil_log2(vec_len)
// rotate-and-add steps; its noise-budget decline alone can't say whether
// the rotations or the adds are responsible. These two traces run ONLY
// rotations or ONLY adds, same k as the combined chain at the same
// vec_len, starting from the same kind of fresh-ciphertext baseline
// noise_trace uses, so the report can attribute the decline to whichever
// operation actually causes it. BFV/BGV only (CKKS has no noise-budget
// equivalent -- same limitation as noise_trace/dot_product). Real
// correctness (item 1) is checked at every step, not just budget: rotation
// permutes values (tracked exactly, direction confirmed empirically
// against SEAL 4.1.2 -- new[i] = old[(i+shift) % row_size] for the
// in-row case, row swap for the cross-row case, matching
// time_dot_product's own row_size/row-crossing logic exactly); add sums
// mod t, same as noise_trace's after_add step.

std::vector<NoiseTraceRow> run_rotate_only_trace(const Args &args, const GridRow &grid, int vec_len) {
    Ctx c = build_context(args, grid);
    int row_size = static_cast<int>(c.batch_encoder->slot_count()) / 2;
    int k = ceil_log2(vec_len);

    std::vector<int> galois_steps;
    for (int i = 0; i < k; i++) {
        int shift = 1 << i;
        galois_steps.push_back(shift < row_size ? shift : 0);  // 0 = column-swap element
    }
    KeyGenerator galois_keygen(*c.context, c.secret_key);
    galois_keygen.create_galois_keys(galois_steps, c.galois_keys);

    std::vector<NoiseTraceRow> rows;
    for (int trial = 0; trial < args.trace_reps; trial++) {
        int step_index = 0;
        auto fresh = fresh_bfv_pair(c, args);
        Ciphertext ct = std::move(fresh.first);
        std::vector<uint64_t> expected = std::move(fresh.second);
        rows.push_back({trial, step_index++, "fresh", c.decryptor->invariant_noise_budget(ct),
                         check_bfv_correctness(c, ct, expected), "measured"});

        for (int i = 0; i < k; i++) {
            int shift = 1 << i;
            Ciphertext rotated;
            std::vector<uint64_t> new_expected(expected.size());
            if (shift < row_size) {
                c.evaluator->rotate_rows(ct, shift, c.galois_keys, rotated);
                for (int half = 0; half < 2; half++) {
                    int base = half * row_size;
                    for (int j = 0; j < row_size; j++)
                        new_expected[base + j] = expected[base + (j + shift) % row_size];
                }
            } else {
                c.evaluator->rotate_columns(ct, c.galois_keys, rotated);
                for (int j = 0; j < row_size; j++) {
                    new_expected[j] = expected[row_size + j];
                    new_expected[row_size + j] = expected[j];
                }
            }
            ct = rotated;
            expected = std::move(new_expected);
            rows.push_back({trial, step_index++, "after_rotate_" + std::to_string(i + 1),
                             c.decryptor->invariant_noise_budget(ct),
                             check_bfv_correctness(c, ct, expected), "measured"});
        }
    }
    return rows;
}

std::vector<NoiseTraceRow> run_add_only_trace(const Args &args, const GridRow &grid, int vec_len) {
    Ctx c = build_context(args, grid);
    int k = ceil_log2(vec_len);
    uint64_t t = c.context->first_context_data()->parms().plain_modulus().value();

    std::vector<NoiseTraceRow> rows;
    for (int trial = 0; trial < args.trace_reps; trial++) {
        int step_index = 0;
        auto fresh = fresh_bfv_pair(c, args);
        Ciphertext ct = std::move(fresh.first);
        std::vector<uint64_t> expected = std::move(fresh.second);
        rows.push_back({trial, step_index++, "fresh", c.decryptor->invariant_noise_budget(ct),
                         check_bfv_correctness(c, ct, expected), "measured"});

        for (int i = 0; i < k; i++) {
            auto addend = fresh_bfv_pair(c, args);
            c.evaluator->add_inplace(ct, addend.first);
            for (size_t j = 0; j < expected.size(); j++) expected[j] = (expected[j] + addend.second[j]) % t;
            rows.push_back({trial, step_index++, "after_add_" + std::to_string(i + 1),
                             c.decryptor->invariant_noise_budget(ct),
                             check_bfv_correctness(c, ct, expected), "measured"});
        }
    }
    return rows;
}

// ---------- CKKS error accumulation (--operation=ckks_error) ----------
// CKKS only; the BFV/BGV skip is handled entirely in main() before this is
// ever called. Unlike run_noise_trace, this needs the actual plaintext
// values (not just a ciphertext) to diff against, so it uses its own
// fresh-vector helper rather than the shared fresh_ciphertext(), and
// deliberately rescales after every multiply (see header comment for why
// that diverges from every timed CKKS operation elsewhere in this file).

// CKKS correctness threshold (item 1): input values are uniform in
// [-1, 1] (fresh_ckks_pair), so max_abs_error is directly interpretable as
// a fraction of the input's own range -- 1e-2 means "off by at most 1% of
// the value range", i.e. at least ~6.6 bits of precision retained
// (-log2(1e-2) =~ 6.64). This is a deliberately LOOSE bound, chosen so it
// accepts every cell this project's own scale-tuning work (Chapter 3,
// security-level validation) found to be genuinely usable -- including the
// smallest-budget "good" cells at ~1e-4, two to three orders of magnitude
// under this bound -- while still failing the cells already documented as
// broken (the old N=2048/category=1 zero-budget cell measured ~9.3 error)
// and the one cell documented as a structural limitation, not a clean fix
// (N=2048/category=3's best-achievable ~0.08 max error, Table~tab:
// configmeta-ckks) -- that cell is EXPECTED to fail this check, and should:
// the point of a real threshold is to stop calling it "correct" just
// because it doesn't throw. 1e-2 sits comfortably between "every cell this
// project actually uses" (<=3e-4) and "every cell already known to be
// broken or marginal" (>=0.08), so it isn't a knife-edge choice riding on
// one specific measurement.
constexpr double CKKS_CORRECTNESS_THRESHOLD = 1e-2;

struct CkksTraceRow {
    int trial;
    int step_index;
    std::string step_name;
    double max_abs_error;
    double mean_abs_error;
    std::string correctness;  // "correct" or "MISMATCH" -- max_abs_error <
                               // CKKS_CORRECTNESS_THRESHOLD, a real pass/fail
                               // verdict (item 1), alongside the existing raw
                               // error numbers, not replacing them.
    std::string status;
};

// Encodes+encrypts a fresh random vector at the given (parms_id, scale) —
// callers pass the current ciphertext's own parms_id()/scale() so the
// result lands at the exact level/scale needed to add/multiply against it.
std::pair<Ciphertext, std::vector<double>> fresh_ckks_pair(
    Ctx &c, seal::parms_id_type parms_id, double scale) {
    size_t slots = c.ckks_encoder->slot_count();
    std::vector<double> data(slots);
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    for (auto &v : data) v = dist(rng);
    Plaintext pt;
    c.ckks_encoder->encode(data, parms_id, scale, pt);
    Ciphertext ct;
    c.encryptor->encrypt(pt, ct);
    return {std::move(ct), std::move(data)};
}

void record_ckks_error(
    Ctx &c, const Ciphertext &ct, const std::vector<double> &expected, int trial, int &step_index,
    const std::string &step_name, std::vector<CkksTraceRow> &rows) {
    Plaintext pt;
    c.decryptor->decrypt(ct, pt);
    std::vector<double> decoded;
    c.ckks_encoder->decode(pt, decoded);
    double max_err = 0.0, sum_err = 0.0;
    for (size_t i = 0; i < expected.size(); i++) {
        double err = std::fabs(decoded[i] - expected[i]);
        max_err = std::max(max_err, err);
        sum_err += err;
    }
    std::string correctness = (max_err < CKKS_CORRECTNESS_THRESHOLD) ? "correct" : "MISMATCH";
    rows.push_back(
        {trial, step_index++, step_name, max_err, sum_err / static_cast<double>(expected.size()),
         correctness, "measured"});
}

std::vector<CkksTraceRow> run_ckks_error_trace(const Args &args, const GridRow &grid) {
    Ctx c = build_context(args, grid);
    std::vector<CkksTraceRow> rows;

    for (int trial = 0; trial < args.trace_reps; trial++) {
        int step_index = 0;

        auto fresh = fresh_ckks_pair(c, c.context->first_parms_id(), c.ckks_scale);
        Ciphertext ct = std::move(fresh.first);
        std::vector<double> expected = std::move(fresh.second);
        record_ckks_error(c, ct, expected, trial, step_index, "fresh", rows);

        auto addend = fresh_ckks_pair(c, ct.parms_id(), ct.scale());
        c.evaluator->add_inplace(ct, addend.first);
        for (size_t i = 0; i < expected.size(); i++) expected[i] += addend.second[i];
        record_ckks_error(c, ct, expected, trial, step_index, "after_add", rows);

        for (int m = 1; m <= grid.depth; m++) {
            auto factor = fresh_ckks_pair(c, ct.parms_id(), ct.scale());
            c.evaluator->multiply_inplace(ct, factor.first);
            for (size_t i = 0; i < expected.size(); i++) expected[i] *= factor.second[i];
            record_ckks_error(c, ct, expected, trial, step_index, "after_multiply_" + std::to_string(m), rows);

            c.evaluator->relinearize_inplace(ct, c.relin_keys);
            record_ckks_error(c, ct, expected, trial, step_index, "after_relinearize_" + std::to_string(m), rows);

            c.evaluator->rescale_to_next_inplace(ct);
            record_ckks_error(c, ct, expected, trial, step_index, "after_rescale_" + std::to_string(m), rows);
        }
    }
    return rows;
}

// ---------- config metadata (--operation=config_metadata) ----------
// Not a timed operation, same shape as size/noise_trace/ckks_error: own CSV
// schema, own function, returns before the timing loop, header written
// before the (possibly-throwing) build_context call so a build failure
// (e.g. N=2048/cat5) still leaves a header-only file behind. One row per
// (scheme, N, category) -- the parameter facts needed to interpret every
// other metric, previously only partially captured (N/chain/depth) or not
// written anywhere at all.

struct ConfigMetadataRow {
    int poly_modulus_degree;
    std::string coeff_modulus_chain;    // grid.chain, e.g. "60+40*7+60"
    std::string secret_distribution;
    std::string error_distribution;
    bool batching_enabled;
    std::size_t slots_used;
    std::string plain_modulus;          // BFV/BGV only, empty for CKKS
    std::string initial_scale;          // CKKS only, empty for BFV/BGV
    std::string rescaling_policy;       // CKKS only, empty for BFV/BGV
    std::string precision_criterion;    // CKKS only, empty for BFV/BGV
};

ConfigMetadataRow measure_config_metadata(const Args &args, const GridRow &grid) {
    Ctx c = build_context(args, grid);
    ConfigMetadataRow row;
    row.poly_modulus_degree = args.N;
    row.coeff_modulus_chain = grid.chain;

    // SEAL 4.1.2 samples the secret key from a uniform ternary {-1,0,1}
    // distribution (confirmed against util/hestdparms.h's header comment)
    // and the error from a distribution with standard deviation 3.2
    // (seal_he_std_parms_error_std_dev, same file) -- fixed library
    // constants, not something this harness configures, so logged as
    // confirmed facts (matching the values already reported elsewhere in
    // this project) rather than re-derived or assumed differently.
    row.secret_distribution = "uniform_ternary";
    row.error_distribution = "centered_binomial_sigma_3.2";

    if (args.scheme == "BFV" || args.scheme == "BGV") {
        row.batching_enabled = true;
        row.slots_used = c.batch_encoder->slot_count();
        row.plain_modulus = std::to_string(
            c.context->first_context_data()->parms().plain_modulus().value());
    } else {  // CKKS
        // CKKS's N/2-slot SIMD packing is inherent to the scheme (no
        // explicit "enable batching" step the way BFV/BGV's
        // PlainModulus::Batching is) -- logged true because slots ARE used
        // exactly like BFV/BGV's batch encoder, just via a different
        // mechanism (CKKSEncoder, not BatchEncoder).
        row.batching_enabled = true;
        row.slots_used = c.ckks_encoder->slot_count();
        row.initial_scale = std::to_string(c.ckks_scale);
        // The six timed CKKS operations (encrypt/decrypt/add/multiply/
        // relinearize) deliberately never rescale, to isolate each
        // operation's raw per-op cost -- see build_context's own comment.
        // Only --operation=ckks_error's error-accumulation trace rescales,
        // and only there, after every multiply (see run_ckks_error_trace's
        // header comment) -- this column describes THAT trace's policy, not
        // the timed operations', which is why it's spelled out explicitly
        // rather than stated as a blanket "CKKS rescales manually" fact.
        row.rescaling_policy =
            "manual, after every multiply -- applies to the ckks_error trace ONLY; "
            "the six timed CKKS operations never rescale, to isolate raw per-op cost";
        // No fixed pass/fail precision threshold is defined anywhere in this
        // project (checked docs/ and aggregate.py) -- ckks_error reports raw
        // max_abs_error/mean_abs_error per step instead of a threshold verdict.
        row.precision_criterion =
            "none fixed; raw max_abs_error/mean_abs_error reported per step "
            "(see --operation=ckks_error)";
    }
    return row;
}

// ---------- main ----------

int main(int argc, char **argv) {
    try {
        Args args = parse_args(argc, argv);
        GridRow grid = load_grid_row(args.grid_path, args.N, args.category);

        // ---- Packing scenario (--fill-pct=...): completely separate code
        // path and CSV schemas, checked FIRST so it intercepts operation=
        // "size" here rather than falling into the generic --operation=size
        // branch below (which knows nothing about fill_pct). See the
        // --fill-pct header comment for the full design rationale.
        if (args.fill_pct_set) {
            if (args.operation == "size") {
                std::ofstream pk_out(args.out);
                if (!pk_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
                pk_out << "library,scheme,N,category,fill_pct,n_real,slot_count,artifact,size_bytes,status\n";
                std::vector<PackingSizeRow> rows = measure_packing_size(args, grid, args.fill_pct);
                for (const auto &row : rows) {
                    pk_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                           << row.fill_pct << "," << row.n_real << "," << row.slot_count << ","
                           << row.artifact << "," << row.size_bytes << "," << row.status << "\n";
                }
                pk_out.close();
                std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
                return 0;
            }

            if (args.operation != "encrypt" && args.operation != "add" && args.operation != "multiply") {
                throw std::runtime_error("Packing scenario (--fill-pct) only supports "
                    "--operation=encrypt|add|multiply|size (keygen/decrypt/relinearize "
                    "aren't central to the packing question -- see run_packing_docker.sh), got: "
                    + args.operation);
            }

            // multiply needs the same depth==0 undefined-operation guard as
            // the generic path below -- reused here, not assumed away, in
            // case Packing is later swept over configs where depth==0 (see
            // the "grid depth vs. effective depth" note at the top of this
            // file). Not exercised by run_packing_docker.sh's own scope
            // (N=8192/category=1 has depth=2), but kept for correctness.
            bool needs_depth = (args.operation == "multiply");
            int depth_for_skip = grid.depth;
            Ctx c;
            bool have_ctx = false;
            if (needs_depth && args.scheme != "CKKS") {
                if (grid.depth > 0) {
                    c = build_context(args, grid);
                    have_ctx = true;
                    depth_for_skip = compute_effective_depth(c, args, grid);
                } else {
                    depth_for_skip = 0;
                }
            }

            std::ofstream out(args.out);
            if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            out << "library,scheme,N,category,operation,fill_pct,n_real,slot_count,iteration,latency_ms,status\n";

            if (needs_depth && depth_for_skip == 0) {
                std::cerr << "SKIPPED: N=" << args.N << " category=" << args.category
                          << " has grid_depth=" << grid.depth << " effective_depth=" << depth_for_skip
                          << " — " << args.operation
                          << " is not defined at this configuration (see Chapter 3, Sec 3.4)."
                          << std::endl;
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << args.fill_pct << ",,,,,\"skipped_depth0\"\n";
                out.close();
                return 0;
            }

            if (!have_ctx) { c = build_context(args, grid); have_ctx = true; }

            int total = args.warmup + args.reps;
            for (int i = 0; i < total; i++) {
                std::size_t n_real = 0, slot_count = 0;
                double ms;
                if      (args.operation == "encrypt") ms = time_encrypt_partial_fill(c, args, args.fill_pct, n_real, slot_count);
                else if (args.operation == "add")     ms = time_add_partial_fill(c, args, args.fill_pct, n_real, slot_count);
                else                                   ms = time_multiply_partial_fill(c, args, args.fill_pct, n_real, slot_count);

                std::string status = (i < args.warmup) ? "warmup" : "measured";
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << args.fill_pct << "," << n_real << "," << slot_count << ","
                    << i << "," << ms << "," << status << "\n";
            }
            out.close();
            std::cerr << "OK: wrote " << total << " rows to " << args.out << std::endl;
            return 0;
        }

        if (args.operation == "size") {
            std::ofstream size_out(args.out);
            if (!size_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            size_out << "library,scheme,N,category,artifact,size_bytes,status\n";
            // Header written before measure_sizes() runs (not after), so a
            // build_context failure (e.g. N=2048/cat5's known prime-search
            // limitation) still leaves a header-only file behind, matching
            // noise_trace/ckks_error and the six original operations —
            // "attempted and failed" stays distinguishable from "never run".
            std::vector<SizeRow> rows = measure_sizes(args, grid);
            for (const auto &row : rows) {
                size_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                          << row.artifact << "," << row.size_bytes << "," << row.status << "\n";
            }
            size_out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
            return 0;
        }

        if (args.operation == "noise_trace") {
            std::ofstream nt_out(args.out);
            if (!nt_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            // grid_depth: modulus-chain length from param_grid.csv. effective_depth:
            // BFV/BGV's actual noise-budget ceiling, measured by
            // compute_effective_depth() -- deliberately a separate column, not a
            // replacement, so the two definitions are never silently conflated
            // (see the "grid depth vs. effective depth" note at the top of this file).
            nt_out << "library,scheme,N,category,grid_depth,effective_depth,trial,step_index,"
                      "step_name,noise_budget_bits,correctness,status\n";

            if (args.scheme == "CKKS") {
                std::cerr << "SKIPPED: noise_trace is BFV/BGV-only (SEAL's invariant_noise_budget "
                             "throws for CKKS); N=" << args.N << " category=" << args.category
                          << " scheme=CKKS." << std::endl;
                nt_out << "SEAL,CKKS," << args.N << "," << args.category << "," << grid.depth
                       << ",,,,,,,\"skipped_not_applicable_ckks\"\n";
                nt_out.close();
                return 0;
            }

            int effective_depth = 0;
            std::vector<NoiseTraceRow> rows = run_noise_trace(args, grid, effective_depth);
            for (const auto &row : rows) {
                nt_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << "," << effective_depth << "," << row.trial << ","
                       << row.step_index << "," << row.step_name << "," << row.noise_budget_bits
                       << "," << row.correctness << "," << row.status << "\n";
            }
            nt_out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out
                      << " (grid_depth=" << grid.depth << ", effective_depth=" << effective_depth
                      << ")" << std::endl;
            return 0;
        }

        if (args.operation == "ckks_error") {
            std::ofstream ck_out(args.out);
            if (!ck_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            ck_out << "library,scheme,N,category,grid_depth,trial,step_index,step_name,"
                      "max_abs_error,mean_abs_error,correctness,status\n";

            if (args.scheme != "CKKS") {
                std::cerr << "SKIPPED: ckks_error is CKKS-only (BFV/BGV are exact schemes, no "
                             "rounding error by construction); N=" << args.N << " category="
                          << args.category << " scheme=" << args.scheme << "." << std::endl;
                ck_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << ",,,,,,,\"skipped_not_applicable_bfv\"\n";
                ck_out.close();
                return 0;
            }

            std::vector<CkksTraceRow> rows = run_ckks_error_trace(args, grid);
            for (const auto &row : rows) {
                ck_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << "," << row.trial << "," << row.step_index << ","
                       << row.step_name << "," << row.max_abs_error << "," << row.mean_abs_error
                       << "," << row.correctness << "," << row.status << "\n";
            }
            ck_out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
            return 0;
        }

        if (args.operation == "config_metadata") {
            std::ofstream cm_out(args.out);
            if (!cm_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            cm_out << "library,scheme,N,category,poly_modulus_degree,coeff_modulus_chain,"
                      "secret_distribution,error_distribution,batching_enabled,slots_used,"
                      "plain_modulus,initial_scale,rescaling_policy,precision_criterion,status\n";
            ConfigMetadataRow row = measure_config_metadata(args, grid);
            cm_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                   << row.poly_modulus_degree << ",\"" << row.coeff_modulus_chain << "\","
                   << row.secret_distribution << "," << row.error_distribution << ","
                   << (row.batching_enabled ? "true" : "false") << "," << row.slots_used << ","
                   << row.plain_modulus << "," << row.initial_scale << ",\""
                   << row.rescaling_policy << "\",\"" << row.precision_criterion << "\",measured\n";
            cm_out.close();
            std::cerr << "OK: wrote 1 row to " << args.out << std::endl;
            return 0;
        }

        // ---- Composite scenario: rotate / dot_product / poly_eval -- see
        // the --operation=rotate/dot_product/poly_eval header comment.
        // Checked here (after config_metadata, before the generic 6-
        // operation path below) since these are their own self-contained
        // CSV schemas, same shape as size/noise_trace/ckks_error/
        // config_metadata above, not part of the generic --batch-size/
        // --inner-loop-aware timing loop.
        if (args.operation == "rotate") {
            Ctx c = build_context(args, grid);  // no galois keys yet -- generated
                                                 // separately below so its own
                                                 // cost can be timed in isolation.

            // Minimal Galois keys (item 4): time_rotate() below only ever
            // rotates by step=1, so that's the only element requested --
            // NOT the library's no-argument default (create_galois_keys()
            // with no args generates the full power-of-two step set for
            // every possible rotation amount up to N/2, a much larger and
            // more expensive key than this operation actually uses).
            KeyGenerator galois_keygen(*c.context, c.secret_key);
            auto gk_t0 = Clock::now();
            galois_keygen.create_galois_keys(std::vector<int>{1}, c.galois_keys);
            auto gk_t1 = Clock::now();
            double galois_keygen_ms = std::chrono::duration<double, std::milli>(gk_t1 - gk_t0).count();
            std::size_t galois_keys_size_bytes = serialized_size(
                [&](std::ostream &os) { return c.galois_keys.save(os, compr_mode_type::none); });

            std::ofstream out(args.out);
            if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            out << "library,scheme,N,category,operation,galois_keygen_ms,galois_keys_size_bytes,"
                   "iteration,latency_ms,status\n";

            int total = args.warmup + args.reps;
            for (int i = 0; i < total; i++) {
                double ms = time_rotate(c, args);
                std::string status = (i < args.warmup) ? "warmup" : "measured";
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << galois_keygen_ms << "," << galois_keys_size_bytes
                    << "," << i << "," << ms << "," << status << "\n";
            }
            out.close();
            std::cerr << "OK: wrote " << total << " rows to " << args.out
                      << " (galois_keygen_ms=" << galois_keygen_ms
                      << ", galois_keys_size_bytes=" << galois_keys_size_bytes << ")" << std::endl;
            return 0;
        }

        if (args.operation == "dot_product") {
            if (args.vec_len <= 0) {
                throw std::runtime_error("--operation=dot_product requires --vec-len=N (a literal "
                                          "count, >= 1, NOT a percentage)");
            }
            Ctx c = build_context(args, grid);  // no galois keys yet -- generated
                                                 // separately below, minimal to
                                                 // this vec_len (item 4).

            std::size_t slot_count = (args.scheme == "BFV" || args.scheme == "BGV")
                ? c.batch_encoder->slot_count() : c.ckks_encoder->slot_count();
            if (static_cast<std::size_t>(args.vec_len) > slot_count) {
                throw std::runtime_error("--vec-len (" + std::to_string(args.vec_len) +
                    ") exceeds slot_count (" + std::to_string(slot_count) + ") for this config");
            }

            // Minimal Galois keys (item 4): time_dot_product()'s doubling
            // reduction only ever rotates by 1,2,4,...,2^(steps-1) -- request
            // exactly those elements, not the library's no-argument default
            // (the full power-of-two step set for every rotation amount up
            // to N/2). BFV/BGV's final step can cross the two-row boundary
            // (see time_dot_product's header comment); that uses the
            // conjugation/column-swap element, requested via step=0 --
            // confirmed against SEAL 4.1.2's own source
            // (Evaluator::conjugate_internal calls
            // galois_tool->get_elt_from_step(0), which rotate_columns_inplace
            // uses internally), not guessed.
            {
                int row_size = (args.scheme == "CKKS") ? static_cast<int>(slot_count)
                                                         : static_cast<int>(slot_count) / 2;
                int steps = ceil_log2(args.vec_len);
                std::vector<int> galois_steps;
                for (int i = 0; i < steps; i++) {
                    int shift = 1 << i;
                    if (args.scheme == "CKKS" || shift < row_size) galois_steps.push_back(shift);
                    else galois_steps.push_back(0);  // column-swap / conjugation element
                }
                KeyGenerator galois_keygen(*c.context, c.secret_key);
                galois_keygen.create_galois_keys(galois_steps, c.galois_keys);
            }

            std::ofstream out(args.out);
            if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            out << "library,scheme,N,category,operation,vec_len,slot_count,iteration,latency_ms,"
                   "noise_budget_bits,correctness,status\n";

            int total = args.warmup + args.reps;
            for (int i = 0; i < total; i++) {
                DotProductResult r = time_dot_product(c, args, args.vec_len, slot_count);
                std::string status = (i < args.warmup) ? "warmup" : "measured";
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << args.vec_len << "," << slot_count << ","
                    << i << "," << r.latency_ms << ",";
                if (r.noise_budget_bits >= 0) out << r.noise_budget_bits;  // empty for CKKS
                out << "," << r.correctness << "," << status << "\n";  // correctness empty for CKKS too
            }
            out.close();
            std::cerr << "OK: wrote " << total << " rows to " << args.out << std::endl;
            return 0;
        }

        // ---- Isolated rotate-only / add-only noise controls (item 3) ----
        // Same --vec-len convention as dot_product (k = ceil_log2(vec_len)),
        // so a given vec_len's isolated traces are directly comparable to
        // that SAME vec_len's combined dot_product trace. BFV/BGV only.
        if (args.operation == "rotate_only" || args.operation == "add_only") {
            if (args.vec_len <= 0) {
                throw std::runtime_error("--operation=" + args.operation +
                                          " requires --vec-len=N (determines k=ceil_log2(vec_len), "
                                          "matching dot_product's own chain length)");
            }
            std::ofstream out(args.out);
            if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            out << "library,scheme,N,category,operation,vec_len,k,trial,step_index,step_name,"
                   "noise_budget_bits,correctness,status\n";

            if (args.scheme == "CKKS") {
                std::cerr << "SKIPPED: " << args.operation << " is BFV/BGV-only (no noise-budget "
                             "equivalent for CKKS); N=" << args.N << " category=" << args.category
                          << " scheme=CKKS." << std::endl;
                out << "SEAL,CKKS," << args.N << "," << args.category << "," << args.operation << ","
                    << args.vec_len << ",,,,,,,\"skipped_not_applicable_ckks\"\n";
                out.close();
                return 0;
            }

            int k = ceil_log2(args.vec_len);
            std::vector<NoiseTraceRow> rows = (args.operation == "rotate_only")
                ? run_rotate_only_trace(args, grid, args.vec_len)
                : run_add_only_trace(args, grid, args.vec_len);
            for (const auto &row : rows) {
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << args.vec_len << "," << k << "," << row.trial << ","
                    << row.step_index << "," << row.step_name << "," << row.noise_budget_bits << ","
                    << row.correctness << "," << row.status << "\n";
            }
            out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
            return 0;
        }

        if (args.operation == "poly_eval") {
            Ctx c = build_context(args, grid);  // no galois keys needed -- purely elementwise

            std::ofstream out(args.out);
            if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            out << "library,scheme,N,category,operation,iteration,latency_ms,status\n";

            int total = args.warmup + args.reps;
            for (int i = 0; i < total; i++) {
                double ms = time_poly_eval(c, args);
                std::string status = (i < args.warmup) ? "warmup" : "measured";
                out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                    << args.operation << "," << i << "," << ms << "," << status << "\n";
            }
            out.close();
            std::cerr << "OK: wrote " << total << " rows to " << args.out << std::endl;
            return 0;
        }

        // needs_depth: multiply/relinearize are undefined when there's no room
        // for even one multiplicative level. depth_for_skip: grid.depth for
        // CKKS (chain length IS the ceiling there, unchanged); for BFV/BGV,
        // compute_effective_depth()'s measured noise-budget ceiling instead
        // (see the "grid depth vs. effective depth" note at the top of this
        // file) -- computed here, once, using a context we then reuse below
        // instead of building a second one for the timing loop.
        bool needs_depth = (args.operation == "multiply" || args.operation == "relinearize");
        int depth_for_skip = grid.depth;
        Ctx c;
        bool have_ctx = false;

        if (needs_depth && args.scheme != "CKKS") {
            if (grid.depth > 0) {
                c = build_context(args, grid);
                have_ctx = true;
                depth_for_skip = compute_effective_depth(c, args, grid);
            } else {
                depth_for_skip = 0;  // no relin-key infrastructure to probe
            }
        }

        if (needs_depth && depth_for_skip == 0) {
            std::cerr << "SKIPPED: N=" << args.N << " category=" << args.category
                      << " has grid_depth=" << grid.depth << " effective_depth=" << depth_for_skip
                      << " — " << args.operation
                      << " is not defined at this configuration (see Chapter 3, Sec 3.4)."
                      << std::endl;
            // Write an empty file with header so downstream aggregation
            // can tell "skipped" apart from "not yet run".
            std::ofstream out(args.out);
            out << "library,scheme,N,category,operation,batch_size,iteration,latency_ms,status\n";
            out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                << args.operation << "," << args.batch_size << ",,,\"skipped_depth0\"\n";
            return 0;
        }

        std::ofstream out(args.out);
        if (!out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
        out << "library,scheme,N,category,operation,batch_size,iteration,latency_ms,status\n";

        int total = args.warmup + args.reps;
        for (int i = 0; i < total; i++) {
            double ms;
            if (args.operation == "keygen")            ms = time_keygen(args, grid);
            else {
                // context/keys built once, reused across all reps (rebuilt
                // fresh only for keygen itself, above). If the depth probe
                // above already built one (BFV/BGV multiply/relinearize),
                // reuse it instead of building a second one.
                if (!have_ctx) { c = build_context(args, grid); have_ctx = true; }

                if      (args.operation == "encrypt")      ms = time_encrypt(c, args, args.batch_size, args.inner_loop);
                else if (args.operation == "decrypt")      ms = time_decrypt(c, args, args.batch_size, args.inner_loop);
                else if (args.operation == "add")          ms = time_add(c, args, args.batch_size, args.inner_loop);
                else if (args.operation == "multiply")     ms = time_multiply(c, args, args.batch_size, args.inner_loop);
                else if (args.operation == "relinearize")  ms = time_relinearize(c, args, args.batch_size, args.inner_loop);
                else throw std::runtime_error("Unknown operation: " + args.operation);
            }

            std::string status = (i < args.warmup) ? "warmup" : "measured";
            out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                << args.operation << "," << args.batch_size << "," << i << "," << ms << ","
                << status << "\n";
        }
        out.close();
        std::cerr << "OK: wrote " << total << " rows to " << args.out << std::endl;
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        return 1;
    }
}
