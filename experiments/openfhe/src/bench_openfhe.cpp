// bench_openfhe.cpp
//
// Benchmark harness for OpenFHE 1.5.1, written to reproduce the SEAL
// measurement protocol of experiments/seal/src/bench_seal.cpp operation by
// operation. PILOT SCOPE: CKKS only (the supervisor-authorized pilot is CKKS
// N=8192/category 1); BFV/BGV stop with an error until their operation
// boundaries have been checked the same way.
//
// Same conventions as bench_seal:
//   - one CLI invocation = one (scheme, N, category, operation) cell;
//   - ONE ROW PER ITERATION, no statistics here (aggregate.py only);
//   - same CSV columns (library = "OpenFHE"), same --reps/--warmup/
//     --inner-loop semantics, the first --warmup rows marked "warmup";
//   - fresh inputs: everything an operation consumes is built BEFORE t0, a
//     different ciphertext for every call (inner_loop of them per rep), with
//     the same input values as bench_seal (encrypt: every slot 0.5; other
//     operations: slots uniform in [-1, 1] from mt19937_64 seeded 12345);
//   - the timed region contains only the operation itself.
//
// The configuration is NOT chosen here: it is read from eligible_v2.csv
// (experiments/openfhe/probe/make_grid_v2.py) -- the variant, depth and prime
// sizes of a configuration that passed the functional, security and
// repeated-correctness checks -- and the primes OpenFHE generates are
// compared with the ones recorded there; any difference stops the run.
//
// Operation boundaries (see docs for the side-by-side table):
//   keygen       SEAL: parameters + prime generation + SEALContext +
//                KeyGenerator (secret key) + public key + relinearization
//                keys when depth > 0. OpenFHE: CCParams + GenCryptoContext
//                (prime generation and precomputation) + Enable + KeyGen
//                (secret and public key) + EvalMultKeyGen when depth > 0.
//                OpenFHE caches contexts and NTT tables process-wide and
//                would reuse them from the second repetition on; they are
//                released (CryptoContextFactory::ReleaseAllContexts, which
//                also clears the static NTT/CRT tables and key maps) before
//                every repetition, OUTSIDE the timed region, so that every
//                keygen starts from scratch as in SEAL.
//   encrypt      public-key encryption of an already-encoded plaintext (in
//                NTT/evaluation form, as SEAL's CKKS encoder produces).
//                Known difference, not removable: SEAL encrypts at the key
//                level (including its special prime) and then switches the
//                result down; OpenFHE encrypts directly modulo Q.
//   decrypt      SEAL's CKKS Decryptor::decrypt stops at c0 + c1*s in NTT
//                form (no inverse NTT, no decoding). OpenFHE's
//                CryptoContext::Decrypt additionally applies the inverse
//                NTT, a multi-precision CRT reconstruction and decoding. So:
//                  decrypt       = c0 + c1*s on OpenFHE's own DCRTPoly
//                                  arithmetic (the computation of OpenFHE's
//                                  PKERNS::DecryptCore), SEAL's boundary;
//                  decrypt_full  = CryptoContext::Decrypt as an application
//                                  calls it -- reported separately, never
//                                  compared with SEAL's decrypt.
//   add          EvalAdd (SEAL: Evaluator::add).
//   multiply     EvalMultNoRelin, no rescaling (FIXEDMANUAL) (SEAL:
//                Evaluator::multiply, no relinearization, no rescaling).
//   relinearize  RelinearizeInPlace on a pre-computed product (SEAL:
//                relinearize_inplace).
//   rotate       EvalRotate by 1 with a key for index 1 only, one call per
//                repetition, no inner loop (SEAL composite rotate:
//                rotate_vector by 1, Galois key for step 1 only); the key
//                generation time is written in galois_keygen_ms as in SEAL.
//
// Usage:
//   bench_openfhe --scheme=CKKS --N=8192 --category=1 --operation=multiply \
//                 --reps=100 --warmup=5 --inner-loop=1000 \
//                 --eligible=../openfhe/probe/eligible_v2.csv --out=...
//   --check-out=FILE  after the loop, decrypts the result of the last call of
//                     every repetition (outside the timed region) and writes
//                     one correctness row per repetition (CKKS: normalized
//                     error < 1e-2, SEAL's CKKS_CORRECTNESS_THRESHOLD).
#include "openfhe.h"
#include "cryptocontext-ser.h"
#include "key/key-ser.h"
#include "scheme/ckksrns/ckksrns-ser.h"
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <random>
#include <sstream>

using namespace lbcrypto;
using Clock = std::chrono::steady_clock;

constexpr double CKKS_CORRECTNESS_THRESHOLD = 1e-2;  // = bench_seal.cpp

