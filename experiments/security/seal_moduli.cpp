// Prints the exact coefficient-modulus primes SEAL 4.1.2 generates for each
// row of config/param_grid.csv (CoeffModulus::Create is deterministic), as
// the input of the Lattice Estimator runs (estimate_seal.py).
#include "seal/seal.h"
#include <fstream>
#include <iostream>
#include <sstream>
using namespace seal;
int main(int argc, char **argv) {
    std::ifstream grid(argv[1]);
    std::string line; std::getline(grid, line);  // header
    std::cout << "N,category,chain_bits,primes,log2_q\n";
    while (std::getline(grid, line)) {
        std::stringstream ss(line); std::string N, cat, sec, chain;
        std::getline(ss, N, ','); std::getline(ss, cat, ','); std::getline(ss, sec, ','); std::getline(ss, chain, ',');
        std::vector<int> bits; std::stringstream cs(chain); std::string tok;
        while (std::getline(cs, tok, '+')) {
            auto x = tok.find('*');
            if (x == std::string::npos) bits.push_back(std::stoi(tok));
            else for (int i = 0; i < std::stoi(tok.substr(x + 1)); i++) bits.push_back(std::stoi(tok.substr(0, x)));
        }
        auto primes = CoeffModulus::Create(std::stoul(N), bits);
        double log2q = 0; std::string ps;
        for (auto &p : primes) { log2q += std::log2(static_cast<double>(p.value())); ps += (ps.empty() ? "" : " ") + std::to_string(p.value()); }
        std::cout << N << "," << cat << "," << chain << "," << ps << "," << log2q << "\n";
    }
}
