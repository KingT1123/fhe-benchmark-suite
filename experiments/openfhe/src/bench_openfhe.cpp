// bench_openfhe.cpp
//
// Benchmark harness for OpenFHE 1.5.1, written to reproduce the SEAL
// measurement protocol of experiments/seal/src/bench_seal.cpp operation by
// operation, for CKKS, BFV and BGV.
//
// Same conventions as bench_seal:
//   - one CLI invocation = one (scheme, N, category, operation) cell;
//   - ONE ROW PER ITERATION, no statistics here (aggregate.py only);
//   - same CSV columns (library = "OpenFHE"), same --reps/--warmup/
//     --inner-loop semantics, the first --warmup rows marked "warmup";
//   - fresh inputs: everything an operation consumes is built BEFORE t0, a
//     different ciphertext for every call (inner_loop of them per rep), with
//     the same input values as bench_seal: encrypt encodes a constant
//     plaintext (CKKS every slot 0.5, BFV/BGV every slot 1); the other
//     operations use fresh ciphertexts whose slots are uniform in [-1, 1]
//     (CKKS) or in {0, 1} (BFV/BGV), from mt19937_64 seeded 12345;
//   - the timed region contains only the operation itself;
//   - energy (--rapl-dir, --idle-*, --ramp-seconds) and peak memory
//     (--peak-rss-out) exactly as bench_seal's round-3 protocol.
//
// FAIL-CLOSED. Every repetition's result is decrypted and checked after the
// timer stops (CKKS: error normalized by max(1,|expected|) below 1e-2, SEAL's
// CKKS_CORRECTNESS_THRESHOLD; BFV/BGV: every slot exact mod t). The rows are
// held in memory and the output files (--out and the mandatory --check-out)
// are written only when every repetition ran and every check passed, through
// a temporary file renamed into place, so an existing output file is always
// complete. A failed check stops the run at once: the rows so far are kept
// as <out>.invalid for diagnosis, no output file is produced, exit code 3.
// Any other error (exception, wrong primes, unreadable counter): exit code 1,
// no output file. --inject-mismatch-at=K (tests only) falsifies the expected
// value of repetition K, to demonstrate that a wrong result is caught.
//
// The configuration is read from eligible_v2.csv (make_grid_v2.py) and the
// primes OpenFHE generates are compared with the recorded ones.
//
// Operation boundaries (side-by-side table in docs/comparability/):
//   keygen       SEAL: parameters + prime generation + SEALContext + secret,
//                public and (depth > 0) relinearization keys. OpenFHE:
//                CCParams + GenCryptoContext + Enable + KeyGen +
//                (depth > 0) EvalMultKeyGen. OpenFHE's process-wide context
//                and NTT caches are released before every repetition,
//                outside the timing (CryptoContextFactory::ReleaseAllContexts).
//   encrypt      public-key encryption of an encoded plaintext (CKKS: in NTT
//                form, as SEAL's encoder output; BFV/BGV: coefficient form, as
//                SEAL's BatchEncoder output). Not the same work: SEAL encrypts
//                with its special prime and then removes it; OpenFHE encrypts
//                modulo Q (BFV: then scales the plaintext by Q/t).
//   decrypt      SEAL's boundary. CKKS: c0 + c1*s in NTT form (SEAL stops
//                there), computed on OpenFHE's polynomial arithmetic as in
//                PKERNS::DecryptCore. BFV/BGV: the scheme-level decryption to
//                the plaintext polynomial mod t (OpenFHE SchemeBase::Decrypt to
//                a NativePoly: DecryptCore + inverse NTT + scale-and-round
//                (BFV) or modulus reduction (BGV)), where SEAL's decrypt also
//                stops (before batch decoding).
//   decrypt_full CryptoContext::Decrypt as an application calls it (also
//                decodes): an end-to-end API cost, not compared with SEAL's
//                decrypt.
//   add          EvalAdd: end-to-end API cost; it clones its first operand
//                into a new ciphertext before adding (LeveledSHERNS::EvalAdd).
//   add_inplace  EvalAddInPlace, the addition without the clone.
//   multiply     EvalMultNoRelin (CKKS/BGV: no rescaling; BFV: the
//                multiplication includes OpenFHE's scaling by t/Q, HPS-based,
//                where SEAL uses BEHZ).
//   relinearize  RelinearizeInPlace on a pre-computed product.
//   rotate       EvalRotate by 1 with a key for index 1 only, one call per
//                repetition (SEAL: rotate_vector / rotate_rows by 1, Galois
//                key for step 1). Checked on the complete output vector,
//                including the wraparound slot (BFV/BGV: each row of N/2
//                slots rotated cyclically, as SEAL's rotate_rows).
//
// Usage:
//   bench_openfhe --scheme=CKKS --N=8192 --category=1 --operation=multiply \
//     --reps=100 --warmup=5 --inner-loop=1000 \
//     --eligible=probe/eligible_v2.csv --out=X.csv --check-out=X_check.csv
#include "openfhe.h"
#include "cryptocontext-ser.h"
#include "key/key-ser.h"
#include "scheme/ckksrns/ckksrns-ser.h"
#include "scheme/bfvrns/bfvrns-ser.h"
#include "scheme/bgvrns/bgvrns-ser.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <random>
#include <sstream>
#include <functional>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using namespace lbcrypto;
using Clock = std::chrono::steady_clock;

