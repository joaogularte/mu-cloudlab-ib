# Mu (OSDI'20) no CloudLab com InfiniBand

Profile do CloudLab para reproduzir o [Mu](https://github.com/LPD-EPFL/mu) sobre
RDMA InfiniBand nativo: 4 nós `c6220` no cluster **Apt** (Mellanox ConnectX-3
FDR 56 Gbps), Ubuntu 18.04 e Mellanox OFED 4.7-3.2.9.0.

| Arquivo | Função |
|---|---|
| [profile.py](profile.py) | Define os nós, a LAN de experimento (`10.10.1.0/24`) e chama o `setup.sh` em cada nó |
| [setup.sh](setup.sh) | Instala kernel, pacotes, OFED, ajusta o sistema e clona o Mu (roda a cada boot) |
| [rdma-info.sh](rdma-info.sh) | Descobre o device/porta RDMA correto e grava `/local/rdma.env` |
| [check-net.sh](check-net.sh) | Testa a conectividade entre os nós |
| [build-mu.sh](build-mu.sh) | Compila o Mu standalone |
| [rdma-lat.sh](rdma-lat.sh) | Repete o `ib_write_lat` entre dois nós e grava os resultados em `~/mu-results/rdma-lat` |
| [qp-flags-bench.c](qp-flags-bench.c) | Mede a latência da troca de flags de acesso de um QP |

## Topologia

| Nó | IP de experimento | Papel |
|---|---|---|
| `node0` | `10.10.1.1` | Réplica (SID 1) |
| `node1` | `10.10.1.2` | Réplica (SID 2) |
| `node2` | `10.10.1.3` | Réplica (SID 3) |
| `node3` | `10.10.1.4` | Cliente + registro memcached (`10.10.1.4:9999`) |

O tráfego RDMA do Mu vai direto pela porta InfiniBand (endereçado por LID). A LAN
Ethernet `10.10.1.0/24` é usada só para TCP: o registro memcached e os clientes.

### Sem Docker

O README do Mu descreve uma implantação com Docker em modo swarm, mas avisa que,
para ter o melhor desempenho, é preciso evitar o Docker e rodar nativamente (seção
*Running without docker*). Este profile segue esse caminho: **o Docker não é
instalado**. O Dockerfile do Mu serve só como lista de dependências, que o
`setup.sh` instala direto em cada nó. Os containers `osdi-node-1..4` correspondem
a `node0..node3` e o container `osdi-memc` ao memcached do `node3`.

---

## Passos após a criação do experimento

Os passos 1 a 4 devem ser feitos **em cada um dos 4 nós**. Abra uma sessão SSH
para cada nó (o endereço aparece na aba *List View* do experimento); usar `tmux`
ajuda a não perder o trabalho se a conexão cair.

### 1. Esperar o setup terminar

Quando o experimento ficar **Ready**, o `setup.sh` ainda está rodando. Acompanhe:

```bash
tail -f /local/setup.log
```

O que acontece, em ordem:

1. Instalação do kernel `4.15.0-72-generic` (versão do artigo) e **um reboot**
   do nó. A sessão SSH cai; reconecte e continue acompanhando o log.
2. Pacotes do Dockerfile do Mu, `gtest` e Conan 1.x.
3. Download e instalação do Mellanox OFED (leva vários minutos; se a instalação
   direta falhar, o script recompila para o kernel atual com
   `--add-kernel-support`, o que demora mais).
4. Ajustes de sistema: `memlock unlimited`, governor `performance`, `irqbalance`
   parado, hugepages de 2 MB.
5. Clone do Mu em `/local/mu`.
6. Execução do `rdma-info.sh`.

O setup terminou quando o log mostra a linha `... fim`. Antes dela devem aparecer
o device e a porta selecionados (`== selecionado: mlx4_0 porta 1, ...`).

> Se o log mostrar `ERRO:` (por exemplo, falha no download do OFED), corrija a
> causa e rode o setup de novo à mão (veja [Rodar o setup de novo](#rodar-o-setup-de-novo)).

### 2. Conferir a configuração RDMA

```bash
source /local/rdma.env && cat /local/rdma.env
ibv_devinfo -d $RDMA_DEV | grep -E "state|link_layer|active_mtu"
```

O esperado é `link_layer: InfiniBand` e `state: PORT_ACTIVE`.

Leia também os avisos `!!` no final do `/local/setup.log` (ou rode de novo
`sudo /local/repository/rdma-info.sh ib`):

- **`o Mu sem modificação escolheria ...`**: o Mu usa o último device de
  `ibv_get_device_list()` e a primeira porta com link. Se essa escolha for
  diferente da porta selecionada, o Mu vai usar a porta errada.
- **`a NIC está no nó NUMA N`**: troque `numactl --membind 0` por
  `numactl --membind N` nos comandos dos experimentos.

### 3. Verificar a rede

Depois que **todos** os nós terminarem o setup:

```bash
/local/repository/check-net.sh
```

Todos os outros IPs `10.10.1.x` devem responder `ping ok`.

### 4. Compilar o Mu

Com o **seu usuário** (não como root):

```bash
/local/repository/build-mu.sh
source ~/.bashrc
```

O script configura o perfil do Conan e compila o `crash-consensus` e a demo
`using_conan_fully`, que gera os binários do Mu standalone (`main-st`,
`main-st-lat` e `main-failover`, em `/local/mu/crash-consensus/demo/using_conan_fully/build/bin`).
Os experimentos com Redis, Memcached e Liquibook não são compilados. O script
também adiciona `source /local/rdma.env` ao `~/.bashrc`.

Abra um novo shell (ou rode `source ~/.bashrc`) antes de seguir.

### 5. Calibrar a latência RDMA (recomendado)

Serve para comparar este ambiente com o do artigo e com o profile RoCE.

Antes de medir, coloque o governor em `performance` no `node0` e no `node1`.
O `setup.sh` já faz isso no boot, mas o ajuste pode ter sido desfeito depois
(por exemplo, pelo serviço `ondemand` do Ubuntu):

```bash
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$g" >/dev/null
done
```

O `rdma-lat.sh` roda o `ib_write_lat` várias vezes seguidas, para mostrar a
variação de uma execução para outra. Cada execução usa `numactl`, fixando CPU e
memória no nó NUMA da NIC (`$RDMA_NUMA`, de `/local/rdma.env`). Sem isso, cada
processo pode cair no socket errado e a latência muda de uma execução para
outra.

Inicie primeiro o servidor, no `node1`:

```bash
/local/repository/rdma-lat.sh server 5
```

Depois o cliente, no `node0`, com o mesmo número de execuções:

```bash
/local/repository/rdma-lat.sh client 10.10.1.2 5
```

O padrão é 5 execuções de 100000 iterações com mensagens de 64 bytes. Para
mudar, use `SIZE` e `ITERS` nos dois nós (por exemplo,
`SIZE=32 ITERS=1000000 /local/repository/rdma-lat.sh server 10`). O script
avisa se o governor da `cpu0` não for `performance`.

Os resultados ficam em `~/mu-results/rdma-lat`, no mesmo formato dos scripts do
passo 7:

| Arquivo | Nó | Conteúdo |
|---|---|---|
| `client-<n>.log` | `node0` | Saída completa do `ib_write_lat` na execução `n` |
| `server-<n>.log` | `node1` | Saída do lado servidor na execução `n` |
| `summary.csv` | `node0` | Uma linha por execução, com as colunas do `ib_write_lat` |

```
run,bytes,iterations,t_min_us,t_max_us,t_typical_us,t_avg_us,t_stdev_us,p99_us,p99.9_us
1,64,100000,...
2,64,100000,...
```

Os valores estão em µs e já são metade do tempo de ida e volta, como o
`ib_write_lat` reporta. O `t_typical_us` é a mediana. Cada nova chamada apaga os
logs e o `summary.csv` anteriores; para guardar uma rodada, copie a pasta ou
use outra `RESULTS_DIR` (por exemplo, `RESULTS_DIR=~/mu-results-powersave`).

> Se uma execução do cliente falhar (o script tenta conectar por até 10 s), o
> servidor fica esperando um cliente a mais. Encerre-o com `Ctrl-C`.

### 6. Medir a troca de QP flags (recomendado)

Na troca de líder, o Mu tira a permissão de escrita do líder antigo e dá ao novo
com `ibv_modify_qp(..., IBV_QP_ACCESS_FLAGS)` (`changeRights`, em
`conn/src/rc.cpp`). Essa chamada faz parte da métrica `permissions` do
`run-failover.sh`. O `qp-flags-bench` mede só essa chamada, sem o resto do
protocolo, para separar o custo da NIC e do driver do custo de comunicação.

No fail-over, quem faz as duas trocas no caminho crítico é o seguidor (`node2`):
ele revoga a escrita no QP do líder antigo e, logo em seguida, concede no QP do
novo líder. O artigo conta essas duas trocas dentro do tempo de troca de
permissão (Seção 7.3).

O teste roda em **um nó só** (use o `node2`). Ele cria dois QPs RC ligados entre
si na mesma NIC (loopback) e leva os dois a RTS. Cada iteração repete o que o
seguidor faz: revoga em um QP (`LOCAL_WRITE`) e concede no outro
(`LOCAL_WRITE | REMOTE_READ | REMOTE_WRITE`), as mesmas flags do Mu. Na
iteração seguinte os papéis dos dois QPs se invertem, então toda troca muda as
flags de fato.

Compile:

```bash
gcc -O2 -Wall -o ~/qp-flags-bench /local/repository/qp-flags-bench.c -libverbs
```

Rode com o governor em `performance` (veja o passo 5), fixando CPU e memória no
nó NUMA da NIC:

```bash
numactl --cpunodebind=$RDMA_NUMA --membind=$RDMA_NUMA \
  ~/qp-flags-bench -d $RDMA_DEV -i $RDMA_PORT -n 10000 -o ~/qp-flags-samples.txt \
  | tee ~/qp-flags-performance.csv
```

A saída tem o mesmo formato do `summary.csv` do fail-over:

```
metric,samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns
revoke,10000,...
grant,10000,...
pair,10000,...
```

| Linha | O que mede |
|---|---|
| `revoke` | Uma chamada sozinha: revogar a escrita no QP do líder antigo |
| `grant` | Uma chamada sozinha: conceder a escrita no QP do novo líder |
| `pair` | As duas seguidas, do início do revoke ao fim do grant |

Compare o `pair` com o tempo de troca de permissão do artigo e com a linha
`permissions` do fail-over. Os percentis do `pair` não são a soma dos percentis
de `revoke` e `grant`: só a média soma. O `pair` também mostra se uma troca logo
depois da outra custa mais que as duas sozinhas.

Opções:

| Opção | Padrão | Significado |
|---|---|---|
| `-n` | `10000` | Pares medidos |
| `-w` | `100` | Pares de aquecimento, descartados |
| `-g` | `0` | Espera ativa (µs) antes de cada par (fora da medição) |
| `-o` | — | Grava cada par (`revoke_ns grant_ns pair_ns`) em um arquivo |
| `-x` | — | Índice de GID, obrigatório só em RoCE (`$RDMA_GID_INDEX`) |

Com `-g 0` os pares são seguidos e a NIC e os núcleos ficam "quentes". Para
algo mais parecido com o fail-over, em que a troca acontece depois de um tempo
sem comandos para a NIC, rode também com `-g 1000`. Dentro do par não há espera
em nenhum caso, como no Mu.

#### Efeito do governor e dos C-states

Cada `ibv_modify_qp` passa pelo kernel e pelo driver `mlx4`, que envia um
comando ao firmware da NIC e espera a interrupção de conclusão. A parte do
kernel depende da frequência da CPU (governor). A espera pela interrupção
depende de quanto tempo o núcleo que a recebe demora para sair do estado de
repouso (C-states). Para separar os dois efeitos, mude um de cada vez e compare
os CSVs:

```bash
# 1) governor powersave (C-states como estão)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo powersave | sudo tee "$g" >/dev/null
done
numactl --cpunodebind=$RDMA_NUMA --membind=$RDMA_NUMA \
  ~/qp-flags-bench -d $RDMA_DEV -i $RDMA_PORT -n 10000 -g 1000 \
  | tee ~/qp-flags-powersave.csv

# 2) governor performance, C-states profundos desligados (state0 é POLL)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$g" >/dev/null
done
for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]*/disable; do
  echo 1 | sudo tee "$s" >/dev/null
done
numactl --cpunodebind=$RDMA_NUMA --membind=$RDMA_NUMA \
  ~/qp-flags-bench -d $RDMA_DEV -i $RDMA_PORT -n 10000 -g 1000 \
  | tee ~/qp-flags-no-cstates.csv

# Religar os C-states
for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]*/disable; do
  echo 0 | sudo tee "$s" >/dev/null
done
```

Para comparar com essas duas execuções, rode também a de referência com
`-g 1000` (governor `performance`, C-states ligados).

> Se `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` não existir, o
> cpufreq está desligado na BIOS e o governor não tem efeito. Nesse caso só a
> comparação dos C-states faz sentido. Para ver a frequência real e o tempo em
> cada C-state durante o teste, rode `sudo turbostat --quiet --interval 1` em
> outro terminal.

### 7. Rodar os experimentos do artigo

Os experimentos de latência (Seção 7.1), fail-over (7.3) e throughput (7.4) têm
scripts no fork, em
[`crash-consensus/experiments/paper`](https://github.com/joaogularte/mu/tree/master/crash-consensus/experiments/paper).
Eles rodam no `node3` e controlam as réplicas por SSH. Eles também iniciam o
registro memcached e definem `DORY_REGISTRY_IP`, então **não** é preciso fazer
o passo 8.

#### SSH do `node3` para as réplicas

Os scripts usam `ssh -o BatchMode=yes`, que não pede senha. Por isso o `node3`
precisa de uma chave aceita pelas réplicas; sem ela, o preflight mostra
`Permission denied (publickey)` e `FAIL: cannot SSH into 10.10.1.x`.

Crie uma chave no `node3`:

```bash
# node3
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Em cada réplica (`node0`, `node1`, `node2`), adicione a linha mostrada:

```bash
echo '<linha do id_ed25519.pub>' >> ~/.ssh/authorized_keys
```

Teste no `node3`:

```bash
for h in 10.10.1.1 10.10.1.2 10.10.1.3; do ssh -o BatchMode=yes "$h" hostname; done
```

> **Alternativa:** conectar no `node3` com `ssh -A`, para repassar a chave do seu
> computador. Ela só é repassada se estiver carregada no agente (confira com
> `ssh-add -l` no seu computador e no `node3`). Dentro de uma sessão `tmux`
> criada antes da conexão, o agente não fica visível. A chave própria do `node3`
> não depende disso, o que é mais seguro para execuções longas.

#### Conferir o ambiente

```bash
cd /local/mu/crash-consensus/experiments/paper
./preflight.sh
```

Corrija tudo o que aparecer como `FAIL`. Depois siga o
[README dos scripts](https://github.com/joaogularte/mu/tree/master/crash-consensus/experiments/paper#running)
(`run-latency.sh`, `run-failover.sh`, `run-throughput.sh`).

> Se o `/local/mu` foi clonado antes de os scripts entrarem no fork, rode
> `git -C /local/mu pull` e o `build-mu.sh` de novo nos 4 nós.

#### Fail-over com mais réplicas (12 nós)

Para medir o fail-over com 3, 5, 7, 9 e 11 réplicas, crie o experimento com
`nodeCount = 12`. O último nó é sempre o cliente:

| Nó | IP de experimento | Papel |
|---|---|---|
| `node0` | `10.10.1.1` | Réplica 1: o líder que é pausado |
| `node1` | `10.10.1.2` | Réplica 2: assume a liderança; é onde se mede |
| `node2`..`node10` | `10.10.1.3`..`10.10.1.11` | Réplicas 3..11 |
| `node11` | `10.10.1.12` | Cliente + registro memcached (`10.10.1.12:9999`) |

Com n réplicas, o experimento usa `node0..node{n-1}`. Assim, todos os valores de
n rodam nas mesmas máquinas, e o líder pausado e o nó medido não mudam.

1. Faça os passos 1 a 4 nos 12 nós. No passo 3, use `check-net.sh 12`. O
   `build-mu.sh` só é necessário nas 11 réplicas.
2. Crie a chave no `node11`, como em [SSH do node3 para as réplicas](#ssh-do-node3-para-as-réplicas),
   e copie a chave para as 11 réplicas. Faça isso a partir do seu computador,
   com os endereços da aba *List View*:

   ```bash
   KEY='<linha do id_ed25519.pub do node11>'
   for h in <endereço do node0> <endereço do node1> ... <endereço do node10>; do
     ssh "$h" "echo '$KEY' >> ~/.ssh/authorized_keys"
   done
   ```

3. No `node11`, confira as réplicas e faça uma rodada curta com as 11:

   ```bash
   cd /local/mu/crash-consensus/experiments/paper
   NR_REPLICAS=11 ./preflight.sh
   NR_REPLICAS=11 ./run-failover.sh 20
   ```

   O `NR_REPLICAS` escolhe as réplicas (`10.10.1.1..N`, padrão 3). O registro
   usa o IP do próprio cliente, que vem do `/local/rdma.env`.

4. Rode o sweep (umas 2h30 com os padrões: 5 valores de n × 3 repetições de
   1000 rodadas). Use `tmux`, porque a sessão SSH pode cair:

   ```bash
   ./run-failover-sweep.sh
   ```

   Os valores de n se alternam (3, 5, …, 11, 3, 5, …). Variáveis: `SWEEP_N`
   (padrão `3 5 7 9 11`), `REPS` (padrão 3) e o número de rodadas como
   argumento. Os resultados ficam em `~/mu-results/failover-sweep`: uma pasta
   `n<N>/rep<R>` para cada execução e um `summary.csv` com todas juntas
   (`n,rep,metric,...,hard_resets`). Os detalhes estão no
   [README dos scripts](https://github.com/joaogularte/mu/tree/master/crash-consensus/experiments/paper#scaling-the-number-of-replicas).

> O novo líder espera a permissão de **todas** as outras réplicas, não de uma
> maioria. Por isso, o tempo de `permissions` é o da réplica mais lenta entre
> as n−1.

### 8. Rodar outros experimentos à mão

Para os demais experimentos do README do Mu, o registro é iniciado à mão no
`node3`. O `setup.sh` para o serviço `memcached` do sistema de propósito, para
não ocupar a porta:

```bash
# node3
memcached -vv -p 9999
```

Em todos os nós, aponte o Mu para o registro:

```bash
export DORY_REGISTRY_IP=10.10.1.4:9999
```

A partir daqui, siga o README do Mu em `/local/mu` para rodar os experimentos,
usando os papéis da [topologia](#topologia): `node0`..`node2` são as réplicas
(SID 1..3) e `node3` é o cliente. Para o experimento Liquibook (eRPC), use o
valor de `ERPC_PORT_INDEX` (de `/local/rdma.env`) em `--numa_0_ports`.

---

## Referência

### Rodar o setup de novo

O CloudLab executa o `setup.sh` a cada boot, e cada etapa é marcada com um
arquivo em `/local/.mu-*` para não ser repetida. Para refazer uma etapa, apague o
marcador correspondente e rode o script com os mesmos argumentos do profile
(substitua `<i>` pelo índice do nó):

| Marcador | Etapa |
|---|---|
| `/local/.mu-kernel` | Instalação do kernel e reboot |
| `/local/.mu-pkgs` | Pacotes, gtest e Conan |
| `/local/.mu-cmake` | CMake 3.27.9 em `/opt/cmake` |
| `/local/.mu-ofed` | Mellanox OFED |

```bash
sudo rm /local/.mu-ofed
sudo /local/repository/setup.sh ib <i> 4.7-3.2.9.0 1 1 0 >> /local/setup.log 2>&1
```

Os ajustes de sistema, o clone do Mu (só se `/local/mu` não existir) e o
`rdma-info.sh` rodam sempre.

> Os ajustes de sistema (governor, `irqbalance`, hugepages) não persistem
> sozinhos, mas como o `setup.sh` roda a cada boot, eles são reaplicados depois
> de um reboot.

### Regenerar `/local/rdma.env`

```bash
sudo /local/repository/rdma-info.sh ib
```

### Problemas comuns

- **Porta IB não está `PORT_ACTIVE`**: o link InfiniBand precisa de um subnet
  manager. Confira com `ibstat` e, se necessário, reinicie o OFED com
  `sudo /etc/init.d/openibd restart`.
- **Kernel do artigo indisponível**: o log mostra
  `AVISO: kernel 4.15.0-72-generic indisponível` e o setup segue com o kernel
  atual. O OFED é recompilado para ele se preciso.
- **`build-mu.sh` falhou no Conan**: o build usa perfis do Conan 1.x. Confira com
  `conan --version` que a versão é menor que 2.
- **`The 'CMakeToolchain' generator only works with CMake >= 3.15`** (ao compilar
  `fmt` ou `spdlog`): o `cmake` em uso é o 3.10 do Ubuntu 18.04. O `setup.sh`
  instala o CMake 3.27.9 em `/usr/local/bin` (marcador `/local/.mu-cmake`).
  Confira com `which cmake && cmake --version`; se ainda for o 3.10, veja a
  linha "CMake" em `/local/setup.log` e rode o setup de novo.
