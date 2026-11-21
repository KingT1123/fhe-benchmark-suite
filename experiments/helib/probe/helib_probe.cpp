// helib_probe.cpp -- what HElib 2.2.0 actually builds for a requested
// configuration, before any timing (as openfhe/probe/openfhe_probe_v2.cpp for
// OpenFHE). HElib does not take a list of primes: it takes the ring (m = 2N),
// the bit size of the ciphertext modulus chain (bits) and the number of
// key-switching columns (c), and chooses its primes itself. For each
// candidate this prints one CSV row:
//   the primes of each set (small, ciphertext, special), their bit sizes, the
//   modulus of a fresh ciphertext (log2 Q), the special primes (log2 P), their
//   total, HElib's own security estimate (Context::securityLevel), the slot
//   structure (generators, orders), and a functional test: fresh x times fresh
//   y, multLowLvl + reLinearize, repeated up to 3 levels, decrypted and
//   checked (CKKS: max error normalized by max(1,|expected|) < 1e-2, the SEAL
//   threshold; BGV: every slot exact mod p), with the remaining capacity and
//   the number of primes after each step; and the CKKS precision achieved
//   (-log2 of the max error) on a fresh ciphertext and after each level.
// Usage: helib_probe CKKS|BGV <bits> <c> [precision|p]
#include <helib/helib.h>
#include <NTL/BasicThreadPool.h>
#include <cmath>
#include <iostream>
#include <random>
#include <sstream>

using namespace helib;

static std::string primes(const Context &ctx, const IndexSet &s) {
    std::ostringstream o;
    for (long i = s.first(); i <= s.last(); i = s.next(i)) o << (o.tellp() ? " " : "") << ctx.ithPrime(i);
    return o.str();
}
static double log2set(const Context &ctx, const IndexSet &s) { return s.card() ? ctx.logOfProduct(s) / std::log(2.0) : 0; }
static std::string bits_of(const Context &ctx, const IndexSet &s) {
    std::ostringstream o;
    for (long i = s.first(); i <= s.last(); i = s.next(i))
        o << (o.tellp() ? "+" : "") << std::lround(std::log2(double(ctx.ithPrime(i))));
    return o.str();
}

