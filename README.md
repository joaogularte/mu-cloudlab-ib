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
`using_conan_fully`, que gera os binários do Mu standalone (`main-st` e
`main-st-lat`, em `/local/mu/crash-consensus/demo/using_conan_fully/build/bin`).
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

Rode o teste com `numactl`, fixando CPU e memória no nó NUMA da NIC
(`$RDMA_NUMA`, de `/local/rdma.env`). Sem isso, cada processo pode cair no
socket errado e a latência muda de uma execução para outra.

No `node1` (servidor):

```bash
numactl --cpunodebind=$RDMA_NUMA --membind=$RDMA_NUMA \
  ib_write_lat -d $RDMA_DEV -i $RDMA_PORT -s 64 -n 100000
```

No `node0` (cliente):

```bash
numactl --cpunodebind=$RDMA_NUMA --membind=$RDMA_NUMA \
  ib_write_lat -d $RDMA_DEV -i $RDMA_PORT -s 64 -n 100000 10.10.1.2
```

### 6. Iniciar o registro e rodar os experimentos

O `setup.sh` para o serviço `memcached` do sistema de propósito, porque o
registro do Mu é iniciado à mão no `node3`:

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