struct Args {
    std::string scheme, operation, out, check_out, eligible = "../openfhe/probe/eligible_v2.csv";
    int N = 0, category = 0, reps = 100, warmup = 5, inner_loop = 1000;
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
        if (s.rfind("--scheme=", 0) == 0) a.scheme = arg_value(s);
        else if (s.rfind("--N=", 0) == 0) a.N = std::stoi(arg_value(s));
        else if (s.rfind("--category=", 0) == 0) a.category = std::stoi(arg_value(s));
        else if (s.rfind("--operation=", 0) == 0) a.operation = arg_value(s);
        else if (s.rfind("--reps=", 0) == 0) a.reps = std::stoi(arg_value(s));
        else if (s.rfind("--warmup=", 0) == 0) a.warmup = std::stoi(arg_value(s));
        else if (s.rfind("--inner-loop=", 0) == 0) a.inner_loop = std::stoi(arg_value(s));
        else if (s.rfind("--eligible=", 0) == 0) a.eligible = arg_value(s);
        else if (s.rfind("--out=", 0) == 0) a.out = arg_value(s);
        else if (s.rfind("--check-out=", 0) == 0) a.check_out = arg_value(s);
        else throw std::runtime_error("Unknown argument: " + s);
    }
    if (a.scheme.empty() || !a.N || !a.category || a.operation.empty() || a.out.empty())
        throw std::runtime_error("Required: --scheme= --N= --category= --operation= --out=");
    if (a.inner_loop < 1) throw std::runtime_error("--inner-loop must be >= 1");
    if (a.scheme != "CKKS")
        throw std::runtime_error("pilot scope: only CKKS is implemented and checked (BFV/BGV boundaries not yet verified)");
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

static SecurityLevel level(int cat) {
    return cat == 1 ? HEStd_128_classic : cat == 3 ? HEStd_192_classic : HEStd_256_classic;
}

// Exactly the settings of openfhe_probe_v2.cpp / openfhe_correctness.cpp.
static CCParams<CryptoContextCKKSRNS> ckks_params(const Args &a, const Config &c) {
    CCParams<CryptoContextCKKSRNS> p;
    p.SetRingDim(a.N); p.SetSecurityLevel(level(a.category)); p.SetMultiplicativeDepth(c.depth);
    p.SetFirstModSize(c.first_bits); p.SetScalingModSize(c.scaling_bits); p.SetScalingTechnique(FIXEDMANUAL);
    p.SetBatchSize(a.N / 2);
    if (c.variant == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(c.depth + 1); }
    if (c.variant == 'C') p.SetKeySwitchTechnique(BV);
    return p;
}

static std::string primes_of(const std::shared_ptr<ILDCRTParams<BigInteger>> &p) {
    std::string s;
    if (p) for (auto &m : p->GetParams()) s += (s.empty() ? "" : " ") + m->GetModulus().ToString();
    return s;
}

struct Ctx { CryptoContext<DCRTPoly> cc; KeyPair<DCRTPoly> kp; };

static Ctx build_context(const Args &a, const Config &c, bool relin_keys) {
    Ctx x;
    x.cc = GenCryptoContext(ckks_params(a, c));
    x.cc->Enable(PKE); x.cc->Enable(KEYSWITCH); x.cc->Enable(LEVELEDSHE);
    auto cp = std::dynamic_pointer_cast<CryptoParametersRNS>(x.cc->GetCryptoParameters());
    if (primes_of(x.cc->GetElementParams()) != c.q_primes || primes_of(cp->GetParamsP()) != c.p_primes)
        throw std::runtime_error("OpenFHE generated other primes than eligible_v2.csv records -- stopping");
    x.kp = x.cc->KeyGen();
    if (relin_keys) x.cc->EvalMultKeyGen(x.kp.secretKey);
    return x;
}

// ---------- fresh inputs (same values as bench_seal.cpp) ----------

static std::mt19937_64 rng(12345);

struct Fresh { Ciphertext<DCRTPoly> ct; std::vector<double> x; };

static Fresh fresh_ciphertext(Ctx &c, size_t slots) {
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    std::vector<double> x(slots);
    for (auto &v : x) v = dist(rng);
    return {c.cc->Encrypt(c.kp.publicKey, c.cc->MakeCKKSPackedPlaintext(x)), x};
}

// ---------- correctness (outside every timed region) ----------

static double norm_error(Ctx &c, const Ciphertext<DCRTPoly> &ct, const std::vector<double> &expect, size_t n) {
    Plaintext pt;
    c.cc->Decrypt(c.kp.secretKey, ct, &pt);
    pt->SetLength(expect.size());
    auto got = pt->GetRealPackedValue();
    double w = 0;
    for (size_t i = 0; i < n; i++) w = std::max(w, std::abs(got[i] - expect[i]) / std::max(1.0, std::abs(expect[i])));
    return w;
}

