// bench_seal.cpp
//
// Benchmark harness for Microsoft SEAL (BFV and CKKS), implementing the
// protocol defined in Chapter 3 (Methodology) of the thesis:
//   - parameter grid from ../../config/param_grid.csv (N x NIST category)
//   - fresh ciphertexts generated each iteration (matches HEProfiler's own
//     convention, chosen deliberately after the 4x cache-effect discrepancy
//     found during the earlier HEProfiler reproduction phase)
//   - one CLI invocation = one (scheme, N, category, operation) cell
//   - writes ONE ROW PER ITERATION (no aggregation here — aggregate.py does
//     mean/std/95% CI and warm-up discarding, so statistics live in exactly
//     one place)
//
// Usage:
//   ./bench_seal --scheme=BFV --N=8192 --category=1 --operation=multiply \
//                --reps=100 --warmup=5 --out=results/raw/seal_bfv_8192_c1_multiply.csv
//
// Operations: keygen, encrypt, decrypt, add, multiply, relinearize, size,
// noise_trace, ckks_error
// Multiply-family operations (multiply, relinearize) are skipped with a
// clear message when the param grid's depth==0 for that (N, category) —
// see param_grid.csv and Chapter 3 Section 3.4 for why.
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
// only the documented-depth chain: fresh -> 1x add -> grid.depth x
// (multiply -> relinearize), stopping at what the grid already claims,
// deliberately not probing past it — this validates whether the
// security-standard parameter tables the grid is built from hold up in
// practice. Runs --trace-reps trials (default 10, independent of
// --reps/--warmup, since this is a near-deterministic bit count, not a
// noisy wall-clock measurement needing 100 statistical repetitions).
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
    std::string scheme;      // "BFV" or "CKKS"
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
    std::unique_ptr<Encryptor> encryptor;
    std::unique_ptr<Evaluator> evaluator;
    std::unique_ptr<Decryptor> decryptor;
    std::unique_ptr<BatchEncoder> batch_encoder;   // BFV only
    std::unique_ptr<CKKSEncoder> ckks_encoder;     // CKKS only
    double ckks_scale = 0.0;
};

Ctx build_context(const Args &args, const GridRow &grid) {
    Ctx c;
    std::vector<int> chain_bits = parse_chain(grid.chain);

    if (args.scheme == "BFV") {
        EncryptionParameters parms(scheme_type::bfv);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        parms.set_plain_modulus(PlainModulus::Batching(args.N, 20));
        c.context = std::make_shared<SEALContext>(parms);
        c.batch_encoder = std::make_unique<BatchEncoder>(*c.context);
    } else if (args.scheme == "CKKS") {
        EncryptionParameters parms(scheme_type::ckks);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        c.context = std::make_shared<SEALContext>(parms);
        c.ckks_encoder = std::make_unique<CKKSEncoder>(*c.context);
    } else {
        throw std::runtime_error("Unsupported scheme (SEAL implements BFV/CKKS only): " + args.scheme);
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
        int scale_bits = std::min(40, usable_bits / 2);
        if (scale_bits < 1) scale_bits = 1;
        c.ckks_scale = std::pow(2.0, scale_bits);
    }

    KeyGenerator keygen(*c.context);
    c.secret_key = keygen.secret_key();
    keygen.create_public_key(c.public_key);
    if (grid.depth > 0) keygen.create_relin_keys(c.relin_keys);

    c.encryptor = std::make_unique<Encryptor>(*c.context, c.public_key);
    c.evaluator = std::make_unique<Evaluator>(*c.context);
    c.decryptor = std::make_unique<Decryptor>(*c.context, c.secret_key);
    return c;
}

// ---------- fresh plaintext/ciphertext generators (per iteration) ----------

std::mt19937_64 rng(12345);  // fixed seed: reproducibility across runs

