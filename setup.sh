#!/bin/bash
# Configuração dos nós para reproduzir o Mu (OSDI'20) no CloudLab.
# Uso (chamado pelo profile):
#   setup.sh <ib|roce> <node_index> <ofed_version> <pin_kernel> <clone_mu> <jumbo>
# O CloudLab executa este script a cada boot; arquivos-marcador em /local/.mu-*
# tornam cada etapa idempotente. Log em /local/setup.log.

set -u
MODE="${1:-ib}"
NODE_IDX="${2:-0}"
OFED_VER="${3:-4.7-3.2.9.0}"
PIN_KERNEL="${4:-1}"
CLONE_MU="${5:-1}"
JUMBO="${6:-0}"

REPO=/local/repository
KVER="4.15.0-72-generic"
OFED_PKG="MLNX_OFED_LINUX-${OFED_VER}-ubuntu18.04-x86_64"
OFED_URL="https://content.mellanox.com/ofed/MLNX_OFED-${OFED_VER}/${OFED_PKG}.tgz"
EXP_PREFIX="10.10.1."
M=/local/.mu
log() { echo "[$(date '+%F %T')] node${NODE_IDX} (${MODE}): $*"; }

export DEBIAN_FRONTEND=noninteractive
log "início (kernel atual: $(uname -r))"

# 1) Kernel do artigo (melhor esforço; exige um reboot)
if [ "$PIN_KERNEL" = "1" ] && [ ! -e "$M-kernel" ]; then
  touch "$M-kernel"
  if [ "$(uname -r)" != "$KVER" ]; then
    apt-get update -q
    if apt-get install -y -q "linux-image-$KVER" "linux-headers-$KVER" "linux-modules-extra-$KVER"; then
      sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux $KVER\"|" /etc/default/grub
      update-grub
      log "kernel $KVER instalado; reiniciando"
      reboot
      exit 0
    else
      log "AVISO: kernel $KVER indisponível; mantendo $(uname -r)"
    fi
  fi
fi

# 2) Pacotes do Dockerfile do Mu (libibverbs vem do OFED)
if [ ! -e "$M-pkgs" ]; then
  apt-get update -q
  apt-get install -y -q build-essential python3 python3-pip cmake ninja-build clang lld \
    clang-format libmemcached-dev memcached libevent-dev libhugetlbfs-dev libgtest-dev \
    libnuma-dev numactl libgflags-dev git vim tmux linux-tools-common \
    "linux-tools-$(uname -r)" || true
  (cd /usr/src/gtest && cmake CMakeLists.txt && make && cp *.a /usr/lib/) || log "AVISO: gtest falhou"
  # O build do Mu usa perfis do Conan 1.x; o último pip para Python 3.6 é o 21.x
  python3 -m pip install -q --upgrade "pip<22"
  python3 -m pip install -q "conan<2"
  touch "$M-pkgs"
fi

# 3) Mellanox OFED (padrão: 4.7-3.2.9.0, a versão do artigo; inclui perftest)
if [ ! -e "$M-ofed" ]; then
  cd /local
  if [ ! -d "$OFED_PKG" ]; then
    wget -q "$OFED_URL" -O "$OFED_PKG.tgz" && tar xzf "$OFED_PKG.tgz" \
      || { log "ERRO: download do OFED falhou ($OFED_URL)"; exit 1; }
  fi
  cd "$OFED_PKG"
  if ! ./mlnxofedinstall --force --without-fw-update; then
    log "instalação direta falhou; recompilando para $(uname -r) (--add-kernel-support)"
    ./mlnxofedinstall --force --without-fw-update --add-kernel-support \
      || { log "ERRO: instalação do OFED falhou"; exit 1; }
  fi
  /etc/init.d/openibd restart
  touch "$M-ofed"
fi

# 4) Ajustes de sistema (a cada boot)
grep -q "memlock unlimited" /etc/security/limits.conf || \
  printf '* soft memlock unlimited\n* hard memlock unlimited\n' >> /etc/security/limits.conf
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo performance > "$g"
done
systemctl stop irqbalance 2>/dev/null || true
systemctl stop memcached 2>/dev/null || true   # o registro do Mu é iniciado à mão no node3
# eRPC (usado no experimento Liquibook) exige hugepages em todos os nós NUMA
for h in /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages; do
  echo 2048 > "$h"
done

# 5) Rede de experimento: no modo RoCE, jumbo frames permitem MTU RDMA de 4096
#    (a mesma do artigo); com MTU Ethernet 1500 a MTU RDMA cai para 1024.
EXP_IF=$(ip -o -4 addr show | awk -v p="$EXP_PREFIX" 'index($4,p)==1 {print $2; exit}')
if [ "$MODE" = "roce" ] && [ -n "$EXP_IF" ]; then
  [ "$JUMBO" = "1" ] && ip link set dev "$EXP_IF" mtu 9000 && log "MTU 9000 em $EXP_IF"
  # O eRPC usa o GID de índice 1 (RoCEv2 link-local), que depende de IPv6 na interface
  sysctl -q -w "net.ipv6.conf.${EXP_IF}.disable_ipv6=0"
fi

# 6) Código do Mu
if [ "$CLONE_MU" = "1" ] && [ ! -d /local/mu ]; then
  git clone https://github.com/LPD-EPFL/mu.git /local/mu && chmod -R a+rwX /local/mu
fi

# 7) Descobre device/porta/GID da rede de experimento e grava /local/rdma.env
sleep 5
bash "$REPO/rdma-info.sh" "$MODE" "$EXP_PREFIX" /local/rdma.env
log "fim"