constexpr double CKKS_CORRECTNESS_THRESHOLD = 1e-2;  // = bench_seal.cpp

struct Args {
    std::string scheme, operation, out, check_out, eligible = "probe/eligible_v2.csv";
    std::string rapl_dir, peak_rss_out;
    int N = 0, category = 0, reps = 100, warmup = 5, inner_loop = 1000;
    int idle_seconds = 0, idle_settle_seconds = 0, ramp_seconds = 0;
    int inject_mismatch_at = -1;
};

static std::string arg_value(const std::string &a) {
    auto p = a.find('=');
    if (p == std::string::npos) throw std::runtime_error("Bad argument: " + a);
    return a.substr(p + 1);
}

static Args parse_args(int argc, char **argv) {
    Args a;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        auto is = [&](const char *k) { return s.rfind(k, 0) == 0; };
        if (is("--scheme=")) a.scheme = arg_value(s);
        else if (is("--N=")) a.N = std::stoi(arg_value(s));
        else if (is("--category=")) a.category = std::stoi(arg_value(s));
        else if (is("--operation=")) a.operation = arg_value(s);
        else if (is("--reps=")) a.reps = std::stoi(arg_value(s));
        else if (is("--warmup=")) a.warmup = std::stoi(arg_value(s));
        else if (is("--inner-loop=")) a.inner_loop = std::stoi(arg_value(s));
        else if (is("--eligible=")) a.eligible = arg_value(s);
        else if (is("--out=")) a.out = arg_value(s);
        else if (is("--check-out=")) a.check_out = arg_value(s);
        else if (is("--rapl-dir=")) a.rapl_dir = arg_value(s);
        else if (is("--idle-seconds=")) a.idle_seconds = std::stoi(arg_value(s));
        else if (is("--idle-settle-seconds=")) a.idle_settle_seconds = std::stoi(arg_value(s));
        else if (is("--ramp-seconds=")) a.ramp_seconds = std::stoi(arg_value(s));
        else if (is("--peak-rss-out=")) a.peak_rss_out = arg_value(s);
        else if (is("--inject-mismatch-at=")) a.inject_mismatch_at = std::stoi(arg_value(s));
        else throw std::runtime_error("Unknown argument: " + s);
    }
    if (a.scheme.empty() || !a.N || !a.category || a.operation.empty() || a.out.empty() || a.check_out.empty())
        throw std::runtime_error("Required: --scheme= --N= --category= --operation= --out= --check-out=");
    if (a.scheme != "CKKS" && a.scheme != "BFV" && a.scheme != "BGV")
        throw std::runtime_error("Unsupported scheme: " + a.scheme);
    if (a.inner_loop < 1 || a.reps < 1 || a.warmup < 0) throw std::runtime_error("bad --reps/--warmup/--inner-loop");
    return a;
}

