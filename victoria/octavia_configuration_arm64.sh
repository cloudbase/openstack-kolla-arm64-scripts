sudo mkdir /etc/kolla/config/octavia
sudo tee /etc/kolla/config/octavia/octavia-worker.conf << EOT
[controller_worker]
user_data_config_drive = true
EOT

# Change the following according to your organization
echo "octavia_certs_country: US" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_certs_state: Oregon" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_certs_organization: OpenStack" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_certs_organizational_unit: Octavia" | sudo tee -a /etc/kolla/globals.yml

cd kolla
source venv/bin/activate

sudo chown $USER:$USER /etc/kolla
kolla-ansible octavia-certificates

OCTAVIA_MGMT_SUBNET=192.168.43.0/24
OCTAVIA_MGMT_SUBNET_START=192.168.43.10
OCTAVIA_MGMT_SUBNET_END=192.168.43.254
OCTAVIA_MGMT_HOST_IP=192.168.43.1/24
OCTAVIA_MGMT_VLAN_ID=107

sudo tee -a /etc/kolla/globals.yml << EOT
octavia_amp_network:
  name: lb-mgmt-net
  provider_network_type: vlan
  provider_segmentation_id: $OCTAVIA_MGMT_VLAN_ID
  provider_physical_network: physnet1
  external: false
  shared: false
  subnet:
    name: lb-mgmt-subnet
    cidr: "$OCTAVIA_MGMT_SUBNET"
    allocation_pool_start: "$OCTAVIA_MGMT_SUBNET_START"
    allocation_pool_end: "$OCTAVIA_MGMT_SUBNET_END"
    gateway_ip: "$OCTAVIA_MGMT_HOST_IP"
    enable_dhcp: yes
EOT

# Flavor used when booting an amphora, change as needed
sudo tee -a /etc/kolla/globals.yml << EOT
octavia_amp_flavor:
  name: "amphora"
  is_public: no
  vcpus: 1
  ram: 1024
  disk: 5
EOT

# This sets up the VLAN veth interface
# Netplan doesn't have support for veth interfaces yet
sudo tee /usr/local/bin/veth-lbaas.sh << EOT
#!/bin/bash
sudo ip link add v-lbaas-vlan type veth peer name v-lbaas
sudo ip addr add $OCTAVIA_MGMT_HOST_IP dev v-lbaas
sudo ip link set v-lbaas-vlan up
sudo ip link set v-lbaas up
EOT
sudo chmod 744 /usr/local/bin/veth-lbaas.sh

sudo tee /etc/systemd/system/veth-lbaas.service << EOT
[Unit]
After=network.service

[Service]
ExecStart=/usr/local/bin/veth-lbaas.sh

[Install]
WantedBy=default.target
EOT
sudo chmod 644 /etc/systemd/system/veth-lbaas.service

sudo systemctl daemon-reload
sudo systemctl enable veth-lbaas.service
sudo systemctl start veth-lbaas.service

docker exec openvswitch_vswitchd ovs-vsctl add-port br-ex v-lbaas-vlan tag=$OCTAVIA_MGMT_VLAN_ID

echo "enable_octavia: \"yes\"" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_network_interface: v-lbaas" | sudo tee -a /etc/kolla/globals.yml

# Deploy all the changes
kolla-ansible -i all-in-one deploy --tags common,horizon,octavia

# Build an ARM64 Amphora image for Octavia. Here are two alternatives: Centos or Ubuntu

git clone https://github.com/cloudbase/openstack-kolla-arm64-scripts
cd openstack-kolla-arm64-scripts/victoria

# Centos
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Centos -t amphora-image-build-arm64-centos

# Ubuntu
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Ubuntu -t amphora-image-build-arm64-ubuntu

git clone https://opendev.org/openstack/octavia -b stable/victoria
# Use latest branch Octavia to create Ubuntu image
cd octavia
# diskimage-create.sh includes armhf but not arm64
git apply  ../0001-Add-arm64-in-diskimage-create.sh.patch
cd ..

# Create CentOS 8 Amphora image
docker run --privileged -v /dev:/dev -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64-centos

# Note the mount of /mnt and /proc in the docker container
# BEWARE!!!!!
# Without the mount of /proc, the diskimage-builder fails to find mount points and deletes the host's /dev,
# rendering the host unusable
docker run --privileged -v /dev:/dev -v /proc:/proc -v /mnt:/mnt -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64-ubuntu

. /etc/kolla/admin-openrc.sh

# Switch to the octavia user and service project
export OS_USERNAME=octavia
export OS_PASSWORD=$(grep octavia_keystone_password /etc/kolla/passwords.yml | awk '{ print $2}')
export OS_PROJECT_NAME=service
export OS_TENANT_NAME=service

openstack image create amphora-x64-haproxy.qcow2 \
--container-format bare \
--disk-format qcow2 \
--private \
--tag amphora \
--file octavia/diskimage-create/amphora-x64-haproxy.qcow2

# Delete the image file
rm -f octavia/diskimage-create/amphora-x64-haproxy.qcow2

# Patch the user_data_config_drive_template
cd octavia
git apply  ../0001-Fix-userdata-template.patch
docker cp octavia/common/jinja/templates/user_data_config_drive.template \
    octavia_worker:/usr/lib/python3/dist-packages/octavia/common/jinja/templates/user_data_config_drive.template

# To create the loadbalancer
. /etc/kolla/admin-openrc.sh

openstack loadbalancer create --name loadbalancer1 --vip-subnet-id public1-subnet

# Check status until it's marked as ONLINE
openstack loadbalancer list

# Troubleshooting

# Check for errors
sudo tail -f /var/log/kolla/octavia/octavia-worker.log

# SSH into amphora
# Get amphora VM IP either from the octavia-worker.log or from:
openstack server list --all-projects

ssh ubuntu@<amphora_ip> -i octavia_ssh_key #ubuntu
ssh cloud-user@<amphora_ip> -i octavia_ssh_key #centos

# Instances stuck in pending create cannot be deleted
# Password: grep octavia_database_password /etc/kolla/passwords.yml
docker exec -ti mariadb mysql -u octavia -p octavia
update load_balancer set provisioning_status = 'ERROR' where provisioning_status = 'PENDING_CREATE';
exit;
