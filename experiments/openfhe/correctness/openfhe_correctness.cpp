// openfhe_correctness.cpp — repeated correctness check of the operations that
// will be timed, for every configuration eligible for measurement (no timing).
//
// Input: ../probe/eligible_v2.csv (make_grid_v2.py): per eligible
// configuration, the request settings of openfhe_probe_v2 (variant, depth,
// prime sizes, SEAL's plaintext modulus), the operations SEAL measured there
// (= the operations to be timed) and the primes the probe obtained.
//
// For each configuration the context is rebuilt with exactly the probe's
// settings and its primes are compared with the probe's (primes_match). Then
// TRIALS independent trials are run; each trial generates NEW keys (key pair,
// relinearization key if relinearize is timed, rotation key if rotate is
// timed) and NEW random inputs, and checks every timed operation by
// decrypt-and-compare:
//   keygen      the trial's keys work: encrypt->decrypt of a fresh input is
//               correct (and relinearization, when timed, with these keys);
//   encrypt,    decrypt(encrypt(x)) == x;
//   decrypt
//   add         decrypt(x + y) == x + y;
//   multiply    decrypt(x * y), without relinearization;
//   relinearize decrypt(relinearize(x * y)) == x * y;
//   rotate      decrypt(rotate(x, 1)) == x shifted by one slot (the slots
//               whose source is unambiguous, as in the probe).
// Two input modes:
//   timing  the inputs of the SEAL timed operations (bench_seal.cpp
//           fresh_bfv_pair / fresh_ckks_pair): BFV/BGV slots in {0, 1},
//           CKKS slots uniform in [-1, 1];
//   full    BFV/BGV only: slots uniform over [-t/2, t/2), the harder case.
// BFV/BGV: exact comparison mod t (a trial passes when every slot matches).
// CKKS: error normalized by max(1, |expected|) below 1e-2, SEAL's
// CKKS_CORRECTNESS_THRESHOLD.
//
// Usage: openfhe_correctness <eligible_v2.csv> <out.csv> [trials=100]
#include "openfhe.h"
#include <cmath>
#include <fstream>
#include <map>
#include <random>
#include <sstream>

using namespace lbcrypto;

static std::mt19937_64 rng(20261018);

// SEAL's plaintext modulus per cell (same function as openfhe_probe_v2.cpp).
static uint64_t seal_t(uint32_t N, int cat) {
    if (N == 2048 && (cat == 1 || cat == 5)) return 12289;
    if (N == 4096 && cat == 5) return 40961;
    return N == 16384 ? 786433 : 1032193;
}
static SecurityLevel level(int cat) {
    return cat == 1 ? HEStd_128_classic : cat == 3 ? HEStd_192_classic : HEStd_256_classic;
}

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

static std::string primes_of(const std::shared_ptr<ILDCRTParams<BigInteger>> &p) {
    std::string s;
    if (p) for (auto &m : p->GetParams()) s += (s.empty() ? "" : " ") + m->GetModulus().ToString();
    return s;
}

// Same settings as openfhe_probe_v2.cpp for the given variant.
template <typename P>
static void key_switching(P &p, char v, uint32_t depth) {
    if (v == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(depth + 1); }
    if (v == 'C') p.SetKeySwitchTechnique(BV);
}
static CryptoContext<DCRTPoly> build(const std::string &scheme, uint32_t N, int cat, char v, uint32_t depth,
                                     uint32_t first, uint32_t mid) {
    if (scheme == "CKKS") {
        CCParams<CryptoContextCKKSRNS> p;
        p.SetRingDim(N); p.SetSecurityLevel(level(cat)); p.SetMultiplicativeDepth(depth);
        p.SetFirstModSize(first); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL);
        p.SetBatchSize(N / 2); key_switching(p, v, depth);
        return GenCryptoContext(p);
    }
    if (scheme == "BGV") {
        CCParams<CryptoContextBGVRNS> p;
        p.SetRingDim(N); p.SetSecurityLevel(level(cat)); p.SetMultiplicativeDepth(depth);
        p.SetPlaintextModulus(seal_t(N, cat));
        p.SetFirstModSize(first); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL);
        key_switching(p, v, depth);
        return GenCryptoContext(p);
    }
    CCParams<CryptoContextBFVRNS> p;
    p.SetRingDim(N); p.SetSecurityLevel(level(cat)); p.SetMultiplicativeDepth(depth);
    p.SetPlaintextModulus(seal_t(N, cat));
    if (v == 'B') p.SetScalingModSize(mid);
    key_switching(p, v, depth);
    return GenCryptoContext(p);
}