Ciphertext fresh_ciphertext(Ctx &c, const Args &args) {
    Plaintext pt;
    if (args.scheme == "BFV") {
        size_t slots = c.batch_encoder->slot_count();
        std::vector<uint64_t> data(slots);
        for (auto &v : data) v = rng() % 2;  // small values, avoids overflow noise
        c.batch_encoder->encode(data, pt);
    } else {
        size_t slots = c.ckks_encoder->slot_count();
        std::vector<double> data(slots);
        std::uniform_real_distribution<double> dist(-1.0, 1.0);
        for (auto &v : data) v = dist(rng);
        c.ckks_encoder->encode(data, c.ckks_scale, pt);
    }
    Ciphertext ct;
    c.encryptor->encrypt(pt, ct);
    return ct;
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
    if (args.scheme == "BFV") {
        EncryptionParameters parms(scheme_type::bfv);
        parms.set_poly_modulus_degree(args.N);
        parms.set_coeff_modulus(CoeffModulus::Create(args.N, chain_bits));
        parms.set_plain_modulus(PlainModulus::Batching(args.N, 20));
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

// batch_size items are set up (encoded/encrypted/multiplied, as needed)
// BEFORE t0, matching the isolation convention of Scenario A/B — the timed
// region below contains only the core op, repeated batch_size times, so at
// batch_size=1 the timed cost is byte-for-byte identical to before. The
// return value is the TOTAL wall time for the whole batch trial (not
// per-item); aggregate.py derives throughput/amortized cost from it.

double time_encrypt(Ctx &c, const Args &args, int batch_size) {
    std::vector<Plaintext> pts(batch_size);
    for (int k = 0; k < batch_size; k++) {
        if (args.scheme == "BFV") {
            std::vector<uint64_t> data(c.batch_encoder->slot_count(), 1);
            c.batch_encoder->encode(data, pts[k]);
        } else {
            std::vector<double> data(c.ckks_encoder->slot_count(), 0.5);
            c.ckks_encoder->encode(data, c.ckks_scale, pts[k]);
        }
    }
    Ciphertext ct;
    auto t0 = Clock::now();
    for (int k = 0; k < batch_size; k++) c.encryptor->encrypt(pts[k], ct);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_decrypt(Ctx &c, const Args &args, int batch_size) {
    std::vector<Ciphertext> cts;
    cts.reserve(batch_size);
    for (int k = 0; k < batch_size; k++) cts.push_back(fresh_ciphertext(c, args));
    Plaintext pt;
    auto t0 = Clock::now();
    for (int k = 0; k < batch_size; k++) c.decryptor->decrypt(cts[k], pt);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_add(Ctx &c, const Args &args, int batch_size) {
    std::vector<Ciphertext> as, bs;
    as.reserve(batch_size); bs.reserve(batch_size);
    for (int k = 0; k < batch_size; k++) {
        as.push_back(fresh_ciphertext(c, args));
        bs.push_back(fresh_ciphertext(c, args));
    }
    Ciphertext result;
    auto t0 = Clock::now();
    for (int k = 0; k < batch_size; k++) c.evaluator->add(as[k], bs[k], result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_multiply(Ctx &c, const Args &args, int batch_size) {
    std::vector<Ciphertext> as, bs;
    as.reserve(batch_size); bs.reserve(batch_size);
    for (int k = 0; k < batch_size; k++) {
        as.push_back(fresh_ciphertext(c, args));
        bs.push_back(fresh_ciphertext(c, args));
    }
    Ciphertext result;
    auto t0 = Clock::now();
    for (int k = 0; k < batch_size; k++) c.evaluator->multiply(as[k], bs[k], result);
    auto t1 = Clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double time_relinearize(Ctx &c, const Args &args, int batch_size) {
    std::vector<Ciphertext> products;
    products.reserve(batch_size);
    for (int k = 0; k < batch_size; k++) {
        Ciphertext a = fresh_ciphertext(c, args);
        Ciphertext b = fresh_ciphertext(c, args);
        Ciphertext product;
        c.evaluator->multiply(a, b, product);  // untimed setup step
        products.push_back(std::move(product));
    }
    auto t0 = Clock::now();
    for (int k = 0; k < batch_size; k++)
        c.evaluator->relinearize_inplace(products[k], c.relin_keys);
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
    std::string status;
};

std::vector<NoiseTraceRow> run_noise_trace(const Args &args, const GridRow &grid) {
    Ctx c = build_context(args, grid);
    std::vector<NoiseTraceRow> rows;

    for (int trial = 0; trial < args.trace_reps; trial++) {
        int step_index = 0;

        Ciphertext ct = fresh_ciphertext(c, args);
        rows.push_back({trial, step_index++, "fresh",
                         c.decryptor->invariant_noise_budget(ct), "measured"});

        Ciphertext addend = fresh_ciphertext(c, args);
        c.evaluator->add_inplace(ct, addend);
        rows.push_back({trial, step_index++, "after_add",
                         c.decryptor->invariant_noise_budget(ct), "measured"});

        for (int m = 1; m <= grid.depth; m++) {
            Ciphertext factor = fresh_ciphertext(c, args);
            c.evaluator->multiply_inplace(ct, factor);
            rows.push_back({trial, step_index++, "after_multiply_" + std::to_string(m),
                             c.decryptor->invariant_noise_budget(ct), "measured"});

            c.evaluator->relinearize_inplace(ct, c.relin_keys);
            rows.push_back({trial, step_index++, "after_relinearize_" + std::to_string(m),
                             c.decryptor->invariant_noise_budget(ct), "measured"});
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

struct CkksTraceRow {
    int trial;
    int step_index;
    std::string step_name;
    double max_abs_error;
    double mean_abs_error;
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
    rows.push_back(
        {trial, step_index++, step_name, max_err, sum_err / static_cast<double>(expected.size()), "measured"});
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

// ---------- main ----------

int main(int argc, char **argv) {
    try {
        Args args = parse_args(argc, argv);
        GridRow grid = load_grid_row(args.grid_path, args.N, args.category);

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
            nt_out << "library,scheme,N,category,grid_depth,trial,step_index,step_name,"
                      "noise_budget_bits,status\n";

            if (args.scheme == "CKKS") {
                std::cerr << "SKIPPED: noise_trace is BFV/BGV-only (SEAL's invariant_noise_budget "
                             "throws for CKKS); N=" << args.N << " category=" << args.category
                          << " scheme=CKKS." << std::endl;
                nt_out << "SEAL,CKKS," << args.N << "," << args.category << "," << grid.depth
                       << ",,,,,\"skipped_not_applicable_ckks\"\n";
                nt_out.close();
                return 0;
            }

            std::vector<NoiseTraceRow> rows = run_noise_trace(args, grid);
            for (const auto &row : rows) {
                nt_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << "," << row.trial << "," << row.step_index << ","
                       << row.step_name << "," << row.noise_budget_bits << "," << row.status << "\n";
            }
            nt_out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
            return 0;
        }

        if (args.operation == "ckks_error") {
            std::ofstream ck_out(args.out);
            if (!ck_out.is_open()) throw std::runtime_error("Cannot open output file: " + args.out);
            ck_out << "library,scheme,N,category,grid_depth,trial,step_index,step_name,"
                      "max_abs_error,mean_abs_error,status\n";

            if (args.scheme != "CKKS") {
                std::cerr << "SKIPPED: ckks_error is CKKS-only (BFV/BGV are exact schemes, no "
                             "rounding error by construction); N=" << args.N << " category="
                          << args.category << " scheme=" << args.scheme << "." << std::endl;
                ck_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << ",,,,,,\"skipped_not_applicable_bfv\"\n";
                ck_out.close();
                return 0;
            }

            std::vector<CkksTraceRow> rows = run_ckks_error_trace(args, grid);
            for (const auto &row : rows) {
                ck_out << "SEAL," << args.scheme << "," << args.N << "," << args.category << ","
                       << grid.depth << "," << row.trial << "," << row.step_index << ","
                       << row.step_name << "," << row.max_abs_error << "," << row.mean_abs_error
                       << "," << row.status << "\n";
            }
            ck_out.close();
            std::cerr << "OK: wrote " << rows.size() << " rows to " << args.out << std::endl;
            return 0;
        }

        bool needs_depth = (args.operation == "multiply" || args.operation == "relinearize");
        if (needs_depth && grid.depth == 0) {
            std::cerr << "SKIPPED: N=" << args.N << " category=" << args.category
                      << " has depth=0 in param grid — " << args.operation
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
                // context/keys built once outside the loop for non-keygen ops
                // (rebuilt fresh only for keygen itself, above)
                static bool built = false;
                static Ctx c;
                if (!built) { c = build_context(args, grid); built = true; }

                if      (args.operation == "encrypt")      ms = time_encrypt(c, args, args.batch_size);
                else if (args.operation == "decrypt")      ms = time_decrypt(c, args, args.batch_size);
                else if (args.operation == "add")          ms = time_add(c, args, args.batch_size);
                else if (args.operation == "multiply")     ms = time_multiply(c, args, args.batch_size);
                else if (args.operation == "relinearize")  ms = time_relinearize(c, args, args.batch_size);
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