// ---------- configuration from eligible_v2.csv ----------

struct Config { char variant; uint32_t depth, first_bits, scaling_bits; std::string q_primes, p_primes, ops; };

static std::vector<std::string> split_csv(const std::string &line) {
    std::vector<std::string> out; std::string cur; bool q = false;
    for (char ch : line) {
        if (ch == '"') q = !q;
        else if (ch == ',' && !q) { out.push_back(cur); cur.clear(); }
        else cur += ch;
    }
    out.push_back(cur);
    return out;
}

static Config load_config(const Args &a) {
    std::ifstream f(a.eligible);
    if (!f) throw std::runtime_error("Cannot open " + a.eligible);
    std::string line; std::getline(f, line);
    auto hdr = split_csv(line);
    while (std::getline(f, line)) {
        auto v = split_csv(line);
        std::map<std::string, std::string> r;
        for (size_t i = 0; i < hdr.size(); i++) r[hdr[i]] = v[i];
        if (r["scheme"] == a.scheme && std::stoi(r["N"]) == a.N && std::stoi(r["category"]) == a.category)
            return {r["variant"][0], (uint32_t)std::stoul(r["depth"]), (uint32_t)std::stoul(r["first_mod_bits"]),
                    (uint32_t)std::stoul(r["scaling_mod_bits"]), r["q_primes"], r["p_primes"], r["ops"]};
    }
    throw std::runtime_error("Configuration not eligible for measurement (absent from " + a.eligible + ")");
}

// SEAL's plaintext modulus per cell (= openfhe_probe_v2.cpp, bench_seal.cpp).
static uint64_t seal_t(uint32_t N, int cat) {
    if (N == 2048 && (cat == 1 || cat == 5)) return 12289;
    if (N == 4096 && cat == 5) return 40961;
    return N == 16384 ? 786433 : 1032193;
}
static SecurityLevel level(int cat) {
    return cat == 1 ? HEStd_128_classic : cat == 3 ? HEStd_192_classic : HEStd_256_classic;
}

// Exactly the settings of openfhe_probe_v2.cpp / openfhe_correctness.cpp.
template <typename P>
static void key_switching(P &p, const Config &c) {
    if (c.variant == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(c.depth + 1); }
    if (c.variant == 'C') p.SetKeySwitchTechnique(BV);
}
static CryptoContext<DCRTPoly> make_context(const Args &a, const Config &c) {
    if (a.scheme == "CKKS") {
        CCParams<CryptoContextCKKSRNS> p;
        p.SetRingDim(a.N); p.SetSecurityLevel(level(a.category)); p.SetMultiplicativeDepth(c.depth);
        p.SetFirstModSize(c.first_bits); p.SetScalingModSize(c.scaling_bits); p.SetScalingTechnique(FIXEDMANUAL);
        p.SetBatchSize(a.N / 2); key_switching(p, c);
        return GenCryptoContext(p);
    }
    if (a.scheme == "BGV") {
        CCParams<CryptoContextBGVRNS> p;
        p.SetRingDim(a.N); p.SetSecurityLevel(level(a.category)); p.SetMultiplicativeDepth(c.depth);
        p.SetPlaintextModulus(seal_t(a.N, a.category));
        p.SetFirstModSize(c.first_bits); p.SetScalingModSize(c.scaling_bits); p.SetScalingTechnique(FIXEDMANUAL);
        key_switching(p, c);
        return GenCryptoContext(p);
    }
    CCParams<CryptoContextBFVRNS> p;
    p.SetRingDim(a.N); p.SetSecurityLevel(level(a.category)); p.SetMultiplicativeDepth(c.depth);
    p.SetPlaintextModulus(seal_t(a.N, a.category));
    if (c.variant == 'B') p.SetScalingModSize(c.scaling_bits);
    key_switching(p, c);
    return GenCryptoContext(p);
}

static std::string primes_of(const std::shared_ptr<ILDCRTParams<BigInteger>> &p) {
    std::string s;
    if (p) for (auto &m : p->GetParams()) s += (s.empty() ? "" : " ") + m->GetModulus().ToString();
    return s;
}

