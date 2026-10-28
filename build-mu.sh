#!/bin/bash
# Compila o Mu seguindo o README (seção "Compilation of the software stack").
# Rode com o seu usuário (não como root) em cada um dos 4 nós, depois que o
# setup terminar:   /local/repository/build-mu.sh
# O README clona osdi2020-no-152/dory (repositório que não existe mais); o
# mesmo código está em LPD-EPFL/mu, que o profile clona em /local/mu.
set -e
MU="${MU_DIR:-/local/mu}"
cd "$MU"

conan profile new default --detect >/dev/null 2>&1 || true
conan profile update settings.compiler.libcxx=libstdc++11 default

./build.py crash-consensus
crash-consensus/libgen/export.sh gcc-release
crash-consensus/demo/using_conan_fully/build.sh gcc-release
crash-consensus/experiments/build.sh
crash-consensus/experiments/liquibook/build.sh

LIB="$MU/crash-consensus/experiments/exported"
grep -q "$LIB" ~/.bashrc || echo "export LD_LIBRARY_PATH=$LIB:\$LD_LIBRARY_PATH" >> ~/.bashrc
grep -q "/local/rdma.env" ~/.bashrc || echo "source /local/rdma.env 2>/dev/null" >> ~/.bashrc
echo "Build concluído. Abra um novo shell (ou 'source ~/.bashrc') antes de rodar os experimentos."
