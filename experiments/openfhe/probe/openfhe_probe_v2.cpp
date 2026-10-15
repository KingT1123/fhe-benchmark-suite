// openfhe_probe_v2.cpp — round-7 correspondence probe (no timing).
//
// For every SEAL configuration (config/param_grid.csv: 12 rows x BFV/BGV/CKKS)
// and every candidate OpenFHE variant, with OpenFHE's security check ON
// (HEStd_128/192/256_classic, never HEStd_NotSet), fixed ring dimension N,
// SEAL's plaintext modulus t (BFV/BGV) and SEAL's prime sizes:
//   1. builds the context and exports the ACTUAL primes generated -- the
//      ciphertext primes Q and the key-switching primes P -- or the rejection
//      reason, classified as "security" (OpenFHE's security check) or
//      "parameter-generation" (any other failure);
//   2. for every accepted context, runs a functional check of each operation
//      the benchmark needs -- key generation (incl. relinearization and
//      rotation keys), encryption, decryption, addition, multiplication,
//      relinearization, rotation, and for CKKS rescaling -- on random inputs,
//      and records ok / wrong result / unsupported (exception) per step.
//      BFV/BGV: exact comparison mod t. CKKS: error normalized by
//      max(1,|expected|) < 1e-2, the threshold of the SEAL campaign; the
//      effective scale, level and number of RNS towers are recorded.
// Variants: A = OpenFHE default key switching (hybrid for CKKS/BGV, BV for
// BFV); B = hybrid with one ciphertext prime per digit (single-prime-sized
// P, SEAL's design); C = BV (no P).
//
// Usage: openfhe_probe_v2 <param_grid.csv> <params_out.csv> <functional_out.csv>
#include "openfhe.h"
#include <cmath>
#include <fstream>
#include <random>
#include <sstream>

using namespace lbcrypto;

struct Row { uint32_t N; int cat; std::vector<int> chain; int depth; };

static std::vector<int> parse_chain(const std::string &c) {
    std::vector<int> bits; std::stringstream cs(c); std::string tok;
    while (std::getline(cs, tok, '+')) {
        auto x = tok.find('*');
        if (x == std::string::npos) bits.push_back(std::stoi(tok));
        else for (int i = 0; i < std::stoi(tok.substr(x + 1)); i++) bits.push_back(std::stoi(tok.substr(0, x)));
    }
    return bits;
}

// SEAL's plaintext modulus per cell (bench_seal.cpp bfv_bgv_plain_modulus;
// results/final/seal_config_metadata.csv).
static uint64_t seal_t(uint32_t N, int cat) {
    if (N == 2048 && (cat == 1 || cat == 5)) return 12289;
    if (N == 4096 && cat == 5) return 40961;
    return N == 16384 ? 786433 : 1032193;
}
static SecurityLevel level(int cat) {
    return cat == 1 ? HEStd_128_classic : cat == 3 ? HEStd_192_classic : HEStd_256_classic;
}
static std::string clean(std::string s) {
    for (auto &ch : s) if (ch == '"' || ch == '\n' || ch == ',') ch = ' ';
    auto p = s.find("():");
    return (p == std::string::npos ? s : s.substr(p + 3)).substr(0, 200);
}
static std::string primes_of(const std::shared_ptr<ILDCRTParams<BigInteger>> &p, double &log2sum) {
    std::string s; log2sum = 0;
    if (!p) return s;
    for (auto &m : p->GetParams()) {
        log2sum += std::log2(m->GetModulus().ConvertToDouble());
        s += (s.empty() ? "" : " ") + m->GetModulus().ToString();
    }
    return s;
}

static std::mt19937_64 rng(20261013);
static std::ofstream F;  // functional output

static void frow(const std::string &id, const std::string &step, const std::string &status,
                 const std::string &detail = "") {
    F << id << "," << step << "," << status << ",\"" << detail << "\"\n";
}

// Run fn; record an exception as "unsupported" with its message.
template <typename Fn>
static bool step(const std::string &id, const std::string &name, Fn fn) {
    try { fn(); return true; }
    catch (const std::exception &e) { frow(id, name, "unsupported", clean(e.what())); return false; }
}

static void check_int(const std::string &id, const std::string &name, const Plaintext &pt,
                      const std::vector<int64_t> &expect, uint64_t t, size_t n) {
    auto v = pt->GetPackedValue();
    size_t bad = 0;
    for (size_t i = 0; i < n; i++) {
        int64_t a = ((v[i] % (int64_t)t) + (int64_t)t) % (int64_t)t;
        int64_t b = ((expect[i] % (int64_t)t) + (int64_t)t) % (int64_t)t;
        if (a != b) bad++;
    }
    frow(id, name, bad ? "wrong" : "ok", "mismatching slots=" + std::to_string(bad) + "/" + std::to_string(n));
}

