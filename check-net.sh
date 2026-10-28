#!/bin/bash
# Verifica, depois que todos os nós estiverem prontos, a conectividade da rede
# de experimento e (no modo RoCE) se jumbo frames passam pelo switch.
# Uso: /local/repository/check-net.sh [nº de nós]

N="${1:-4}"
source /local/rdma.env 2>/dev/null || { echo "rode antes: sudo /local/repository/rdma-info.sh <ib|roce>"; exit 1; }
MY_IP="$RDMA_IP"
IF_MTU=$(cat "/sys/class/net/$RDMA_NETDEV/mtu" 2>/dev/null)
echo "modo $RDMA_MODE | $RDMA_DEV porta $RDMA_PORT | netdev $RDMA_NETDEV (MTU $IF_MTU) | active_mtu RDMA $RDMA_ACTIVE_MTU"

for i in $(seq 1 "$N"); do
  ip="10.10.1.$i"
  [ "$ip" = "$MY_IP" ] && continue
  if ping -q -c 3 -W 1 "$ip" >/dev/null 2>&1; then ok="ok"; else ok="FALHOU"; fi
  jumbo="-"
  if [ "$RDMA_MODE" = "roce" ] && [ "${IF_MTU:-1500}" -ge 9000 ]; then
    if ping -q -c 3 -W 1 -M do -s 8972 "$ip" >/dev/null 2>&1; then jumbo="ok"; else jumbo="FALHOU"; fi
  fi
  echo "  $ip: ping $ok | jumbo 9000 $jumbo"
done

if [ "$RDMA_MODE" = "roce" ] && [ "${IF_MTU:-1500}" -ge 9000 ]; then
  echo "Se 'jumbo' falhou, o switch não aceita MTU 9000: rode 'sudo ip link set dev $RDMA_NETDEV mtu 1500'"
  echo "em todos os nós e use MTU RDMA 1024 no Mu."
fi