struct Check { double err = 0; };

// ---------- timed operations: elapsed ms for ONE repetition ----------
// (total of inner_loop calls / inner_loop, as bench_seal)

static double ms(Clock::time_point t0, Clock::time_point t1) {
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

static double time_keygen(const Args &a, const Config &c, Check &chk) {
    CryptoContextFactory<DCRTPoly>::ReleaseAllContexts();  // untimed: no reuse of cached contexts/NTT tables
    auto t0 = Clock::now();
    CCParams<CryptoContextCKKSRNS> p = ckks_params(a, c);
    CryptoContext<DCRTPoly> cc = GenCryptoContext(p);
    cc->Enable(PKE); cc->Enable(KEYSWITCH); cc->Enable(LEVELEDSHE);
    KeyPair<DCRTPoly> kp = cc->KeyGen();
    if (c.depth > 0) cc->EvalMultKeyGen(kp.secretKey);
    auto t1 = Clock::now();
    // check: the keys just generated work (encrypt -> decrypt)
    Ctx x{cc, kp};
    std::vector<double> v(a.N / 2, 0.5);
    chk.err = norm_error(x, cc->Encrypt(kp.publicKey, cc->MakeCKKSPackedPlaintext(v)), v, v.size());
    return ms(t0, t1);
}

static double time_encrypt(Ctx &c, const Args &a, Check &chk) {
    const size_t slots = a.N / 2;
    std::vector<double> v(slots, 0.5);  // bench_seal: every slot 0.5
    std::vector<Plaintext> pts(a.inner_loop);
    for (auto &pt : pts) {
        pt = c.cc->MakeCKKSPackedPlaintext(v);
        pt->GetElement<DCRTPoly>().SetFormat(Format::EVALUATION);  // as SEAL's encoder output (NTT form)
    }
    Ciphertext<DCRTPoly> ct;
    auto t0 = Clock::now();
    for (int k = 0; k < a.inner_loop; k++) ct = c.cc->Encrypt(c.kp.publicKey, pts[k]);
    auto t1 = Clock::now();
    chk.err = norm_error(c, ct, v, slots);
    return ms(t0, t1) / a.inner_loop;
}

static double time_decrypt(Ctx &c, const Args &a, Check &chk, bool full) {
    const size_t slots = a.N / 2;
    std::vector<Fresh> in;
    in.reserve(a.inner_loop);
    for (int k = 0; k < a.inner_loop; k++) in.push_back(fresh_ciphertext(c, slots));
    const DCRTPoly &s = c.kp.secretKey->GetPrivateElement();
    DCRTPoly b;
    Plaintext pt;
    auto t0 = Clock::now();
    if (full) {
        for (int k = 0; k < a.inner_loop; k++) c.cc->Decrypt(c.kp.secretKey, in[k].ct, &pt);
    } else {
        for (int k = 0; k < a.inner_loop; k++) {
            const auto &cv = in[k].ct->GetElements();
            b = cv[1] * s;   // PKERNS::DecryptCore for a 2-element ciphertext:
            b += cv[0];      // c0 + c1*s, evaluation (NTT) form
        }
    }
    auto t1 = Clock::now();
    chk.err = norm_error(c, in.back().ct, in.back().x, slots);
    if (!full) {
        // The hand-written c0 + c1*s must carry the message: subtracting the
        // properly encoded input leaves only the small encryption noise.
        // Normalized like the CKKS threshold: max |noise| / scale < 1e-2.
        auto px = c.cc->MakeCKKSPackedPlaintext(in.back().x);
        px->GetElement<DCRTPoly>().SetFormat(Format::EVALUATION);
        DCRTPoly d = b - px->GetElement<DCRTPoly>();
        d.SetFormat(Format::COEFFICIENT);
        const auto &t0p = d.GetElementAtIndex(0);
        const auto q = t0p.GetModulus().ConvertToInt();
        double worst = 0;
        for (size_t i = 0; i < t0p.GetLength(); i++) {
            auto v = t0p[i].ConvertToInt();
            double centered = v > q / 2 ? -double(q - v) : double(v);
            worst = std::max(worst, std::abs(centered));
        }
        chk.err = std::max(chk.err, worst / in.back().ct->GetScalingFactor());
    }
    return ms(t0, t1) / a.inner_loop;
}

static double time_binary(Ctx &c, const Args &a, Check &chk, const std::string &op) {
    const size_t slots = a.N / 2;
    std::vector<Fresh> xs, ys;
    xs.reserve(a.inner_loop); ys.reserve(a.inner_loop);
    for (int k = 0; k < a.inner_loop; k++) { xs.push_back(fresh_ciphertext(c, slots)); ys.push_back(fresh_ciphertext(c, slots)); }
    std::vector<Ciphertext<DCRTPoly>> prods;
    if (op == "relinearize") {  // untimed setup step, as in bench_seal
        prods.reserve(a.inner_loop);
        for (int k = 0; k < a.inner_loop; k++) prods.push_back(c.cc->EvalMultNoRelin(xs[k].ct, ys[k].ct));
    }
    Ciphertext<DCRTPoly> r;
    auto t0 = Clock::now();
    if (op == "add")           for (int k = 0; k < a.inner_loop; k++) r = c.cc->EvalAdd(xs[k].ct, ys[k].ct);
    else if (op == "multiply") for (int k = 0; k < a.inner_loop; k++) r = c.cc->EvalMultNoRelin(xs[k].ct, ys[k].ct);
    else                       for (int k = 0; k < a.inner_loop; k++) c.cc->RelinearizeInPlace(prods[k]);
    auto t1 = Clock::now();
    if (op == "relinearize") r = prods.back();
    std::vector<double> e(slots);
    for (size_t i = 0; i < slots; i++)
        e[i] = op == "add" ? xs.back().x[i] + ys.back().x[i] : xs.back().x[i] * ys.back().x[i];
    chk.err = norm_error(c, r, e, slots);
    return ms(t0, t1) / a.inner_loop;
}

static double time_rotate(Ctx &c, const Args &a, Check &chk) {
    const size_t slots = a.N / 2;
    Fresh in = fresh_ciphertext(c, slots);  // setup before t0, one rotation per repetition
    auto t0 = Clock::now();
    auto r = c.cc->EvalRotate(in.ct, 1);
    auto t1 = Clock::now();
    std::vector<double> e(slots);
    for (size_t i = 0; i + 1 < slots; i++) e[i] = in.x[i + 1];
    chk.err = norm_error(c, r, e, slots - 1);
    return ms(t0, t1);
}

int main(int argc, char **argv) {
    try {
        Args a = parse_args(argc, argv);
        Config c = load_config(a);
        const std::string &op = a.operation;
        const std::string base = op == "decrypt_full" ? "decrypt" : op;
        if (c.ops.find(base) == std::string::npos)
            throw std::runtime_error(op + " is not among the operations to time for this configuration (" + c.ops + ")");

        std::ofstream out(a.out);
        if (!out) throw std::runtime_error("Cannot open output file: " + a.out);
        std::ofstream chk_out;
        if (!a.check_out.empty()) {
            chk_out.open(a.check_out);
            chk_out << "library,scheme,N,category,operation,iteration,norm_error,correctness\n";
        }
        const bool rotate = op == "rotate";
        out << "library,scheme,N,category,operation," << (rotate ? "galois_keygen_ms,galois_keys_size_bytes," : "batch_size,")
            << "iteration,latency_ms,status\n";

        Ctx x;
        double gk_ms = 0;
        size_t gk_bytes = 0;
        if (op != "keygen") {
            x = build_context(a, c, c.depth > 0);
            if (rotate) {
                auto g0 = Clock::now();
                x.cc->EvalRotateKeyGen(x.kp.secretKey, {1});  // index 1 only, as SEAL's step-1 Galois key
                gk_ms = ms(g0, Clock::now());
                std::stringstream ks;  // serialized size of that key (SEAL: galois_keys_size_bytes, uncompressed)
                x.cc->SerializeEvalAutomorphismKey(ks, SerType::BINARY);
                gk_bytes = ks.str().size();
            }
        }
        const int total = a.warmup + a.reps;
        for (int i = 0; i < total; i++) {
            Check k;
            double t;
            if (op == "keygen")             t = time_keygen(a, c, k);
            else if (op == "encrypt")       t = time_encrypt(x, a, k);
            else if (op == "decrypt")       t = time_decrypt(x, a, k, false);
            else if (op == "decrypt_full")  t = time_decrypt(x, a, k, true);
            else if (op == "add" || op == "multiply" || op == "relinearize") t = time_binary(x, a, k, op);
            else if (rotate)                t = time_rotate(x, a, k);
            else throw std::runtime_error("Unknown operation: " + op);
            const char *status = i < a.warmup ? "warmup" : "measured";
            out << "OpenFHE," << a.scheme << "," << a.N << "," << a.category << "," << op << ","
                << (rotate ? std::to_string(gk_ms) + "," + std::to_string(gk_bytes) + "," : "1,") << i << "," << t << "," << status << "\n";
            if (chk_out.is_open())
                chk_out << "OpenFHE," << a.scheme << "," << a.N << "," << a.category << "," << op << "," << i << ","
                        << k.err << "," << (k.err < CKKS_CORRECTNESS_THRESHOLD ? "correct" : "MISMATCH") << "\n";
        }
        std::cerr << "OK: wrote " << total << " rows to " << a.out << std::endl;
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        return 1;
    }
}