static void check_real(const std::string &id, const std::string &name, Plaintext pt,
                       const std::vector<double> &expect, const Ciphertext<DCRTPoly> &ct) {
    pt->SetLength(expect.size());
    auto v = pt->GetRealPackedValue();
    double worst = 0, abs_worst = 0;
    for (size_t i = 0; i < expect.size(); i++) {
        double e = std::abs(v[i] - expect[i]);
        abs_worst = std::max(abs_worst, e);
        worst = std::max(worst, e / std::max(1.0, std::abs(expect[i])));
    }
    std::ostringstream d;
    d << "max_abs_error=" << abs_worst << " norm_error=" << worst
      << " log2_scale=" << std::log2(ct->GetScalingFactor()) << " level=" << ct->GetLevel()
      << " towers=" << ct->GetElements()[0].GetNumOfElements();
    frow(id, name, worst < 1e-2 ? "ok" : "wrong", d.str());
}

template <typename P>
static void probe(std::ofstream &out, const std::string &scheme, const Row &r, char v,
                  const std::string &request, P &params) {
    std::ostringstream idss;
    idss << scheme << "," << r.N << "," << r.cat << "," << v;
    std::string id = idss.str();
    CryptoContext<DCRTPoly> cc;
    try {
        cc = GenCryptoContext(params);
    } catch (const std::exception &e) {
        std::string msg = clean(e.what());
        bool sec = msg.find("HE standards") != std::string::npos ||
                   msg.find("security requirement") != std::string::npos;
        out << id << ",\"" << request << "\",rejected," << (sec ? "security" : "parameter-generation")
            << ",,,,,,\"" << msg << "\"\n";
        return;
    }
    auto cp = std::dynamic_pointer_cast<CryptoParametersRNS>(cc->GetCryptoParameters());
    double lq = 0, lp = 0;
    std::string q = primes_of(cc->GetElementParams(), lq);
    std::string p = primes_of(cp->GetParamsP(), lp);
    out << id << ",\"" << request << "\",accepted,," << cc->GetRingDimension() << ",\"" << q << "\",\""
        << p << "\"," << lq << "," << lq + lp << ",\n";
    out.flush();

    // ---- functional check ----
    cc->Enable(PKE); cc->Enable(KEYSWITCH); cc->Enable(LEVELEDSHE);
    const bool ckks = scheme == "CKKS";
    const size_t slots = ckks ? r.N / 2 : r.N;
    const uint64_t t = ckks ? 0 : seal_t(r.N, r.cat);
    KeyPair<DCRTPoly> kp;
    if (!step(id, "keygen", [&] { kp = cc->KeyGen(); })) return;
    frow(id, "keygen", "ok");
    bool relin_keys = step(id, "relin_keygen", [&] { cc->EvalMultKeyGen(kp.secretKey); });
    if (relin_keys) frow(id, "relin_keygen", "ok");
    bool rot_keys = step(id, "rotation_keygen", [&] { cc->EvalRotateKeyGen(kp.secretKey, {1}); });
    if (rot_keys) frow(id, "rotation_keygen", "ok");

    std::vector<int64_t> a(slots), b(slots);
    std::vector<double> x(slots), y(slots);
    std::uniform_real_distribution<double> ud(-1.0, 1.0);
    for (size_t i = 0; i < slots; i++) {
        if (ckks) { x[i] = ud(rng); y[i] = ud(rng); }
        else { a[i] = (int64_t)(rng() % t) - (int64_t)(t / 2); b[i] = (int64_t)(rng() % t) - (int64_t)(t / 2); }
    }
    Plaintext pa, pb;
    Ciphertext<DCRTPoly> ca, cb;
    if (!step(id, "encrypt", [&] {
            pa = ckks ? cc->MakeCKKSPackedPlaintext(x) : cc->MakePackedPlaintext(a);
            pb = ckks ? cc->MakeCKKSPackedPlaintext(y) : cc->MakePackedPlaintext(b);
            ca = cc->Encrypt(kp.publicKey, pa); cb = cc->Encrypt(kp.publicKey, pb); })) return;
    frow(id, "encrypt", "ok", ckks ? "log2_scale=" + std::to_string(std::log2(ca->GetScalingFactor())) +
                                         " level=" + std::to_string(ca->GetLevel()) +
                                         " towers=" + std::to_string(ca->GetElements()[0].GetNumOfElements())
                                   : "t=" + std::to_string(t));
    auto dec = [&](const Ciphertext<DCRTPoly> &c) { Plaintext o; cc->Decrypt(kp.secretKey, c, &o); return o; };

    step(id, "decrypt", [&] {
        if (ckks) check_real(id, "decrypt", dec(ca), x, ca); else check_int(id, "decrypt", dec(ca), a, t, slots); });
    step(id, "add", [&] {
        auto c = cc->EvalAdd(ca, cb);
        if (ckks) { std::vector<double> e(slots); for (size_t i = 0; i < slots; i++) e[i] = x[i] + y[i];
                    check_real(id, "add", dec(c), e, c); }
        else { std::vector<int64_t> e(slots); for (size_t i = 0; i < slots; i++) e[i] = a[i] + b[i];
               check_int(id, "add", dec(c), e, t, slots); } });

    std::vector<double> xy(slots); std::vector<int64_t> ab(slots);
    for (size_t i = 0; i < slots; i++) {
        if (ckks) xy[i] = x[i] * y[i];
        else ab[i] = (int64_t)(((__int128)(a[i] % (int64_t)t + (int64_t)t) * (b[i] % (int64_t)t + (int64_t)t)) % t);
    }
    Ciphertext<DCRTPoly> prod;
    if (step(id, "multiply", [&] { prod = cc->EvalMultNoRelin(ca, cb); })) {
        step(id, "multiply", [&] {
            if (ckks) check_real(id, "multiply", dec(prod), xy, prod); else check_int(id, "multiply", dec(prod), ab, t, slots); });
        if (relin_keys && step(id, "relinearize", [&] {
                auto rl = cc->Relinearize(prod);
                if (ckks) check_real(id, "relinearize", dec(rl), xy, rl);
                else check_int(id, "relinearize", dec(rl), ab, t, slots);
                if (ckks) step(id, "rescale", [&] {
                    auto rs = cc->Rescale(rl); check_real(id, "rescale", dec(rs), xy, rs); });
            })) {}
    }
    if (rot_keys) step(id, "rotate", [&] {
        auto c = cc->EvalRotate(ca, 1);
        // compare the slots whose rotated source is unambiguous: within the
        // first row for BFV/BGV (two rows of N/2), all but the last for CKKS
        size_t n = ckks ? slots - 1 : slots / 2 - 1;
        if (ckks) { std::vector<double> e(slots); for (size_t i = 0; i + 1 < slots; i++) e[i] = x[i + 1];
                    e.resize(n); auto o = dec(c); check_real(id, "rotate", o, e, c); }
        else { std::vector<int64_t> e(slots); for (size_t i = 0; i < n; i++) e[i] = a[i + 1];
               check_int(id, "rotate", dec(c), e, t, n); } });
    F.flush();
}