struct Ctx { CryptoContext<DCRTPoly> cc; KeyPair<DCRTPoly> kp; bool ckks = true; size_t slots = 0; uint64_t t = 0; };

static Ctx build_context(const Args &a, const Config &c) {
    Ctx x;
    x.cc = make_context(a, c);
    x.cc->Enable(PKE); x.cc->Enable(KEYSWITCH); x.cc->Enable(LEVELEDSHE);
    auto cp = std::dynamic_pointer_cast<CryptoParametersRNS>(x.cc->GetCryptoParameters());
    if (primes_of(x.cc->GetElementParams()) != c.q_primes || primes_of(cp->GetParamsP()) != c.p_primes)
        throw std::runtime_error("OpenFHE generated other primes than eligible_v2.csv records -- stopping");
    x.ckks = a.scheme == "CKKS";
    x.slots = x.ckks ? a.N / 2 : a.N;
    x.t = x.ckks ? 0 : seal_t(a.N, a.category);
    x.kp = x.cc->KeyGen();
    if (c.depth > 0) x.cc->EvalMultKeyGen(x.kp.secretKey);
    return x;
}

// ---------- inputs (same values as bench_seal.cpp) ----------

static std::mt19937_64 rng(12345);

struct Fresh { Ciphertext<DCRTPoly> ct; std::vector<double> x; };  // BFV/BGV values held exactly as doubles

static Plaintext encode(Ctx &c, const std::vector<double> &x) {
    if (c.ckks) return c.cc->MakeCKKSPackedPlaintext(x);
    std::vector<int64_t> v(x.begin(), x.end());
    return c.cc->MakePackedPlaintext(v);
}

static Fresh fresh_ciphertext(Ctx &c) {
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    std::vector<double> x(c.slots);
    for (auto &v : x) v = c.ckks ? dist(rng) : double(rng() % 2);
    return {c.cc->Encrypt(c.kp.publicKey, encode(c, x)), x};
}

// ---------- correctness (always, outside every timed region) ----------
// CKKS: largest error normalized by max(1,|expected|). BFV/BGV: number of
// slots whose value differs mod t. n: number of leading slots compared.

static double check_error(Ctx &c, const Ciphertext<DCRTPoly> &ct, const std::vector<double> &expect) {
    Plaintext pt;
    c.cc->Decrypt(c.kp.secretKey, ct, &pt);
    pt->SetLength(expect.size());
    double w = 0;
    if (c.ckks) {
        auto got = pt->GetRealPackedValue();
        for (size_t i = 0; i < expect.size(); i++)
            w = std::max(w, std::abs(got[i] - expect[i]) / std::max(1.0, std::abs(expect[i])));
    } else {
        auto got = pt->GetPackedValue();
        auto mod = [&](int64_t z) { int64_t t = (int64_t)c.t; return ((z % t) + t) % t; };
        for (size_t i = 0; i < expect.size(); i++)
            if (mod(got[i]) != mod((int64_t)std::llround(expect[i]))) w += 1;
    }
    return w;
}
static bool passes(const Ctx &c, double err) { return c.ckks ? err < CKKS_CORRECTNESS_THRESHOLD : err == 0; }

// Expected rotation by one slot, complete vector including the wraparound:
// CKKS one cyclic vector of N/2 slots; BFV/BGV two rows of N/2 slots, each
// rotated cyclically (SEAL rotate_rows).
static std::vector<double> rotated(const Ctx &c, const std::vector<double> &x) {
    std::vector<double> e(x.size());
    const size_t row = c.ckks ? x.size() : x.size() / 2;
    for (size_t r = 0; r < x.size(); r += row)
        for (size_t i = 0; i < row; i++) e[r + i] = x[r + (i + 1) % row];
    return e;
}

// ---------- energy (bench_seal's --rapl-dir protocol) ----------

static std::string g_rapl_energy_path;
static uint64_t g_rapl_max_uj = 0, g_last_window_uj = 0;

