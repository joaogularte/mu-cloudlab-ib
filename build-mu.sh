#!/bin/bash
# Compila o Mu seguindo o README (seção "Compilation of the software stack").
# Rode com o seu usuário (não como root) em cada um dos 4 nós, depois que o
# setup terminar:   /local/repository/build-mu.sh
# O README clona osdi2020-no-152/dory (repositório que não existe mais); o
# mesmo código está em LPD-EPFL/mu; o profile clona o fork joaogularte/mu em /local/mu.
# Compila só o necessário para o Mu standalone (main-st / main-st-lat); Redis,
# Memcached e Liquibook (crash-consensus/experiments) ficam de fora.
set -e
MU="${MU_DIR:-/local/mu}"
cd "$MU"

conan profile new default --detect >/dev/null 2>&1 || true
conan profile update settings.compiler.libcxx=libstdc++11 default

./build.py crash-consensus
crash-consensus/demo/using_conan_fully/build.sh gcc-release

grep -q "/local/rdma.env" ~/.bashrc || echo "source /local/rdma.env 2>/dev/null" >> ~/.bashrc
echo "Build concluído: $MU/crash-consensus/demo/using_conan_fully/build/bin/{main-st,main-st-lat}"
echo "Abra um novo shell (ou 'source ~/.bashrc') antes de rodar os experimentos."