int main(int argc, char **argv) {
    std::ifstream grid(argv[1]);
    std::ofstream out(argv[2]);
    F.open(argv[3]);
    std::string line; std::getline(grid, line);
    std::vector<Row> rows;
    while (std::getline(grid, line)) {
        std::stringstream ss(line); std::string N, cat, sec, chain, logq, depth;
        std::getline(ss, N, ','); std::getline(ss, cat, ','); std::getline(ss, sec, ',');
        std::getline(ss, chain, ','); std::getline(ss, logq, ','); std::getline(ss, depth, ',');
        rows.push_back({(uint32_t)std::stoul(N), std::stoi(cat), parse_chain(chain), std::stoi(depth)});
    }
    out << "scheme,N,category,variant,request,status,rejection_type,ring_dim,q_primes,p_primes,log2_q,log2_qp,error\n";
    F << "scheme,N,category,variant,step,status,detail\n";
    for (auto &r : rows) {
        int first = r.chain.front();
        int mid = r.chain.size() >= 3 ? r.chain[1] : first;
        int first_ok = std::max(first, mid);  // OpenFHE requires firstModSize >= scalingModSize
        uint32_t depth = (uint32_t)r.depth, nq = depth + 1;
        for (char v : {'A', 'B', 'C'}) {
            auto ks = [&](auto &p) {
                if (v == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(nq); }
                if (v == 'C') p.SetKeySwitchTechnique(BV);
            };
            std::string ksname = v == 'B' ? " hybrid dnum=" + std::to_string(nq) : v == 'C' ? " BV" : " default";
            {
                CCParams<CryptoContextCKKSRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetFirstModSize(first_ok); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL);
                p.SetBatchSize(r.N / 2); ks(p);
                probe(out, "CKKS", r, v, "depth=" + std::to_string(depth) + " firstModSize=" + std::to_string(first_ok) +
                      " scalingModSize=" + std::to_string(mid) + " FIXEDMANUAL" + ksname, p);
            }
            {
                CCParams<CryptoContextBGVRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetPlaintextModulus(seal_t(r.N, r.cat));
                p.SetFirstModSize(first_ok); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL); ks(p);
                probe(out, "BGV", r, v, "depth=" + std::to_string(depth) + " t=" + std::to_string(seal_t(r.N, r.cat)) +
                      " firstModSize=" + std::to_string(first_ok) + " scalingModSize=" + std::to_string(mid) +
                      " FIXEDMANUAL" + ksname, p);
            }
            {
                CCParams<CryptoContextBFVRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetPlaintextModulus(seal_t(r.N, r.cat));
                if (v == 'B') p.SetScalingModSize(mid);
                ks(p);
                probe(out, "BFV", r, v, "depth=" + std::to_string(depth) + " t=" + std::to_string(seal_t(r.N, r.cat)) +
                      (v == 'B' ? " scalingModSize=" + std::to_string(mid) : " chain=automatic") + ksname, p);
            }
        }
    }
}
