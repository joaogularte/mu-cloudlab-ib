# -*- coding: utf-8 -*-
"""Mu (OSDI'20) sobre RDMA InfiniBand: 4 nos c6220 no cluster Apt.

Quatro nos bare-metal com InfiniBand nativo (Mellanox ConnectX-3 FDR 56 Gbps),
Ubuntu 18.04 e Mellanox OFED 4.7-3.2.9.0. E o unico lugar do CloudLab com
InfiniBand nativo hoje. O codigo original do Mu roda aqui sem modificacoes.

Instructions:
Quando o experimento ficar "Ready", acompanhe /local/setup.log em cada no: a
instalacao do OFED leva alguns minutos, e o no reinicia uma vez se a fixacao do
kernel estiver ligada. Ao final, o log mostra a porta escolhida, e as variaveis
ficam em /local/rdma.env:

  source /local/rdma.env && cat /local/rdma.env
  ibv_devinfo -d $RDMA_DEV | grep -E "state|link_layer|active_mtu"   # InfiniBand, PORT_ACTIVE
  /local/repository/check-net.sh

Compile o Mu em cada no com o seu usuario: /local/repository/build-mu.sh

Papeis (como no README do Mu): node0..node2 sao as replicas (SID 1..3); node3 e
o cliente e roda o registro memcached (DORY_REGISTRY_IP=10.10.1.4:9999). O
codigo fica em /local/mu.

Calibracao (recomendado para comparar com o profile RoCE): no node1 rode
`ib_write_lat -d $RDMA_DEV -i $RDMA_PORT -s 64 -n 100000` e, no node0, o mesmo
comando seguido de `10.10.1.2`.
"""

import geni.portal as portal
import geni.rspec.pg as pg

APT = "urn:publicid:IDN+apt.emulab.net+authority+cm"

pc = portal.Context()

pc.defineParameter(
    "nodeCount", "Numero de nos", portal.ParameterType.INTEGER, 4,
    longDescription="O artigo usa 4 maquinas: 3 replicas + 1 cliente/registro.")
pc.defineParameter(
    "osImage", "Imagem de disco", portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU18-64-STD",
    longDescription="Ubuntu 18.04, como no artigo.")
pc.defineParameter(
    "ofedVersion", "Versao do Mellanox OFED", portal.ParameterType.STRING,
    "4.7-3.2.9.0", longDescription="A versao do artigo; ainda suporta ConnectX-3 (mlx4).")
pc.defineParameter(
    "pinKernel", "Tentar fixar o kernel 4.15.0-72-generic (versao do artigo)",
    portal.ParameterType.BOOLEAN, True)
pc.defineParameter(
    "cloneMu", "Clonar LPD-EPFL/mu em /local/mu", portal.ParameterType.BOOLEAN, True)

params = pc.bindParameters()
if params.nodeCount < 4:
    pc.reportWarning(portal.ParameterWarning(
        "Os experimentos do artigo usam 4 nos (3 replicas + cliente).", ["nodeCount"]))
pc.verifyParameters()

request = pc.makeRequestRSpec()

# LAN Ethernet (fabric "commodity" de 10 Gbps do Apt) para o trafego TCP:
# registro memcached e clientes Redis/memcached. O RDMA do Mu vai pela porta
# InfiniBand diretamente, enderecado por LID, sem passar por esta LAN.
lan = request.LAN("lan")
lan.best_effort = True

for i in range(params.nodeCount):
    node = request.RawPC("node%d" % i)
    node.component_manager_id = APT
    # c6220: 2 sockets (o Mu usa numactl --membind 0), 64 GB e uma unica porta
    # ConnectX-3 FDR. O r320 tem uma porta Ethernet ativa no mesmo device, que
    # o Mu pode escolher no lugar da porta IB.
    node.hardware_type = "c6220"
    node.disk_image = params.osImage
    iface = node.addInterface("if1")
    iface.addAddress(pg.IPv4Address("10.10.1.%d" % (i + 1), "255.255.255.0"))
    lan.addInterface(iface)
    node.addService(pg.Execute(
        shell="bash",
        command="sudo /local/repository/setup.sh ib %d %s %d %d 0 >> /local/setup.log 2>&1" % (
            i, params.ofedVersion, int(params.pinKernel), int(params.cloneMu))))

pc.printRequestRSpec(request)