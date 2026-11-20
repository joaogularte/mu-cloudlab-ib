#!/bin/bash
# Calibração da latência RDMA com ib_write_lat, repetida várias vezes.
# Grava em ~/mu-results/rdma-lat, no mesmo formato dos scripts do Mu
# (crash-consensus/experiments/paper): um log bruto por execução e um summary.csv.
#
# Uso:
#   node1: /local/repository/rdma-lat.sh server [execuções]
#   node0: /local/repository/rdma-lat.sh client <ip do servidor> [execuções]
# Inicie o servidor primeiro. Os dois lados devem usar o mesmo nº de execuções.
# Variáveis: SIZE (bytes, padrão 64), ITERS (padrão 100000), RESULTS_DIR.

set -u

ROLE="${1:-}"
case "$ROLE" in
  server) SERVER_IP=""; RUNS="${2:-5}" ;;
  client) SERVER_IP="${2:-}"; RUNS="${3:-5}"
          [ -n "$SERVER_IP" ] || { echo "uso: $0 client <ip do servidor> [execuções]"; exit 1; } ;;
  *) echo "uso: $0 server [execuções] | $0 client <ip do servidor> [execuções]"; exit 1 ;;
esac

source /local/rdma.env 2>/dev/null || { echo "rode antes: sudo /local/repository/rdma-info.sh <ib|roce>"; exit 1; }

SIZE="${SIZE:-64}"
ITERS="${ITERS:-100000}"
OUT="${RESULTS_DIR:-$HOME/mu-results}/rdma-lat"
mkdir -p "$OUT"

GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
[ -n "$GOV" ] && [ "$GOV" != "performance" ] && echo "!! governor da cpu0 é '$GOV', não 'performance'"

GID_OPT=""
[ "$RDMA_MODE" = "roce" ] && GID_OPT="-x $RDMA_GID_INDEX"

lat() {
  numactl --cpunodebind="$RDMA_NUMA" --membind="$RDMA_NUMA" \
    ib_write_lat -d "$RDMA_DEV" -i "$RDMA_PORT" $GID_OPT -s "$SIZE" -n "$ITERS" "$@"
}

# Linha de resultados do ib_write_lat: a primeira linha numérica depois do cabeçalho #bytes
parse() {
  awk -v run="$2" '/#bytes/ { h = 1; next }
    h && $1 ~ /^[0-9]+$/ { print run "," $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," $9; exit }' "$1"
}

rm -f "$OUT/$ROLE"-*.log
echo "== $ROLE: $RUNS execuções, $SIZE bytes, $ITERS iterações, $RDMA_DEV porta $RDMA_PORT, NUMA $RDMA_NUMA"

if [ "$ROLE" = "server" ]; then
  for r in $(seq 1 "$RUNS"); do
    echo "== execução $r/$RUNS: aguardando o cliente"
    lat > "$OUT/server-$r.log" 2>&1 || echo "!! execução $r falhou, veja $OUT/server-$r.log"
  done
  echo "== logs em $OUT"
  exit 0
fi

SUMMARY="$OUT/summary.csv"
echo "run,bytes,iterations,t_min_us,t_max_us,t_typical_us,t_avg_us,t_stdev_us,p99_us,p99.9_us" | tee "$SUMMARY"

for r in $(seq 1 "$RUNS"); do
  log="$OUT/client-$r.log"
  # O servidor leva um instante para voltar a escutar depois da execução anterior
  ok=0
  for try in $(seq 1 10); do
    sleep 1
    if lat "$SERVER_IP" > "$log" 2>&1; then ok=1; break; fi
  done
  if [ "$ok" = 1 ]; then
    parse "$log" "$r" | tee -a "$SUMMARY"
  else
    echo "!! execução $r falhou, veja $log"
  fi
done

echo "== resumo em $SUMMARY"
