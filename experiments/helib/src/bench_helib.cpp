// bench_helib.cpp
//
// Latency harness for HElib 2.2.0 (latency pilot), written to reproduce the
// SEAL measurement protocol of experiments/seal/src/bench_seal.cpp, as
// experiments/openfhe/src/bench_openfhe.cpp does for OpenFHE. CKKS and BGV
// (HElib has no BFV).
//
// Same conventions as bench_seal / bench_openfhe:
//   - one CLI invocation = one (scheme, N, category, operation) cell;
//   - ONE ROW PER ITERATION, no statistics here (aggregate.py only);
//   - same CSV columns (library = "HElib"), same --reps/--warmup/--inner-loop
//     semantics, the first --warmup rows marked "warmup";
//   - fresh inputs: everything an operation consumes is built BEFORE t0, a
//     different ciphertext for every call (inner_loop of them per rep), with
//     the same input values as bench_seal: encrypt encodes a constant
//     plaintext (CKKS every slot 0.5, BGV every slot 1); the other operations
//     use fresh ciphertexts whose slots are uniform in [-1, 1] (CKKS) or in
//     {0, 1} (BGV), from mt19937_64 seeded 12345;
//   - the timed region contains only the operation itself.
//
// FAIL-CLOSED, as bench_openfhe: every repetition's result is decrypted and
// checked after the timer stops (CKKS: error normalized by max(1,|expected|)
// below 1e-2, SEAL's threshold; BGV: every slot exact mod p; a decryption that
// HElib refuses -- "too much noise" -- fails the check). Output files are
// written only when every repetition ran and passed, through a temporary file
// renamed into place; a failed check keeps the rows as <out>.invalid, exit 3;
// any other error exit 1, no output. --inject-mismatch-at=K (tests only)
// falsifies the expected value of repetition K.
//
// Configuration: helib/probe/helib_params.csv (make_params.py, from the
// probe). HElib takes no list of primes, only m, bits, c (and the CKKS
// precision or the BGV p); the primes it builds are compared with the
// recorded ones, and a difference stops the run.
//
// Operation boundaries (HElib's own API; NONE is the same computation as in
// SEAL, so the pilot reports each library's value without a ratio):
//   keygen       ContextBuilder::buildPtr (prime chain, algebra, tables) +
//                SecKey::GenSecKey(0, 2): secret key, public key and the
//                relinearization key s^2 -> s only. (HElib's default,
//                GenSecKey(), also builds s^3 -> s; SEAL builds s^2 only.)
//   encrypt      PubKey::Encrypt (public-key encryption, on a separate PubKey
//                object: SecKey overrides Encrypt with secret-key encryption)
//                of an EncodedPtxt encoded before t0; includes
//                HElib's conversion of the encoding to its DoubleCRT form.
//   decrypt      SecKey::Decrypt to the plaintext polynomial (ZZX), before
//                decoding: HElib's own check of the noise bound, then
//                CRT reconstruction to integer coefficients (BGV: reduced
//                mod p). SEAL's CKKS decrypt stops in NTT form.
//   decrypt_full SecKey::Decrypt to a Ptxt (also decodes): end-to-end API cost.
//   add_inplace  Ctxt::operator+= (no copy).
//   multiply     Ctxt::multLowLvl, without relinearization. HElib first
//                switches the inputs to the modulus it computes for the
//                product (noise management), then forms the tensor product.
//   relinearize  Ctxt::reLinearize on a pre-computed multLowLvl product
//                (drops small and special primes, then key switching).
//   rotate       EncryptedArray::rotate1D(ct, 0, 1): one automorphism by the
//                first generator, with ONE key-switching key (for that
//                generator only, as SEAL's step-1 Galois key), one call per
//                repetition. BGV: each of the two rows of N/2 slots is rotated
//                cyclically (as SEAL's rotate_rows). Direction: HElib +1
//                (SEAL rotates by +1 the other way; one automorphism either way).
//
// Usage:
//   bench_helib --scheme=CKKS --N=8192 --category=1 --operation=multiply \
//     --reps=100 --warmup=5 --inner-loop=100 \
//     --params=probe/helib_params.csv --out=X.csv --check-out=X_check.csv
#include <helib/helib.h>
#include <NTL/BasicThreadPool.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>

