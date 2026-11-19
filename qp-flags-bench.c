// Mede a latência de ibv_modify_qp(IBV_QP_ACCESS_FLAGS), a chamada que o Mu
// usa em ReliableConnection::changeRights (conn/src/rc.cpp) para tirar e dar
// acesso de escrita remota na troca de líder.
//
// Cria dois QPs RC ligados entre si no mesmo HCA (loopback) e leva os dois a
// RTS. Cada iteração repete o que o seguidor do Mu faz na troca de líder:
// revoga a escrita remota em um QP (o do líder antigo: LOCAL_WRITE) e logo em
// seguida concede no outro (o do novo líder: LOCAL_WRITE | REMOTE_READ |
// REMOTE_WRITE). Na iteração seguinte os papéis se invertem, então toda troca
// muda de fato as flags do QP.
//
// Compilar: gcc -O2 -Wall -o qp-flags-bench qp-flags-bench.c -libverbs
// Uso:      qp-flags-bench -d mlx4_0 [-i porta] [-x gid_index] [-n pares]
//                          [-w aquecimento] [-g intervalo_us] [-o amostras.txt]
//
// Saída (stdout) no mesmo formato do summary.csv do fail-over:
//   metric,samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns
// revoke e grant são cada chamada sozinha; pair é o par inteiro (revoke
// seguido de grant), medido com o mesmo relógio.

#include <errno.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RIGHTS_REVOKE (IBV_ACCESS_LOCAL_WRITE)
#define RIGHTS_GRANT \
  (IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE)

static void die(const char *what) {
  fprintf(stderr, "ERRO: %s: %s\n", what, strerror(errno));
  exit(1);
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void spin_us(unsigned us) {
  uint64_t until = now_ns() + (uint64_t)us * 1000;
  while (now_ns() < until) {
  }
}

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return (x > y) - (x < y);
}

static void summary(const char *name, uint64_t *v, size_t n) {
  if (n == 0) return;
  qsort(v, n, sizeof(*v), cmp_u64);
  long double sum = 0;
  for (size_t i = 0; i < n; i++) sum += v[i];
  printf("%s,%zu,%llu,%llu,%llu,%llu,%llu\n", name, n,
         (unsigned long long)v[n / 100], (unsigned long long)v[n / 2],
         (unsigned long long)v[(n * 99) / 100],
         (unsigned long long)(sum / n), (unsigned long long)v[n - 1]);
}

static void change_rights(struct ibv_qp *qp, unsigned rights) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_access_flags = rights;
  int ret = ibv_modify_qp(qp, &a, IBV_QP_ACCESS_FLAGS);
  if (ret) {
    if (ret > 0) errno = ret;
    die("ibv_modify_qp(IBV_QP_ACCESS_FLAGS)");
  }
}

static void to_init(struct ibv_qp *qp, int port, unsigned rights) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_INIT;
  a.pkey_index = 0;
  a.port_num = port;
  a.qp_access_flags = rights;
  if (ibv_modify_qp(qp, &a,
                    IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                        IBV_QP_ACCESS_FLAGS))
    die("QP -> INIT");
}