static uint64_t rapl_now() {
    if (g_rapl_energy_path.empty()) return 0;
    std::ifstream f(g_rapl_energy_path);
    uint64_t v = 0;
    if (!(f >> v)) throw std::runtime_error("Cannot read " + g_rapl_energy_path);
    return v;
}
static uint64_t rapl_delta(uint64_t b, uint64_t e) { return e >= b ? e - b : e + g_rapl_max_uj - b; }
static long read_vmhwm_kb() {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line))
        if (line.rfind("VmHWM:", 0) == 0) return std::stol(line.substr(6));
    return -1;
}

// ---------- timed operations: elapsed ms for ONE repetition ----------
// (total of inner_loop calls / inner_loop, as bench_seal). Each also returns
// the result of its last call and the expected values, for the check.

// extra: an additional check of the operation's own output (decrypt at SEAL's
// boundary), run together with the main check.
struct Result { double ms; Ciphertext<DCRTPoly> ct; std::vector<double> expect; std::function<double()> extra; };

// With --peak-rss-out (memory measurement) every check runs in a forked child
// process, so that the objects the check creates never count towards the
// measured process's peak memory (VmHWM). The child returns the error through
// a pipe; a child that fails in any way yields an error that fails the check.
static bool g_fork_checks = false;
template <typename F>
static double run_check(F f) {
    if (!g_fork_checks) return f();
    int fd[2];
    if (pipe(fd) != 0) throw std::runtime_error("pipe() failed for the correctness check");
    pid_t pid = fork();
    if (pid < 0) throw std::runtime_error("fork() failed for the correctness check");
    if (pid == 0) {
        close(fd[0]);
        double e = 1e300;
        try { e = f(); } catch (...) {}
        ssize_t w = write(fd[1], &e, sizeof e);
        _exit(w == sizeof e ? 0 : 1);
    }
    close(fd[1]);
    double e = 1e300;
    ssize_t r = read(fd[0], &e, sizeof e);
    close(fd[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    return (r == sizeof e && WIFEXITED(st) && WEXITSTATUS(st) == 0) ? e : 1e300;
}

static double ms(Clock::time_point t0, Clock::time_point t1) {
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

static Result time_keygen(const Args &a, const Config &c, Ctx &keys_out) {
    CryptoContextFactory<DCRTPoly>::ReleaseAllContexts();  // untimed: no reuse of cached contexts/NTT tables
    uint64_t e0 = rapl_now();
    auto t0 = Clock::now();
    CryptoContext<DCRTPoly> cc = make_context(a, c);
    cc->Enable(PKE); cc->Enable(KEYSWITCH); cc->Enable(LEVELEDSHE);
    KeyPair<DCRTPoly> kp = cc->KeyGen();
    if (c.depth > 0) cc->EvalMultKeyGen(kp.secretKey);
    auto t1 = Clock::now();
    g_last_window_uj = rapl_delta(e0, rapl_now());
    // check: the keys just generated work (fresh input through encrypt -> decrypt)
    keys_out.cc = cc; keys_out.kp = kp;
    keys_out.ckks = a.scheme == "CKKS"; keys_out.slots = keys_out.ckks ? a.N / 2 : a.N;
    keys_out.t = keys_out.ckks ? 0 : seal_t(a.N, a.category);
    Fresh f = fresh_ciphertext(keys_out);
    return {ms(t0, t1), f.ct, f.x, nullptr};
}

static Result time_encrypt(Ctx &c, const Args &a) {
    std::vector<double> v(c.slots, c.ckks ? 0.5 : 1.0);  // bench_seal: CKKS 0.5, BFV/BGV 1 in every slot
    std::vector<Plaintext> pts(a.inner_loop);
    for (auto &pt : pts) {
        pt = encode(c, v);
        if (c.ckks) pt->GetElement<DCRTPoly>().SetFormat(Format::EVALUATION);  // as SEAL's CKKS encoder (NTT form)
    }
    Ciphertext<DCRTPoly> ct;
    uint64_t e0 = rapl_now();
    auto t0 = Clock::now();
    for (int k = 0; k < a.inner_loop; k++) ct = c.cc->Encrypt(c.kp.publicKey, pts[k]);
    auto t1 = Clock::now();
    g_last_window_uj = rapl_delta(e0, rapl_now());
    return {ms(t0, t1) / a.inner_loop, ct, v, nullptr};
}

static Result time_decrypt(Ctx &c, const Args &a, bool full) {
    std::vector<Fresh> in;
    in.reserve(a.inner_loop);
    for (int k = 0; k < a.inner_loop; k++) in.push_back(fresh_ciphertext(c));
    const DCRTPoly &s = c.kp.secretKey->GetPrivateElement();
    DCRTPoly b;
    NativePoly np;
    Plaintext pt;
    uint64_t e0 = rapl_now();
    auto t0 = Clock::now();
    if (full) {
        for (int k = 0; k < a.inner_loop; k++) c.cc->Decrypt(c.kp.secretKey, in[k].ct, &pt);
    } else if (c.ckks) {
        for (int k = 0; k < a.inner_loop; k++) {
            const auto &cv = in[k].ct->GetElements();
            b = cv[1] * s;   // PKERNS::DecryptCore for a 2-element ciphertext:
            b += cv[0];      // c0 + c1*s, evaluation (NTT) form
        }
    } else {
        for (int k = 0; k < a.inner_loop; k++) c.cc->GetScheme()->Decrypt(in[k].ct, c.kp.secretKey, &np);
    }
    auto t1 = Clock::now();
    g_last_window_uj = rapl_delta(e0, rapl_now());
    Result r{ms(t0, t1) / a.inner_loop, in.back().ct, in.back().x, nullptr};
    if (!full) {
        // The value computed at SEAL's boundary must itself be right (run
        // with the main check, after the timer).
        const double scale = in.back().ct->GetScalingFactor();
        r.extra = [&c, b = std::move(b), np = std::move(np), x = in.back().x, scale]() -> double {
            auto px = encode(c, x);
            if (c.ckks) {
                // c0 + c1*s minus the encoded input leaves only the small noise:
                // max |noise| / scale, normalized like the CKKS threshold.
                px->GetElement<DCRTPoly>().SetFormat(Format::EVALUATION);
                DCRTPoly d = b - px->GetElement<DCRTPoly>();
                d.SetFormat(Format::COEFFICIENT);
                const auto &t0p = d.GetElementAtIndex(0);
                const auto q = t0p.GetModulus().ConvertToInt();
                double worst = 0;
                for (size_t i = 0; i < t0p.GetLength(); i++) {
                    auto v = t0p[i].ConvertToInt();
                    worst = std::max(worst, std::abs(v > q / 2 ? -double(q - v) : double(v)));
                }
                return worst / scale;
            }
            // the plaintext polynomial mod t must equal the encoded input
            // exactly; the encoding is held as a DCRTPoly whose residues are
            // the (signed) coefficients, read from the first prime
            DCRTPoly e = px->GetElement<DCRTPoly>();
            e.SetFormat(Format::COEFFICIENT);
            const auto &e0p = e.GetElementAtIndex(0);
            const uint64_t q = e0p.GetModulus().ConvertToInt(), t = c.t;
            size_t bad = 0;
            for (size_t i = 0; i < e0p.GetLength(); i++) {
                const uint64_t v = e0p[i].ConvertToInt();
                const int64_t centered = v > q / 2 ? -int64_t(q - v) : int64_t(v);
                const uint64_t want = uint64_t(((centered % int64_t(t)) + int64_t(t)) % int64_t(t));
                bad += (np[i].ConvertToInt() % t != want);
            }
            return double(bad);
        };
    }
    return r;
}

static Result time_binary(Ctx &c, const Args &a, const std::string &op) {
    std::vector<Fresh> xs, ys;
    xs.reserve(a.inner_loop); ys.reserve(a.inner_loop);
    for (int k = 0; k < a.inner_loop; k++) { xs.push_back(fresh_ciphertext(c)); ys.push_back(fresh_ciphertext(c)); }
    std::vector<Ciphertext<DCRTPoly>> prods;
    if (op == "relinearize") {  // untimed setup step, as in bench_seal
        prods.reserve(a.inner_loop);
        for (int k = 0; k < a.inner_loop; k++) prods.push_back(c.cc->EvalMultNoRelin(xs[k].ct, ys[k].ct));
    }
    Ciphertext<DCRTPoly> r;
    uint64_t e0 = rapl_now();
    auto t0 = Clock::now();
    if (op == "add")              for (int k = 0; k < a.inner_loop; k++) r = c.cc->EvalAdd(xs[k].ct, ys[k].ct);
    else if (op == "add_inplace") for (int k = 0; k < a.inner_loop; k++) c.cc->EvalAddInPlace(xs[k].ct, ys[k].ct);
    else if (op == "multiply")    for (int k = 0; k < a.inner_loop; k++) r = c.cc->EvalMultNoRelin(xs[k].ct, ys[k].ct);
    else                          for (int k = 0; k < a.inner_loop; k++) c.cc->RelinearizeInPlace(prods[k]);
    auto t1 = Clock::now();
    g_last_window_uj = rapl_delta(e0, rapl_now());
    if (op == "relinearize") r = prods.back();
    if (op == "add_inplace") r = xs.back().ct;
    std::vector<double> e(c.slots);
    for (size_t i = 0; i < c.slots; i++)
        e[i] = op.rfind("add", 0) == 0 ? xs.back().x[i] + ys.back().x[i] : xs.back().x[i] * ys.back().x[i];
    return {ms(t0, t1) / a.inner_loop, r, e, nullptr};
}

static Result time_rotate(Ctx &c) {
    Fresh in = fresh_ciphertext(c);  // setup before t0, one rotation per repetition
    uint64_t e0 = rapl_now();
    auto t0 = Clock::now();
    auto r = c.cc->EvalRotate(in.ct, 1);
    auto t1 = Clock::now();
    g_last_window_uj = rapl_delta(e0, rapl_now());
    return {ms(t0, t1), r, rotated(c, in.x), nullptr};
}

// ---------- output: written only when the whole cell is valid ----------

static void write_atomically(const std::string &path, const std::string &content) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp);
        if (!(f << content) || !(f.flush())) throw std::runtime_error("Cannot write " + tmp);
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) throw std::runtime_error("Cannot rename " + tmp);
}