using namespace helib;
using Clock = std::chrono::steady_clock;
constexpr double CKKS_CORRECTNESS_THRESHOLD = 1e-2;  // = bench_seal.cpp

struct Args {
    std::string scheme, operation, params, out, check_out;
    int N = 0, category = 0, reps = 100, warmup = 5, inner_loop = 1, inject_mismatch_at = -1;
};
static std::string arg_value(const std::string &s) { return s.substr(s.find('=') + 1); }
static Args parse_args(int argc, char **argv) {
    Args a;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        auto is = [&](const char *p) { return s.rfind(p, 0) == 0; };
        if (is("--scheme=")) a.scheme = arg_value(s);
        else if (is("--N=")) a.N = std::stoi(arg_value(s));
        else if (is("--category=")) a.category = std::stoi(arg_value(s));
        else if (is("--operation=")) a.operation = arg_value(s);
        else if (is("--reps=")) a.reps = std::stoi(arg_value(s));
        else if (is("--warmup=")) a.warmup = std::stoi(arg_value(s));
        else if (is("--inner-loop=")) a.inner_loop = std::stoi(arg_value(s));
        else if (is("--params=")) a.params = arg_value(s);
        else if (is("--out=")) a.out = arg_value(s);
        else if (is("--check-out=")) a.check_out = arg_value(s);
        else if (is("--inject-mismatch-at=")) a.inject_mismatch_at = std::stoi(arg_value(s));
        else throw std::runtime_error("Unknown argument: " + s);
    }
    if (a.scheme.empty() || !a.N || !a.category || a.operation.empty() || a.out.empty() || a.check_out.empty() ||
        a.params.empty())
        throw std::runtime_error("Required: --scheme= --N= --category= --operation= --params= --out= --check-out=");
    if (a.scheme != "CKKS" && a.scheme != "BGV") throw std::runtime_error("HElib: CKKS or BGV only");
    if (a.inner_loop < 1 || a.reps < 1 || a.warmup < 0) throw std::runtime_error("bad --reps/--warmup/--inner-loop");
    static const std::string ops = " keygen encrypt decrypt decrypt_full add_inplace multiply relinearize rotate ";
    if (ops.find(" " + a.operation + " ") == std::string::npos) throw std::runtime_error("unknown --operation");
    return a;
}

// ---------- configuration from helib_params.csv ----------
struct Config { long m = 0, bits = 0, c = 0, param = 0; std::string small, ctxt, special; };
static std::vector<std::string> split_csv(const std::string &line) {
    std::vector<std::string> v; std::string cur; bool q = false;
    for (char ch : line) {
        if (ch == '"') q = !q;
        else if (ch == ',' && !q) { v.push_back(cur); cur.clear(); }
        else cur += ch;
    }
    v.push_back(cur);
    return v;
}
static Config load_config(const Args &a) {
    std::ifstream f(a.params);
    if (!f) throw std::runtime_error("Cannot read " + a.params);
    std::string line;
    std::getline(f, line);
    auto h = split_csv(line);
    auto col = [&](const std::string &n) {
        for (size_t i = 0; i < h.size(); i++) if (h[i] == n) return i;
        throw std::runtime_error("column " + n + " missing in " + a.params);
    };
    while (std::getline(f, line)) {
        auto v = split_csv(line);
        if (v[col("scheme")] == a.scheme && std::stoi(v[col("N")]) == a.N && std::stoi(v[col("category")]) == a.category) {
            Config c;
            c.m = std::stol(v[col("m")]); c.bits = std::stol(v[col("bits")]); c.c = std::stol(v[col("c")]);
            c.param = std::stol(v[col("param")]);
            c.small = v[col("small_primes")]; c.ctxt = v[col("ctxt_primes")]; c.special = v[col("special_primes")];
            if (c.m != 2L * a.N) throw std::runtime_error("m != 2N in " + a.params);
            return c;
        }
    }
    throw std::runtime_error("Configuration absent from " + a.params);
}