struct Tally { int trials = 0, passed = 0; double worst = 0; };  // worst: CKKS error or BFV/BGV bad slots

int main(int argc, char **argv) {
    std::ifstream in(argv[1]);
    std::ofstream out(argv[2]);
    const int trials = argc > 3 ? std::stoi(argv[3]) : 100;
    out << "scheme,N,category,variant,primes_match,input_mode,operation,trials,passed,worst,metric\n";
    std::string line; std::getline(in, line);
    std::vector<std::string> hdr = split_csv(line);
    while (std::getline(in, line)) {
        auto f = split_csv(line);
        std::map<std::string, std::string> r;
        for (size_t i = 0; i < hdr.size(); i++) r[hdr[i]] = f[i];
        const std::string scheme = r["scheme"];
        const uint32_t N = std::stoul(r["N"]), depth = std::stoul(r["depth"]);
        const int cat = std::stoi(r["category"]);
        const char v = r["variant"][0];
        std::set<std::string> ops; { std::stringstream ss(r["ops"]); std::string o; while (ss >> o) ops.insert(o); }

        auto cc = build(scheme, N, cat, v, depth, std::stoul(r["first_mod_bits"]), std::stoul(r["scaling_mod_bits"]));
        cc->Enable(PKE); cc->Enable(KEYSWITCH); cc->Enable(LEVELEDSHE);
        auto cp = std::dynamic_pointer_cast<CryptoParametersRNS>(cc->GetCryptoParameters());
        const bool match = primes_of(cc->GetElementParams()) == r["q_primes"] && primes_of(cp->GetParamsP()) == r["p_primes"];

        const bool ckks = scheme == "CKKS";
        const size_t slots = ckks ? N / 2 : N;
        const uint64_t t = ckks ? 0 : seal_t(N, cat);
        std::vector<std::string> modes = ckks ? std::vector<std::string>{"timing"} : std::vector<std::string>{"timing", "full"};
        for (const auto &mode : modes) {
            std::map<std::string, Tally> tally;
            for (int k = 0; k < trials; k++) {
                auto kp = cc->KeyGen();
                if (ops.count("relinearize")) cc->EvalMultKeyGen(kp.secretKey);
                if (ops.count("rotate")) cc->EvalRotateKeyGen(kp.secretKey, {1});
                std::map<std::string, double> bad;  // per operation: error / mismatching slots this trial

                auto dec = [&](const Ciphertext<DCRTPoly> &c) { Plaintext o; cc->Decrypt(kp.secretKey, c, &o); return o; };
                if (ckks) {
                    std::uniform_real_distribution<double> ud(-1.0, 1.0);
                    std::vector<double> x(slots), y(slots);
                    for (size_t i = 0; i < slots; i++) { x[i] = ud(rng); y[i] = ud(rng); }
                    auto ca = cc->Encrypt(kp.publicKey, cc->MakeCKKSPackedPlaintext(x));
                    auto cb = cc->Encrypt(kp.publicKey, cc->MakeCKKSPackedPlaintext(y));
                    auto err = [&](Plaintext pt, const std::vector<double> &e, size_t n) {
                        pt->SetLength(slots);
                        auto got = pt->GetRealPackedValue();
                        double w = 0;
                        for (size_t i = 0; i < n; i++) w = std::max(w, std::abs(got[i] - e[i]) / std::max(1.0, std::abs(e[i])));
                        return w;
                    };
                    bad["decrypt"] = err(dec(ca), x, slots);
                    std::vector<double> s(slots), m(slots), rot(slots);
                    for (size_t i = 0; i < slots; i++) { s[i] = x[i] + y[i]; m[i] = x[i] * y[i]; }
                    for (size_t i = 0; i + 1 < slots; i++) rot[i] = x[i + 1];
                    if (ops.count("add")) bad["add"] = err(dec(cc->EvalAdd(ca, cb)), s, slots);
                    if (ops.count("multiply") || ops.count("relinearize")) {
                        auto prod = cc->EvalMultNoRelin(ca, cb);
                        if (ops.count("multiply")) bad["multiply"] = err(dec(prod), m, slots);
                        if (ops.count("relinearize")) bad["relinearize"] = err(dec(cc->Relinearize(prod)), m, slots);
                    }
                    if (ops.count("rotate")) bad["rotate"] = err(dec(cc->EvalRotate(ca, 1)), rot, slots - 1);
                } else {
                    std::vector<int64_t> a(slots), b(slots);
                    for (size_t i = 0; i < slots; i++) {
                        if (mode == "timing") { a[i] = rng() % 2; b[i] = rng() % 2; }
                        else { a[i] = (int64_t)(rng() % t) - (int64_t)(t / 2); b[i] = (int64_t)(rng() % t) - (int64_t)(t / 2); }
                    }
                    auto ca = cc->Encrypt(kp.publicKey, cc->MakePackedPlaintext(a));
                    auto cb = cc->Encrypt(kp.publicKey, cc->MakePackedPlaintext(b));
                    auto mod = [&](__int128 z) { return (int64_t)(((z % (__int128)t) + t) % t); };
                    auto mism = [&](Plaintext pt, const std::vector<int64_t> &e, size_t n) {
                        auto got = pt->GetPackedValue();
                        double c = 0;
                        for (size_t i = 0; i < n; i++) if (mod(got[i]) != mod(e[i])) c++;
                        return c;
                    };
                    bad["decrypt"] = mism(dec(ca), a, slots);
                    std::vector<int64_t> s(slots), m(slots), rot(slots);
                    for (size_t i = 0; i < slots; i++) { s[i] = a[i] + b[i]; m[i] = mod((__int128)a[i] * b[i]); }
                    for (size_t i = 0; i + 1 < slots / 2; i++) rot[i] = a[i + 1];
                    if (ops.count("add")) bad["add"] = mism(dec(cc->EvalAdd(ca, cb)), s, slots);
                    if (ops.count("multiply") || ops.count("relinearize")) {
                        auto prod = cc->EvalMultNoRelin(ca, cb);
                        if (ops.count("multiply")) bad["multiply"] = mism(dec(prod), m, slots);
                        if (ops.count("relinearize")) bad["relinearize"] = mism(dec(cc->Relinearize(prod)), m, slots);
                    }
                    if (ops.count("rotate")) bad["rotate"] = mism(dec(cc->EvalRotate(ca, 1)), rot, slots / 2 - 1);
                }
                auto ok = [&](double w) { return ckks ? w < 1e-2 : w == 0; };
                bad["encrypt"] = bad["decrypt"];
                bad["keygen"] = std::max(bad["decrypt"], bad.count("relinearize") ? bad["relinearize"] : 0.0);
                for (const auto &op : ops) {
                    auto &T = tally[op];
                    T.trials++; T.passed += ok(bad[op]); T.worst = std::max(T.worst, bad[op]);
                }
            }
            for (const auto &op : ops) {
                const auto &T = tally[op];
                out << scheme << "," << N << "," << cat << "," << v << "," << (match ? "yes" : "NO") << "," << mode
                    << "," << op << "," << T.trials << "," << T.passed << "," << T.worst << ","
                    << (ckks ? "max_norm_error" : "max_mismatching_slots") << "\n";
            }
            out.flush();
            std::cerr << scheme << " " << N << "/" << cat << " " << v << " " << mode << " done\n";
        }
    }
}
