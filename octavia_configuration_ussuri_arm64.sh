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

# Make sure that in the kolla octavia worker config, [controller_worker] section,
# the correct network, public key, flavors and certificate paths are set.
# Also, set user_data_config_drive = True so that cloud-init can write the
# amphora agent configuration file and certificates at amphora boot time.

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