static void to_rtr(struct ibv_qp *qp, uint32_t dest_qpn, int port,
                   struct ibv_port_attr *pa, int gid_index, union ibv_gid *gid) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_RTR;
  a.path_mtu = pa->active_mtu;
  a.dest_qp_num = dest_qpn;
  a.rq_psn = 0;
  a.max_dest_rd_atomic = 1;
  a.min_rnr_timer = 12;
  a.ah_attr.dlid = pa->lid;
  a.ah_attr.port_num = port;
  if (gid_index >= 0) {
    a.ah_attr.is_global = 1;
    a.ah_attr.grh.dgid = *gid;
    a.ah_attr.grh.sgid_index = gid_index;
    a.ah_attr.grh.hop_limit = 1;
  }
  if (ibv_modify_qp(qp, &a,
                    IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                        IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                        IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
    die("QP -> RTR");
}

static void to_rts(struct ibv_qp *qp) {
  struct ibv_qp_attr a;
  memset(&a, 0, sizeof(a));
  a.qp_state = IBV_QPS_RTS;
  a.timeout = 14;
  a.retry_cnt = 7;
  a.rnr_retry = 7;
  a.sq_psn = 0;
  a.max_rd_atomic = 1;
  if (ibv_modify_qp(qp, &a,
                    IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                        IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
                        IBV_QP_MAX_QP_RD_ATOMIC))
    die("QP -> RTS");
}

int main(int argc, char **argv) {
  const char *dev_name = NULL, *out_path = NULL;
  int port = 1, gid_index = -1, opt;
  long iters = 10000, warmup = 100;
  unsigned gap_us = 0;

  while ((opt = getopt(argc, argv, "d:i:x:n:w:g:o:")) != -1) {
    switch (opt) {
      case 'd': dev_name = optarg; break;
      case 'i': port = atoi(optarg); break;
      case 'x': gid_index = atoi(optarg); break;
      case 'n': iters = atol(optarg); break;
      case 'w': warmup = atol(optarg); break;
      case 'g': gap_us = (unsigned)atoi(optarg); break;
      case 'o': out_path = optarg; break;
      default:
        fprintf(stderr,
                "uso: %s -d dev [-i porta] [-x gid_index] [-n pares] "
                "[-w aquecimento] [-g intervalo_us] [-o amostras.txt]\n",
                argv[0]);
        return 1;
    }
  }
  if (!dev_name || iters < 1 || warmup < 0) {
    fprintf(stderr, "ERRO: informe -d <device> e -n >= 1\n");
    return 1;
  }

  int ndev;
  struct ibv_device **list = ibv_get_device_list(&ndev);
  if (!list) die("ibv_get_device_list");
  struct ibv_device *dev = NULL;
  for (int i = 0; i < ndev; i++)
    if (strcmp(ibv_get_device_name(list[i]), dev_name) == 0) dev = list[i];
  if (!dev) {
    fprintf(stderr, "ERRO: device %s não encontrado\n", dev_name);
    return 1;
  }

  struct ibv_context *ctx = ibv_open_device(dev);
  if (!ctx) die("ibv_open_device");

  struct ibv_port_attr pa;
  if (ibv_query_port(ctx, port, &pa)) die("ibv_query_port");
  if (pa.state != IBV_PORT_ACTIVE) {
    fprintf(stderr, "ERRO: porta %d de %s não está ACTIVE\n", port, dev_name);
    return 1;
  }
  union ibv_gid gid;
  memset(&gid, 0, sizeof(gid));
  if (pa.link_layer == IBV_LINK_LAYER_ETHERNET && gid_index < 0) {
    fprintf(stderr, "ERRO: link Ethernet (RoCE): informe -x <gid_index>\n");
    return 1;
  }
  if (gid_index >= 0 && ibv_query_gid(ctx, port, gid_index, &gid))
    die("ibv_query_gid");

  struct ibv_pd *pd = ibv_alloc_pd(ctx);
  if (!pd) die("ibv_alloc_pd");
  static char buf[4096];
  // Como no Mu, o MR é registrado com todas as permissões; quem limita o
  // acesso remoto são as flags do QP.
  struct ibv_mr *mr = ibv_reg_mr(pd, buf, sizeof(buf), RIGHTS_GRANT);
  if (!mr) die("ibv_reg_mr");
  struct ibv_cq *cq = ibv_create_cq(ctx, 16, NULL, NULL, 0);
  if (!cq) die("ibv_create_cq");

  struct ibv_qp_init_attr ia;
  memset(&ia, 0, sizeof(ia));
  ia.send_cq = cq;
  ia.recv_cq = cq;
  ia.qp_type = IBV_QPT_RC;
  ia.cap.max_send_wr = 4;
  ia.cap.max_recv_wr = 4;
  ia.cap.max_send_sge = 1;
  ia.cap.max_recv_sge = 1;
  struct ibv_qp *qa = ibv_create_qp(pd, &ia);
  struct ibv_qp *qb = ibv_create_qp(pd, &ia);
  if (!qa || !qb) die("ibv_create_qp");

  // Estado inicial: qa com escrita remota (líder antigo), qb sem (novo líder).
  to_init(qa, port, RIGHTS_GRANT);
  to_init(qb, port, RIGHTS_REVOKE);
  to_rtr(qa, qb->qp_num, port, &pa, gid_index, &gid);
  to_rtr(qb, qa->qp_num, port, &pa, gid_index, &gid);
  to_rts(qa);
  to_rts(qb);

  uint64_t *revoke = calloc((size_t)iters, sizeof(uint64_t));
  uint64_t *grant = calloc((size_t)iters, sizeof(uint64_t));
  uint64_t *pair = calloc((size_t)iters, sizeof(uint64_t));
  if (!revoke || !grant || !pair) die("calloc");
  FILE *out = NULL;
  if (out_path && !(out = fopen(out_path, "w"))) die(out_path);
  if (out) fprintf(out, "revoke_ns grant_ns pair_ns\n");

  size_t n = 0;
  struct ibv_qp *old_leader = qa, *new_leader = qb;
  for (long i = 0; i < warmup + iters; i++) {
    if (gap_us) spin_us(gap_us);

    // Como o seguidor do Mu: revoga do líder antigo e concede ao novo, seguidos
    uint64_t t0 = now_ns();
    change_rights(old_leader, RIGHTS_REVOKE);
    uint64_t t1 = now_ns();
    change_rights(new_leader, RIGHTS_GRANT);
    uint64_t t2 = now_ns();

    // Na próxima troca de líder, os papéis se invertem
    struct ibv_qp *tmp = old_leader;
    old_leader = new_leader;
    new_leader = tmp;

    if (i < warmup) continue;
    revoke[n] = t1 - t0;
    grant[n] = t2 - t1;
    pair[n] = t2 - t0;
    if (out) fprintf(out, "%llu %llu %llu\n", (unsigned long long)revoke[n],
                     (unsigned long long)grant[n], (unsigned long long)pair[n]);
    n++;
  }
  if (out) fclose(out);

  printf("metric,samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns\n");
  summary("revoke", revoke, n);
  summary("grant", grant, n);
  summary("pair", pair, n);

  ibv_destroy_qp(qa);
  ibv_destroy_qp(qb);
  ibv_destroy_cq(cq);
  ibv_dereg_mr(mr);
  ibv_dealloc_pd(pd);
  ibv_close_device(ctx);
  ibv_free_device_list(list);
  return 0;
}
