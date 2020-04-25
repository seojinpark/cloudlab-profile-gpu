"""
Profile for GPU servers with rcnfs and remote dataset

Instructions:
    TODO
"""

import geni.portal as portal
import geni.rspec.pg as RSpec
import geni.urn as urn
import geni.aggregate.cloudlab as cloudlab
# Emulab specific extensions.
import geni.rspec.emulab as emulab

pc = portal.Context()

images = [ ("UBUNTU18-64-STD", "Ubuntu 18.04") ]

types = [ ("c240g5", "c240g5 (NVIDIA 12GB P100 GPU, dual-port 10Gb NIC)"),
          ("c4130", "c4130 (4x NVIDIA 16GB Tesla V100 GPU, no networking?)"),
          ("c220g2", "c220g2 (for NFS node, no GPU)"), ("c220g5", "c220g5 (for NFS node, no GPU)")]

num_nodes = range(1, 32)

pc.defineParameter("image", "Disk Image",
                   portal.ParameterType.IMAGE, images[0], images)

pc.defineParameter("type", "Node Type",
                   portal.ParameterType.NODETYPE, types[0], types)

pc.defineParameter("num_nodes", "# Nodes",
                   portal.ParameterType.INTEGER, 1, num_nodes)

pc.defineParameter("rcnfs", "Setup an extra node for NFS?",
                   portal.ParameterType.BOOLEAN, False, [True, False])
                   
pc.defineParameter("type4nfs", "Node Type for NFS server",
                   portal.ParameterType.NODETYPE, types[0], types)

params = pc.bindParameters()

rspec = RSpec.Request()

lan = RSpec.LAN()
rspec.addResource(lan)

if params.rcnfs == True:
    node = RSpec.RawPC("rcnfs")

    # Ask for a 200GB file system mounted at /shome on rcnfs
    bs = node.Blockstore("bs", "/shome")
    bs.size = "400GB"

    node.hardware_type = params.type4nfs
    node.disk_image = 'urn:publicid:IDN+emulab.net+image+emulab-ops:' + params.image

    cmd_string = "sudo /local/repository/startup.sh"
    node.addService(RSpec.Execute(shell="sh", command=cmd_string))

    rspec.addResource(node)

    iface = node.addInterface("eth0")
    lan.addInterface(iface)
    
node_names = []    
for i in range(1, params.num_nodes + 1):
    node_names.append("rc%02d" % i)

for name in node_names:
    node = RSpec.RawPC(name)
    
    bs = node.Blockstore("bs","/users")
    bs.size = "300GB"

    node.hardware_type = params.type
    node.disk_image = 'urn:publicid:IDN+emulab.net+image+emulab-ops:' + params.image
    
    # The remote file system is represented by special node.
    fsnode = rspec.RemoteBlockstore("fsnode", "/data")
    # This URN is displayed in the web interfaace for your dataset.
    fsnode.dataset = "urn:publicid:IDN+wisc.cloudlab.us:ramcloud-pg0+ltdataset+Pipedream"
    fsnode.rwclone = True

    cmd_string = "sudo /local/repository/startup.sh"
    node.addService(RSpec.Execute(shell="sh", command=cmd_string))

    rspec.addResource(node)

    iface = node.addInterface("eth0")
    lan.addInterface(iface)
    
    # fslink = rspec.Link("fslink")
#     fslink.addInterface(iface)
#     fslink.addInterface(fsnode.interface)
    lan.addInterface(fsnode.interface)
    # # Special attributes for this link that we must use.
    # fslink.best_effort = True
    # fslink.vlan_tagging = True


pc.printRequestRSpec(rspec)