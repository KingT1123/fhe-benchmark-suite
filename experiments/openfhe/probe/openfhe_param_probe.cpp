// openfhe_param_probe.cpp — builds, in OpenFHE, the closest equivalent of
// every SEAL configuration of config/param_grid.csv (3 schemes x 12 rows) and
// records what OpenFHE actually produces, to ground the SEAL/OpenFHE
// correspondence grid in facts rather than assumptions. No timing.
//
// For each (scheme, N, category) it requests:
//   * ring dimension N, fixed (SetRingDim);
//   * OpenFHE's own security check for the matching level
//     (HEStd_128/192/256_classic), never HEStd_NotSet: if OpenFHE rejects the
//     configuration, that is recorded, not bypassed;
//   * BFV/BGV: SEAL's plaintext modulus t for that cell;
//   * the chain: CKKS and BGV with FIXEDMANUAL scaling, first-modulus size and
//     scaling-modulus size taken from SEAL's chain (first data prime, middle
//     primes); BFV builds its chain automatically from the depth (OpenFHE
//     offers no explicit prime list for BFV);
//   * multiplicative depth = the grid's depth.
// It prints one CSV row per attempt: accepted or the exception text, the ring
// dimension obtained, the bit sizes of the ciphertext primes (Q) and of the
// key-switching primes (P), log2 Q and log2 QP.
//
// Usage: openfhe_param_probe <param_grid.csv> <seal_moduli.csv> > probe.csv
#include "openfhe.h"
#include <cmath>
#include <fstream>
#include <map>
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

// SEAL's plaintext modulus per cell (bench_seal.cpp's bfv_bgv_plain_modulus,
// values confirmed in results/final/seal_config_metadata.csv).
static uint64_t seal_t(uint32_t N, int cat) {
    if (N == 2048 && (cat == 1 || cat == 5)) return 12289;
    if (N == 4096 && cat == 5) return 40961;
    return N == 16384 ? 786433 : 1032193;
}

static SecurityLevel level(int cat) {
    return cat == 1 ? HEStd_128_classic : cat == 3 ? HEStd_192_classic : HEStd_256_classic;
}

static std::string bits_of(const std::shared_ptr<ILDCRTParams<BigInteger>> &p, double &log2sum) {
    std::string s; log2sum = 0;
    for (auto &m : p->GetParams()) {
        double b = std::log2(m->GetModulus().ConvertToDouble());
        log2sum += b;
        s += (s.empty() ? "" : " ") + std::to_string(static_cast<int>(std::round(b)));
    }
    return s;
}

template <typename P>
static void report(const std::string &scheme, const Row &r, const std::string &request, P &params) {
    std::cout << scheme << "," << r.N << "," << r.cat << ",\"" << request << "\",";
    try {
        auto cc = GenCryptoContext(params);
        auto cp = std::dynamic_pointer_cast<CryptoParametersRNS>(cc->GetCryptoParameters());
        double lq = 0, lp = 0;
        std::string q = bits_of(cc->GetElementParams(), lq);
        std::string p = cp->GetParamsP() ? bits_of(cp->GetParamsP(), lp) : "";
        std::cout << "accepted," << cc->GetRingDimension() << ",\"" << q << "\",\"" << p << "\","
                  << lq << "," << lq + lp << ",\n";
    } catch (const std::exception &e) {
        std::string msg = e.what();
        for (auto &ch : msg) if (ch == '"' || ch == '\n' || ch == ',') ch = ' ';
        std::cout << "rejected,,,,,,\"" << msg.substr(0, 300) << "\"\n";
    }
}

int main(int argc, char **argv) {
    std::ifstream grid(argv[1]);
    std::string line; std::getline(grid, line);
    std::vector<Row> rows;
    while (std::getline(grid, line)) {
        std::stringstream ss(line); std::string N, cat, sec, chain, logq, depth;
        std::getline(ss, N, ','); std::getline(ss, cat, ','); std::getline(ss, sec, ',');
        std::getline(ss, chain, ','); std::getline(ss, logq, ','); std::getline(ss, depth, ',');
        rows.push_back({static_cast<uint32_t>(std::stoul(N)), std::stoi(cat), parse_chain(chain), std::stoi(depth)});
    }
    std::cout << "scheme,N,category,request,status,ring_dim,q_prime_bits,p_prime_bits,log2_q,log2_qp,error\n";
    // Variants per scheme (the security check is ON in every one):
    //   A  OpenFHE defaults for key switching (HYBRID for CKKS/BGV, BV for BFV)
    //   B  HYBRID with one Q prime per digit (numLargeDigits = #Q primes), so
    //      the key-switching modulus P is about one prime -- SEAL's design
    //   C  BV key switching (no extra P modulus)
    // CKKS/BGV request SEAL's prime sizes (first data prime; middle primes),
    // with firstModSize raised to scalingModSize where OpenFHE requires
    // first >= scaling. BFV variant B also requests SEAL's middle prime size
    // as its CRT prime size (scalingModSize).
    for (auto &r : rows) {
        int first = r.chain.front();
        int mid = r.chain.size() >= 3 ? r.chain[1] : first;
        int first_ok = std::max(first, mid);
        uint32_t depth = static_cast<uint32_t>(r.depth);
        uint32_t nq = depth + 1;  // Q primes with FIXEDMANUAL: first + depth scaling primes
        for (char v : {'A', 'B', 'C'}) {
            std::ostringstream base;
            base << v << ": depth=" << depth;
            {
                CCParams<CryptoContextCKKSRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetFirstModSize(first_ok); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL);
                p.SetBatchSize(r.N / 2);
                if (v == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(nq); }
                if (v == 'C') p.SetKeySwitchTechnique(BV);
                std::ostringstream req; req << base.str() << " firstModSize=" << first_ok
                    << " scalingModSize=" << mid << " FIXEDMANUAL"
                    << (v == 'B' ? " HYBRID dnum=" + std::to_string(nq) : v == 'C' ? " BV" : " default-HYBRID");
                report("CKKS", r, req.str(), p);
            }
            {
                CCParams<CryptoContextBGVRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetPlaintextModulus(seal_t(r.N, r.cat));
                p.SetFirstModSize(first_ok); p.SetScalingModSize(mid); p.SetScalingTechnique(FIXEDMANUAL);
                if (v == 'B') { p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(nq); }
                if (v == 'C') p.SetKeySwitchTechnique(BV);
                std::ostringstream req; req << base.str() << " t=" << seal_t(r.N, r.cat)
                    << " firstModSize=" << first_ok << " scalingModSize=" << mid << " FIXEDMANUAL"
                    << (v == 'B' ? " HYBRID dnum=" + std::to_string(nq) : v == 'C' ? " BV" : " default-HYBRID");
                report("BGV", r, req.str(), p);
            }
            {
                CCParams<CryptoContextBFVRNS> p;
                p.SetRingDim(r.N); p.SetSecurityLevel(level(r.cat)); p.SetMultiplicativeDepth(depth);
                p.SetPlaintextModulus(seal_t(r.N, r.cat));
                if (v == 'B') { p.SetScalingModSize(mid); p.SetKeySwitchTechnique(HYBRID); p.SetNumLargeDigits(nq); }
                if (v == 'C') p.SetKeySwitchTechnique(BV);
                std::ostringstream req; req << base.str() << " t=" << seal_t(r.N, r.cat)
                    << (v == 'B' ? " scalingModSize=" + std::to_string(mid) + " HYBRID dnum=" + std::to_string(nq)
                        : v == 'C' ? " chain=automatic BV" : " chain=automatic default-BV");
                report("BFV", r, req.str(), p);
            }
        }
    }
}
