#!/bin/bash
# Descobre qual device/porta RDMA está ligado à rede de experimento e grava as
# variáveis em um arquivo para o Mu e o eRPC. Pode ser rodado à mão a qualquer
# momento:  sudo /local/repository/rdma-info.sh <ib|roce>
#
# Por que isso é necessário: o Mu usa o ÚLTIMO device de ibv_get_device_list()
# e a primeira porta com link; o eRPC usa a N-ésima porta com link, contando
# todos os devices. Nos nós do CloudLab com várias portas Mellanox (inclusive a
# da rede de controle), essa escolha automática pode cair na porta errada.

MODE="${1:-ib}"
PREFIX="${2:-10.10.1.}"
OUT="${3:-/local/rdma.env}"

EXP_IF=$(ip -o -4 addr show | awk -v p="$PREFIX" 'index($4,p)==1 {print $2; exit}')
EXP_IP=$(ip -o -4 addr show dev "$EXP_IF" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
# GID IPv4-mapped esperado para RoCEv2: ::ffff:a.b.c.d
GID_WANT=""
if [ -n "$EXP_IP" ]; then
  IFS=. read -r a b c d <<< "$EXP_IP"
  GID_WANT=$(printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' "$a" "$b" "$c" "$d")
fi

ORDER=$(ibv_devices 2>/dev/null | awk 'NR>2 && NF {print $1}')
[ -n "$ORDER" ] || ORDER=$(ls ${SYS_IB:-/sys/class/infiniband} 2>/dev/null)

echo "== interface de experimento: ${EXP_IF:-?} (${EXP_IP:-?})"
echo "== devices em ordem de ibv_get_device_list: $(echo $ORDER)"

erpc_idx=0
SEL_DEV=""; SEL_PORT=""; SEL_ERPC=""; SEL_GID=""; SEL_LID=""
MU_DEV=""; MU_PORT=""
for dev in $ORDER; do
  mu_first=""
  for pdir in ${SYS_IB:-/sys/class/infiniband}/$dev/ports/*; do
    port=$(basename "$pdir")
    ll=$(cat "$pdir/link_layer" 2>/dev/null)
    st=$(cat "$pdir/state" 2>/dev/null)
    ph=$(cat "$pdir/phys_state" 2>/dev/null)
    nd=$(cat "$pdir/gid_attrs/ndevs/0" 2>/dev/null)
    echo "   $dev porta $port: $ll | $st | $ph | netdev=${nd:--}"
    case "$ph" in 4:*|5:*) linkup=1 ;; *) linkup=0 ;; esac
    [ "$linkup" = 1 ] || continue
    [ -z "$mu_first" ] && mu_first="$port"

    if [ -z "$SEL_DEV" ]; then
      if [ "$MODE" = "ib" ] && [ "$ll" = "InfiniBand" ]; then
        SEL_DEV=$dev; SEL_PORT=$port; SEL_ERPC=$erpc_idx
        SEL_LID=$(printf '%d' "$(cat "$pdir/lid")")
      elif [ "$MODE" = "roce" ] && [ "$ll" = "Ethernet" ] && [ "$nd" = "$EXP_IF" ]; then
        SEL_DEV=$dev; SEL_PORT=$port; SEL_ERPC=$erpc_idx
        for g in "$pdir"/gids/*; do
          i=$(basename "$g")
          t=$(cat "$pdir/gid_attrs/types/$i" 2>/dev/null) || continue
          [ "$t" = "RoCE v2" ] && [ "$(cat "$g")" = "$GID_WANT" ] && { SEL_GID=$i; break; }
        done
        ERPC_GID1_TYPE=$(cat "$pdir/gid_attrs/types/1" 2>/dev/null)
        ERPC_GID1=$(cat "$pdir/gids/1" 2>/dev/null)
      fi
    fi
    erpc_idx=$((erpc_idx + 1))
  done
  [ -n "$mu_first" ] && { MU_DEV=$dev; MU_PORT=$mu_first; }
done

if [ -z "$SEL_DEV" ]; then
  echo "!! nenhuma porta adequada encontrada para o modo $MODE"
  [ "$MODE" = "ib" ] && echo "!! verifique se a porta Mellanox está em modo InfiniBand e ACTIVE (há subnet manager?)"
  exit 1
fi

MTU=$(ibv_devinfo -d "$SEL_DEV" -i "$SEL_PORT" 2>/dev/null | awk '/active_mtu/ {print $2; exit}')
NUMA=$(cat "${SYS_IB:-/sys/class/infiniband}/$SEL_DEV/device/numa_node" 2>/dev/null)

{
  echo "# gerado por rdma-info.sh em $(date '+%F %T')"
  echo "export RDMA_MODE=$MODE"
  echo "export RDMA_DEV=$SEL_DEV"
  echo "export RDMA_PORT=$SEL_PORT"
  echo "export RDMA_ACTIVE_MTU=$MTU"
  echo "export RDMA_NUMA=${NUMA:-0}"
  echo "export RDMA_NETDEV=$EXP_IF"
  echo "export RDMA_IP=$EXP_IP"
  [ "$MODE" = "ib" ]   && echo "export RDMA_LID=$SEL_LID"
  [ "$MODE" = "roce" ] && echo "export RDMA_GID_INDEX=$SEL_GID"
  echo "export ERPC_PORT_INDEX=$SEL_ERPC   # use em --numa_0_ports do liquibook"
} > "$OUT"
chmod a+r "$OUT"

echo "== selecionado: $SEL_DEV porta $SEL_PORT, active_mtu $MTU, NUMA ${NUMA:-?}, índice eRPC $SEL_ERPC"
[ "$MODE" = "roce" ] && echo "== GID RoCEv2 (IPv4) índice: ${SEL_GID:-NÃO ENCONTRADO}"
if [ "$MODE" = "roce" ] && [ "$ERPC_GID1_TYPE" != "RoCE v2" ]; then
  echo "!! o eRPC usa o GID de índice 1, mas ele é '$ERPC_GID1_TYPE' ($ERPC_GID1): ajuste kDefaultGIDIndex"
fi
if [ "$MU_DEV" != "$SEL_DEV" ] || [ "$MU_PORT" != "$SEL_PORT" ]; then
  echo "!! o Mu sem modificação escolheria $MU_DEV porta $MU_PORT (último device, primeira porta com link)"
fi
[ "${NUMA:-0}" != "0" ] && echo "!! a NIC está no nó NUMA $NUMA: troque 'numactl --membind 0' por '--membind $NUMA'"
echo "== variáveis gravadas em $OUT"