int main(int argc, char **argv) {
    std::string out_path;
    try {
        Args a = parse_args(argc, argv);
        out_path = a.out;
        std::remove(a.out.c_str());          // a stale file never survives a new attempt
        std::remove(a.check_out.c_str());
        Config c = load_config(a);
        const std::string &op = a.operation;
        const std::string base = op == "decrypt_full" ? "decrypt" : op == "add_inplace" ? "add" : op;
        if (c.ops.find(base) == std::string::npos)
            throw std::runtime_error(op + " is not among the operations to time for this configuration (" + c.ops + ")");
        if (!a.rapl_dir.empty()) {
            g_rapl_energy_path = a.rapl_dir + "/energy_uj";
            std::ifstream mf(a.rapl_dir + "/max_energy_range_uj");
            if (!(mf >> g_rapl_max_uj)) throw std::runtime_error("Cannot read " + a.rapl_dir + "/max_energy_range_uj");
            rapl_now();
        }
        const bool energy = !g_rapl_energy_path.empty();
        const bool rotate = op == "rotate";
        g_fork_checks = !a.peak_rss_out.empty();

        Ctx x;
        double gk_ms = 0;
        size_t gk_bytes = 0;
        if (op != "keygen") {
            x = build_context(a, c);
            if (rotate) {
                auto g0 = Clock::now();
                x.cc->EvalRotateKeyGen(x.kp.secretKey, {1});  // index 1 only, as SEAL's step-1 Galois key
                gk_ms = ms(g0, Clock::now());
                std::stringstream ks;  // serialized size of that key (SEAL: galois_keys_size_bytes, uncompressed)
                x.cc->SerializeEvalAutomorphismKey(ks, SerType::BINARY);
                gk_bytes = ks.str().size();
            }
        }

        std::ostringstream out, chk;
        out << "library,scheme,N,category,operation," << (rotate ? "galois_keygen_ms,galois_keys_size_bytes," : "batch_size,")
            << "iteration,latency_ms,status" << (energy ? ",inner_loop,energy_uj,idle_power_w" : "") << "\n";
        chk << "library,scheme,N,category,operation,iteration,error,metric,correctness\n";

        // idle package power just before the reps (bench_seal round-3 protocol)
        double idle_w = 0.0;
        if (energy && a.idle_seconds > 0) {
            std::this_thread::sleep_for(std::chrono::seconds(a.idle_settle_seconds));
            auto w0 = Clock::now();
            uint64_t i0 = rapl_now();
            std::this_thread::sleep_for(std::chrono::seconds(a.idle_seconds));
            uint64_t i1 = rapl_now();
            idle_w = rapl_delta(i0, i1) / 1e6 / std::chrono::duration<double>(Clock::now() - w0).count();
        }
        if (energy && a.ramp_seconds > 0) {
            volatile uint64_t spin = 0;
            auto r0 = Clock::now();
            while (Clock::now() - r0 < std::chrono::seconds(a.ramp_seconds)) spin = spin + 1;
        }
        const int ops_per_window = (op == "keygen" || rotate) ? 1 : a.inner_loop;

        const int total = a.warmup + a.reps;
        for (int i = 0; i < total; i++) {
            Result r;
            Ctx kx;
            if (op == "keygen")             r = time_keygen(a, c, kx);
            else if (op == "encrypt")       r = time_encrypt(x, a);
            else if (op == "decrypt")       r = time_decrypt(x, a, false);
            else if (op == "decrypt_full")  r = time_decrypt(x, a, true);
            else if (op == "add" || op == "add_inplace" || op == "multiply" || op == "relinearize")
                r = time_binary(x, a, op);
            else if (rotate)                r = time_rotate(x);
            else throw std::runtime_error("Unknown operation: " + op);
            Ctx &cx = op == "keygen" ? kx : x;

            if (i == a.inject_mismatch_at) r.expect[0] += 1.0;  // TEST ONLY: falsified expectation
            const double err = run_check([&] {
                double e = check_error(cx, r.ct, r.expect);
                if (r.extra) e = std::max(e, r.extra());
                return e;
            });
            const bool ok = passes(cx, err);
            out << "OpenFHE," << a.scheme << "," << a.N << "," << a.category << "," << op << ","
                << (rotate ? std::to_string(gk_ms) + "," + std::to_string(gk_bytes) + "," : "1,") << i << "," << r.ms
                << "," << (i < a.warmup ? "warmup" : "measured");
            if (energy) out << "," << ops_per_window << "," << g_last_window_uj << "," << idle_w;
            out << "\n";
            chk << "OpenFHE," << a.scheme << "," << a.N << "," << a.category << "," << op << "," << i << "," << err << ","
                << (cx.ckks ? "max_norm_error" : "mismatching_slots") << "," << (ok ? "correct" : "MISMATCH") << "\n";
            if (!ok) {
                std::ofstream inv(a.out + ".invalid");
                inv << out.str() << "# INVALID: repetition " << i << " failed its correctness check (error " << err
                    << "); the cell has no output file\n" << chk.str();
                std::cerr << "ERROR: repetition " << i << " of " << op << " failed its correctness check (error " << err
                          << ") -- cell invalid, no output written (" << a.out << ".invalid kept)" << std::endl;
                return 3;
            }
        }
        write_atomically(a.check_out, chk.str());
        write_atomically(a.out, out.str());
        if (!a.peak_rss_out.empty())
            write_atomically(a.peak_rss_out, "Maximum resident set size (kbytes): " + std::to_string(read_vmhwm_kb()) + "\n");
        std::cerr << "OK: wrote " << total << " rows to " << a.out << " (all " << total << " checks correct)" << std::endl;
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << " -- no output written" << std::endl;
        return 1;
    }
}
