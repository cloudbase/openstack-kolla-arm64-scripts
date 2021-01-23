sudo mkdir /etc/kolla/config/octavia
sudo tee /etc/kolla/config/octavia/octavia-worker.conf <<EOT
[controller_worker]
user_data_config_drive = true
EOT

# Follow the "Creating the Certificate Authorities" section of the Octavia documentation.
# Note: use the password retrieved above to protect the keys for both CAs
https://docs.openstack.org/octavia/victoria/admin/guides/certificates.html

# Let's copy the certificates to the location excpected by kolla-ansible:
sudo cp client_ca/certs/ca.cert.pem /etc/kolla/config/octavia/client_ca.cert.pem
sudo cp server_ca/certs/ca.cert.pem /etc/kolla/config/octavia/server_ca.cert.pem
sudo cp server_ca/private/ca.key.pem /etc/kolla/config/octavia/server_ca.key.pem
sudo cp client_ca/private/client.cert-and-key.pem /etc/kolla/config/octavia/client.cert-and-key.pem
sudo chown -R $USER:$USER /etc/kolla/config/octavia

# Build an ARM64 Amphora image for Octavia. Here are two alternatives: Centos or Ubuntu

# Centos
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Centos -t amphora-image-build-arm64-centos

# Ubuntu
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Ubuntu -t amphora-image-build-arm64-ubuntu

git clone https://opendev.org/openstack/octavia -b stable/ussuri
# Use latest branch Octavia to create Ubuntu image
cd octavia
# diskimage-create.sh includes armhf but not arm64
git apply  ../0001-Add-arm64-in-diskimage-create.sh.patch
cd ..

# Create CentOS 8 Amphora image
docker run --privileged -v /dev:/dev -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64-centos

# Create Ubuntu Focal Amphora image
On stable/ussuri, this requires a patch that fixes the Ubuntu image build:
pushd octavia
git fetch
git cherry-pick 70079d861db3c870710e817955b4c7572ecc217b
popd

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
rm octavia/diskimage-create/amphora-x64-haproxy.qcow2

# Disk size must at least match the image size
openstack flavor create --vcpus 1 --ram 1024 --disk 4 "amphora" --private

openstack keypair create --private-key octavia_ssh_key octavia_ssh_key

OCTAVIA_MGMT_SUBNET=192.168.43.0/24
OCTAVIA_MGMT_SUBNET_START=192.168.43.10
OCTAVIA_MGMT_SUBNET_END=192.168.43.254
OCTAVIA_MGMT_HOST_IP=192.168.43.1/24

VLAN_ID=107

# Note: if this fails with:
# Invalid input for operation: physical_network 'physnet1' unknown for VLAN provider network
# it that network_vlan_ranges was not set in ml2_conf.ini
openstack network create lb-mgmt-net --provider-network-type vlan --provider-segment $VLAN_ID --provider-physical-network physnet1
openstack subnet create --subnet-range $OCTAVIA_MGMT_SUBNET --allocation-pool \
  start=$OCTAVIA_MGMT_SUBNET_START,end=$OCTAVIA_MGMT_SUBNET_END \
  --network lb-mgmt-net lb-mgmt-subnet

openstack security group create lb-mgmt-sec-grp
openstack security group rule create --protocol icmp lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 22 lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 9443 lb-mgmt-sec-grp

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

docker exec openvswitch_vswitchd ovs-vsctl add-port br-ex v-lbaas-vlan tag=$VLAN_ID

# Update /etc/kolla/globals.yml
OCTAVIA_MGMT_NET_ID=$(openstack network show lb-mgmt-net --format value -c id)
OCTAVIA_MGMT_SEC_GROUP_ID=$(openstack security group show lb-mgmt-sec-grp --format value -c id)
OCTAVIA_MGMT_FLAVOR_ID=$(openstack flavor show amphora --format value -c id)

echo "enable_octavia: \"yes\"" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_network_interface: v-lbaas" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_amp_boot_network_list: $OCTAVIA_MGMT_NET_ID" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_amp_secgroup_list: $OCTAVIA_MGMT_SEC_GROUP_ID" | sudo tee -a /etc/kolla/globals.yml
echo "octavia_amp_flavor_id: $OCTAVIA_MGMT_FLAVOR_ID" | sudo tee -a /etc/kolla/globals.yml

# TODO: Check if a docker restart octavia_worker is enough
kolla-ansible -i all-in-one reconfigure

# Patch the user_data_config_drive_template
git apply  ../0001-Fix-userdata-template.patch
docker cp octavia/common/jinja/templates/user_data_config_drive.template \
    octavia_worker:/usr/lib/python3/dist-packages/octavia/common/jinja/templates/user_data_config_drive.template

# To create the loadbalancer
openstack loadbalancer create --name loadbalancer1 --vip-subnet-id public-subnet


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