static std::string primes_of(const Context &ctx, const IndexSet &s) {
    std::ostringstream o;
    for (long i = s.first(); i <= s.last(); i = s.next(i)) o << (o.tellp() ? " " : "") << ctx.ithPrime(i);
    return o.str();
}
static std::unique_ptr<Context> make_context(const Args &a, const Config &c) {
    if (a.scheme == "CKKS")
        return std::unique_ptr<Context>(ContextBuilder<CKKS>().m(c.m).bits(c.bits).precision(c.param).c(c.c).buildPtr());
    return std::unique_ptr<Context>(ContextBuilder<BGV>().m(c.m).p(c.param).r(1).bits(c.bits).c(c.c).buildPtr());
}
static void check_primes(const Context &ctx, const Config &c, const std::string &where) {
    if (primes_of(ctx, ctx.getSmallPrimes()) != c.small || primes_of(ctx, ctx.getCtxtPrimes()) != c.ctxt ||
        primes_of(ctx, ctx.getSpecialPrimes()) != c.special)
        throw std::runtime_error(where + ": HElib built other primes than helib_params.csv records -- stopping");
}

struct Keys {
    std::unique_ptr<Context> ctx;
    std::unique_ptr<SecKey> sk;
    // PUBLIC-key encryption: HElib's SecKey overrides Encrypt with secret-key
    // encryption (also when called through a PubKey reference), so every
    // ciphertext is encrypted with this separate PubKey object, copied from
    // the secret key after every key-switching key exists (untimed).
    std::unique_ptr<PubKey> pk;
    bool ckks = true;
    long slots = 0, p = 0;
};
static void generate_keys(Keys &k, const Args &a, const Config &c) {
    k.ctx = make_context(a, c);
    k.sk.reset(new SecKey(*k.ctx));
    k.sk->GenSecKey(0, 2);  // relinearization key s^2 -> s only (as SEAL)
}
static void finish_keys(Keys &k, const Args &a, const Config &c) {
    check_primes(*k.ctx, c, "context");
    k.pk.reset(new PubKey(*k.sk));
    k.ckks = a.scheme == "CKKS";
    k.slots = k.ctx->getEA().size();
    k.p = k.ckks ? 0 : c.param;
}

// ---------- inputs (same values as bench_seal.cpp) ----------
static std::mt19937_64 rng(12345);
struct Fresh { std::unique_ptr<Ctxt> ct; std::vector<double> x; };

static void encode(const Keys &k, EncodedPtxt &e, const std::vector<double> &x) {
    const EncryptedArray &ea = k.ctx->getEA();
    if (k.ckks) { ea.encode(e, x); return; }
    std::vector<long> w(x.size());
    for (size_t i = 0; i < x.size(); i++) w[i] = std::lround(x[i]);
    ea.encode(e, w);
}
static Fresh fresh_ciphertext(const Keys &k) {
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    Fresh f;
    f.x.resize(k.slots);
    for (auto &v : f.x) v = k.ckks ? dist(rng) : double(rng() % 2);
    EncodedPtxt e;
    encode(k, e, f.x);
    f.ct.reset(new Ctxt(*k.pk));
    k.pk->Encrypt(*f.ct, e);
    return f;
}

// ---------- correctness (always, outside every timed region) ----------
// CKKS: largest error normalized by max(1,|expected|). BGV: number of slots
// whose value differs mod p. A decryption HElib refuses fails the check.
static double check_error(const Keys &k, const Ctxt &ct, const std::vector<double> &expect) {
    try {
        double w = 0;
        if (k.ckks) {
            Ptxt<CKKS> pt(*k.ctx);
            k.sk->Decrypt(pt, ct);
            for (long i = 0; i < k.slots; i++)
                w = std::max(w, std::abs(pt[i].real() - expect[i]) / std::max(1.0, std::abs(expect[i])));
        } else {
            Ptxt<BGV> pt(*k.ctx);
            k.sk->Decrypt(pt, ct);
            for (long i = 0; i < k.slots; i++) {
                const long got = NTL::conv<long>(NTL::ConstTerm(pt[i].getData())) % k.p;
                const long want = (std::llround(expect[i]) % k.p + k.p) % k.p;
                if ((got + k.p) % k.p != want) w += 1;
            }
        }
        return w;
    } catch (const std::exception &) {
        return 1e300;
    }
}
static bool passes(const Keys &k, double err) { return k.ckks ? err < CKKS_CORRECTNESS_THRESHOLD : err == 0; }

// rotation by +1 along the first dimension, complete vector
static std::vector<double> rotated(const Keys &k, const std::vector<double> &x) {
    const PAlgebra &zm = k.ctx->getZMStar();
    std::vector<double> e(x.size());
    for (long i = 0; i < k.slots; i++) e[zm.addCoord(0, i, 1)] = x[i];  // addCoord(dimension, slot, offset)
    return e;
}