int main(int argc, char **argv) {
    if (argc < 4) { std::cerr << "usage: helib_probe CKKS|BGV bits c [precision|p]\n"; return 2; }
    const std::string scheme = argv[1];
    const long bits = std::stol(argv[2]), c = std::stol(argv[3]);
    const long m = 16384;  // N = 8192
    const bool ckks = scheme == "CKKS";
    const long extra = argc > 4 ? std::stol(argv[4]) : (ckks ? 20 : 1032193);  // CKKS precision / BGV p (= SEAL's t)
    try {
        Context ctx = ckks ? ContextBuilder<CKKS>().m(m).bits(bits).precision(extra).c(c).build()
                           : ContextBuilder<BGV>().m(m).p(extra).r(1).bits(bits).c(c).build();
        SecKey sk(ctx);
        sk.GenSecKey(0, 2);  // relinearization key s^2 -> s only (as SEAL)
        // rotation key: ONE key-switching matrix, for the first generator
        // (as SEAL's step-1 Galois key), generated before the public key is copied
        sk.GenKeySWmatrix(1, ctx.getZMStar().genToPow(0, 1), 0, 0);
        sk.setKeySwitchMap();
        // PUBLIC-key encryption: SecKey overrides Encrypt with secret-key
        // encryption (also through a PubKey reference), so encrypt with a
        // separate PubKey object, copied after every key exists
        const PubKey pk(sk);
        const EncryptedArray &ea = ctx.getEA();
        const PAlgebra &zm = ctx.getZMStar();
        std::ostringstream gens;
        for (long i = 0; i < zm.numOfGens(); i++)
            gens << (i ? ";" : "") << zm.ZmStarGen(i) << ":" << zm.OrderOf(i) << (zm.SameOrd(i) ? "" : "(bad)");
        const long nslots = ea.size();

        std::mt19937_64 rng(12345);
        std::uniform_real_distribution<double> u(-1.0, 1.0);
        auto fresh = [&](std::vector<double> &x) {
            Ctxt ct(pk);
            x.resize(nslots);
            if (ckks) { for (auto &v : x) v = u(rng); Ptxt<CKKS> p(ctx, x); pk.Encrypt(ct, p); }
            else { std::vector<long> w(nslots); for (long i = 0; i < nslots; i++) { w[i] = long(rng() % 2); x[i] = double(w[i]); }
                   Ptxt<BGV> p(ctx, w); pk.Encrypt(ct, p); }
            return ct;
        };
        auto err = [&](const Ctxt &ct, const std::vector<double> &e) -> double {
          try {
            double w = 0;
            if (ckks) { Ptxt<CKKS> p(ctx); sk.Decrypt(p, ct);
                        for (long i = 0; i < nslots; i++) w = std::max(w, std::abs(p[i].real() - e[i]) / std::max(1.0, std::abs(e[i]))); }
            else { Ptxt<BGV> p(ctx); sk.Decrypt(p, ct);
                   for (long i = 0; i < nslots; i++) {
                       const long t = extra, g = NTL::conv<long>(NTL::ConstTerm(p[i].getData())) % t;
                       const long want = (std::llround(e[i]) % t + t) % t;
                       if ((g % t + t) % t != want) w += 1; } }
            return w;
          } catch (const std::exception &) { return 1e300; }  // HElib refuses to decrypt: too much noise
        };
        auto ok = [&](double e) { return ckks ? e < 1e-2 : e == 0; };

        std::vector<double> x, y;
        Ctxt acc = fresh(x);
        const double e0 = err(acc, x);
        const long fresh_primes = acc.getPrimeSet().card();
        const double fresh_logq = log2set(ctx, acc.getPrimeSet());
        std::ostringstream lv;
        lv << "fresh:cap=" << std::lround(acc.capacity()) << ",primes=" << fresh_primes
           << ",err=" << e0 << (ckks ? ",prec=" + std::to_string(-std::log2(e0)) : "");
        long depth_ok = 0;
        for (int d = 1; d <= 3; d++) {
            Ctxt b = fresh(y);
            const long before = acc.getPrimeSet().card();
            acc.multLowLvl(b);
            const long after_mult = acc.getPrimeSet().card();
            acc.reLinearize();
            for (long i = 0; i < nslots; i++) x[i] *= y[i];
            const double e = err(acc, x);
            lv << " | L" << d << ":primes " << before << "->" << after_mult << "->" << acc.getPrimeSet().card()
               << ",cap=" << std::lround(acc.capacity()) << ",err=" << e << (ckks ? ",prec=" + std::to_string(-std::log2(std::max(e, 1e-300))) : "")
               << (ok(e) ? ",OK" : ",FAIL");
            if (ok(e) && depth_ok == d - 1) depth_ok = d;
        }

        // rotation along dimension 0 by +1 with that one key: direction checked against addCoord
        std::vector<double> r;
        Ctxt rc = fresh(r);
        ea.rotate1D(rc, 0, 1);
        std::vector<double> want(nslots);
        for (long i = 0; i < nslots; i++) want[zm.addCoord(0, i, 1)] = r[i];  // addCoord(dimension, slot, offset)
        const double erot = err(rc, want);

        const IndexSet &sp = ctx.getSmallPrimes(), &cp = ctx.getCtxtPrimes(), &kp = ctx.getSpecialPrimes();
        std::cout << "scheme,m,N,bits_req,c,param,slots,gens,small_primes,ctxt_primes,special_primes,"
                     "small_bits,ctxt_bits,special_bits,fresh_ctxt_primes,log2Q_fresh,log2P_special,log2QP_ctxt_special,"
                     "log2_all,helib_security,ntl_threads,depth_ok,rotate1D_dim0_plus1_err,levels\n";
        std::cout << scheme << "," << m << "," << zm.getPhiM() << "," << bits << "," << c << "," << extra << ","
                  << nslots << "," << gens.str() << "," << primes(ctx, sp) << "," << primes(ctx, cp) << ","
                  << primes(ctx, kp) << "," << bits_of(ctx, sp) << "," << bits_of(ctx, cp) << "," << bits_of(ctx, kp) << ","
                  << fresh_primes << "," << fresh_logq << "," << log2set(ctx, kp) << ","
                  << log2set(ctx, cp | kp) << "," << log2set(ctx, sp | cp | kp) << "," << ctx.securityLevel() << ","
                  << NTL::AvailableThreads() << "," << depth_ok << "," << erot << ",\"" << lv.str() << "\"\n";
    } catch (const std::exception &e) {
        std::cout << "ERROR," << scheme << "," << bits << "," << c << "," << e.what() << "\n";
        return 1;
    }
    return 0;
}
