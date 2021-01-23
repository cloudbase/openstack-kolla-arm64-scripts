# kolla-ansible
sudo apt update
sudo apt install -y qemu-kvm docker-ce
sudo apt install -y python3-dev libffi-dev gcc libssl-dev python3-venv
sudo apt install -y nfs-kernel-server

sudo usermod -aG docker $USER
newgrp docker

mkdir kolla
cd kolla

python3 -m venv venv
source venv/bin/activate

pip install -U pip
pip install 'ansible<2.10'
pip install 'kolla-ansible>=10,<11'

sudo mkdir -p /etc/kolla/config
sudo cp -r venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla
sudo chown -R $USER:$USER /etc/kolla
cp venv/share/kolla-ansible/ansible/inventory/* .

# Check if Ansible is properly setup
ansible -i all-in-one all -m ping

# If running on a Ubuntu 20.04 host, add "focal", after "bionic" in:
# vi venv/share/kolla-ansible/ansible/roles/prechecks/vars/main.yml

kolla-genpwd

# edit /etc/kolla/globals.yml and set:
#  kolla_base_distro: "ubuntu"
#  openstack_tag: 10.1.1
#  kolla_internal_vip_address: # An unallocated IP address in your network
#  network_interface: # your management interface
#  neutron_external_interface: #Your external interface
#  enable_cinder: "yes"
#  enable_cinder_backend_nfs: "yes"
#  enable_barbican: "yes"
#  enable_neutron_provider_networks: yes

# docker_registry: $ACR_NAME.azurecr.io
# docker_registry_username: $SP_APP_ID_PULL_ONLY

# if there are multiple deployments with kolla,
# set another keepalived_virtual_router_id
# keepalived_virtual_router_id = 101

# Edit /etc/kolla/passwords.yml and set:
# docker_registry_password: $SP_PASSWD_PULL_ONLY

# Cinder NFS setup
# Your local IP
CINDER_NFS_HOST="10.0.0.1"
# Replace with your local network CIDR if you plan to add more nodes
CINDER_NFS_ACCESS=$CINDER_NFS_HOST
sudo mkdir /kolla_nfs
echo "/kolla_nfs $CINDER_NFS_ACCESS(rw,sync,no_root_squash)" | sudo tee -a /etc/exports
echo "$CINDER_NFS_HOST:/kolla_nfs" | sudo tee -a /etc/kolla/config/nfs_shares
sudo systemctl restart nfs-kernel-server

# Increase the PCIe ports to avoid this error when creating Octavia pool members:
# libvirt.libvirtError: internal error: No more available PCI slots
sudo mkdir /etc/kolla/config/nova
sudo tee /etc/kolla/config/nova/nova-compute.conf <<EOT
[DEFAULT]
resume_guests_state_on_host_boot = true

[libvirt]
num_pcie_ports=28
EOT

# This is needed for Octavia
sudo mkdir /etc/kolla/config/neutron
sudo tee /etc/kolla/config/neutron/ml2_conf.ini <<EOT
[ml2_type_vlan]
network_vlan_ranges = physnet1:100:200
EOT

kolla-ansible -i ./all-in-one prechecks
kolla-ansible -i ./all-in-one bootstrap-servers
kolla-ansible -i ./all-in-one deploy

# when done:
pip3 install python-openstackclient python-barbicanclient python-heatclient python-octaviaclient
kolla-ansible post-deploy

# Load the vars to access the OpenStack environment
. /etc/kolla/admin-openrc.sh
# Create sample images, networks, etc

# Set you external netwrork CIDR, range and gateway, matching your environment, e.g.:
export EXT_NET_CIDR='10.0.2.0/24'
export EXT_NET_RANGE='start=10.0.2.150,end=10.0.2.199'
export EXT_NET_GATEWAY='10.0.2.1'
./venv/share/kolla-ansible/init-runonce

# Create a demo VM
openstack server create --image cirros --flavor m1.tiny --key-name mykey --network demo-net demo1

# To clean up:
kolla-ansible -i ./all-in-one destroy --yes-i-really-really-mean-it