// ---------- timed operations: elapsed ms for ONE repetition ----------
struct Result { double ms; std::unique_ptr<Ctxt> ct; std::vector<double> expect; std::function<double()> extra; };
static double ms(Clock::time_point t0, Clock::time_point t1) {
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

static Result time_keygen(const Args &a, const Config &c, Keys &out) {
    Keys k;
    auto t0 = Clock::now();
    generate_keys(k, a, c);
    auto t1 = Clock::now();
    finish_keys(k, a, c);
    // check: the keys just generated work (fresh input through encrypt -> decrypt)
    Fresh f = fresh_ciphertext(k);
    Result r{ms(t0, t1), std::move(f.ct), f.x, nullptr};
    out = std::move(k);
    return r;
}

static Result time_encrypt(const Keys &k, const Args &a) {
    std::vector<double> v(k.slots, k.ckks ? 0.5 : 1.0);  // bench_seal: CKKS 0.5, BGV 1 in every slot
    std::vector<EncodedPtxt> es(a.inner_loop);
    for (auto &e : es) encode(k, e, v);
    std::vector<std::unique_ptr<Ctxt>> cts(a.inner_loop);
    for (auto &ct : cts) ct.reset(new Ctxt(*k.pk));
    auto t0 = Clock::now();
    for (int i = 0; i < a.inner_loop; i++) k.pk->Encrypt(*cts[i], es[i]);
    auto t1 = Clock::now();
    return {ms(t0, t1) / a.inner_loop, std::move(cts.back()), v, nullptr};
}

static Result time_decrypt(const Keys &k, const Args &a, bool full) {
    std::vector<Fresh> in;
    in.reserve(a.inner_loop);
    for (int i = 0; i < a.inner_loop; i++) in.push_back(fresh_ciphertext(k));
    NTL::ZZX poly;
    auto t0 = Clock::now();
    if (full) {
        if (k.ckks) { Ptxt<CKKS> pt(*k.ctx); for (int i = 0; i < a.inner_loop; i++) k.sk->Decrypt(pt, *in[i].ct); }
        else        { Ptxt<BGV> pt(*k.ctx);  for (int i = 0; i < a.inner_loop; i++) k.sk->Decrypt(pt, *in[i].ct); }
    } else {
        for (int i = 0; i < a.inner_loop; i++) k.sk->Decrypt(poly, *in[i].ct);
    }
    auto t1 = Clock::now();
    Result r{ms(t0, t1) / a.inner_loop, std::move(in.back().ct), in.back().x, nullptr};
    if (!full) {
        // the polynomial computed at this boundary must itself decode to the input
        const double scaling = NTL::conv<double>(r.ct->getRatFactor());
        r.extra = [&k, poly, x = r.expect, scaling]() -> double {
            const EncryptedArray &ea = k.ctx->getEA();
            double w = 0;
            if (k.ckks) {
                std::vector<double> got;
                ea.getCx().decode(got, poly, scaling);
                for (long i = 0; i < k.slots; i++) w = std::max(w, std::abs(got[i] - x[i]) / std::max(1.0, std::abs(x[i])));
            } else {
                std::vector<long> got;
                ea.decode(got, poly);
                for (long i = 0; i < k.slots; i++)
                    if (((got[i] % k.p) + k.p) % k.p != (std::llround(x[i]) % k.p + k.p) % k.p) w += 1;
            }
            return w;
        };
    }
    return r;
}

static Result time_binary(const Keys &k, const Args &a, const std::string &op) {
    std::vector<Fresh> xs, ys;
    xs.reserve(a.inner_loop); ys.reserve(a.inner_loop);
    for (int i = 0; i < a.inner_loop; i++) { xs.push_back(fresh_ciphertext(k)); ys.push_back(fresh_ciphertext(k)); }
    if (op == "relinearize")  // untimed setup step, as in bench_seal
        for (int i = 0; i < a.inner_loop; i++) xs[i].ct->multLowLvl(*ys[i].ct);
    auto t0 = Clock::now();
    if (op == "add_inplace")   for (int i = 0; i < a.inner_loop; i++) *xs[i].ct += *ys[i].ct;
    else if (op == "multiply") for (int i = 0; i < a.inner_loop; i++) xs[i].ct->multLowLvl(*ys[i].ct);
    else                       for (int i = 0; i < a.inner_loop; i++) xs[i].ct->reLinearize();
    auto t1 = Clock::now();
    std::vector<double> e(k.slots);
    for (long i = 0; i < k.slots; i++)
        e[i] = op == "add_inplace" ? xs.back().x[i] + ys.back().x[i] : xs.back().x[i] * ys.back().x[i];
    return {ms(t0, t1) / a.inner_loop, std::move(xs.back().ct), e, nullptr};
}

static Result time_rotate(const Keys &k) {
    Fresh in = fresh_ciphertext(k);  // setup before t0, one rotation per repetition
    auto t0 = Clock::now();
    k.ctx->getEA().rotate1D(*in.ct, 0, 1);
    auto t1 = Clock::now();
    return {ms(t0, t1), std::move(in.ct), rotated(k, in.x), nullptr};
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
        std::remove(a.out.c_str());
        std::remove(a.check_out.c_str());
        Config c = load_config(a);
        const std::string &op = a.operation;
        const bool rotate = op == "rotate";
        if (NTL::AvailableThreads() != 1) throw std::runtime_error("NTL thread pool active: not single-threaded");

        Keys x;
        double gk_ms = 0;
        size_t gk_bytes = 0;
        if (op != "keygen") {
            generate_keys(x, a, c);
            if (rotate) {
                const long g = x.ctx->getZMStar().genToPow(0, 1);
                auto g0 = Clock::now();
                x.sk->GenKeySWmatrix(1, g, 0, 0);  // one key: the first generator only
                x.sk->setKeySwitchMap();
                gk_ms = ms(g0, Clock::now());
                std::ostringstream ks;
                x.sk->getKeySWmatrix(1, g, 0, 0).writeTo(ks);
                gk_bytes = ks.str().size();
            }
            finish_keys(x, a, c);  // checks the primes, copies the public key (with the rotation key)
        }

        std::ostringstream out, chk;
        out << "library,scheme,N,category,operation," << (rotate ? "galois_keygen_ms,galois_keys_size_bytes," : "batch_size,")
            << "iteration,latency_ms,status\n";
        chk << "library,scheme,N,category,operation,iteration,norm_error,correctness\n";
        const std::string ident = "HElib," + a.scheme + "," + std::to_string(a.N) + "," + std::to_string(a.category) + "," + op + ",";

        const int total = a.warmup + a.reps;
        for (int i = 0; i < total; i++) {
            Result r;
            Keys kx;
            if (op == "keygen")             r = time_keygen(a, c, kx);
            else if (op == "encrypt")       r = time_encrypt(x, a);
            else if (op == "decrypt")       r = time_decrypt(x, a, false);
            else if (op == "decrypt_full")  r = time_decrypt(x, a, true);
            else if (rotate)                r = time_rotate(x);
            else                            r = time_binary(x, a, op);
            const Keys &kk = op == "keygen" ? kx : x;
            if (i == a.inject_mismatch_at) for (auto &v : r.expect) v += 1.0;  // TESTS ONLY
            double err = check_error(kk, *r.ct, r.expect);
            if (r.extra && passes(kk, err)) err = std::max(err, r.extra());
            const bool ok = passes(kk, err);
            out << ident << (rotate ? std::to_string(gk_ms) + "," + std::to_string(gk_bytes) + "," : "1,") << i << ","
                << r.ms << "," << (i < a.warmup ? "warmup" : "measured") << "\n";
            chk << ident << i << "," << err << "," << (ok ? "correct" : "INCORRECT") << "\n";
            if (!ok) {
                write_atomically(a.out + ".invalid", out.str() + "# INVALID: correctness check failed at iteration " +
                                                         std::to_string(i) + "\n");
                write_atomically(a.check_out + ".invalid", chk.str());
                std::cerr << "FAILED: correctness check at iteration " << i << " (error " << err << ") -- no output written\n";
                return 3;
            }
        }
        write_atomically(a.check_out, chk.str());
        write_atomically(a.out, out.str());
        std::cout << "OK: wrote " << total << " rows to " << a.out << " (all " << total << " checks correct)\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << "\n";
        return 1;
    }
}
