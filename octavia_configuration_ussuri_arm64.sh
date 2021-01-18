# Build an ARM64 Amphora image for Octavia. Here are two alternatives: Centos or Ubuntu

# Centos
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Centos -t amphora-image-build-arm64

# Ubuntu
docker build amphora-image-arm64-docker -f amphora-image-arm64-docker/Dockerfile.Ubuntu -t amphora-image-build-arm64

git clone https://opendev.org/openstack/octavia -b stable/ussuri
# Use latest branch Octavia to create Ubuntu image
cd octavia
# diskimage-create.sh includes armhf but not arm64
git apply  ../0001-Add-arm64-in-diskimage-create.sh.patch
cd ..

# Create CentOS 8 Amphora image
docker run --privileged -v /dev:/dev -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64

# To create Ubuntu images, you need to create the image on an Ubuntu VM
# on KVM ARM64, using an ARM64 Ubuntu cloud image for that VM.
# This is due to unsupported diskimage-builder grub layout for the EMAG ARM64 EFI grub layout.

# Create Ubuntu Focal Amphora image
# Note the mount of /mnt and /proc in the docker container
# BEWARE!!!!!
# Without the mount of /proc, the diskimage-builder fails to find mount points and deletes the host's /dev,
# rendering the host unusable
# docker run --privileged -v /dev:/dev -v /proc:/proc -v /mnt:/mnt -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64-ubuntu

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
docker restart octavia_worker

# To create the loadbalancer
openstack loadbalancer create --name loadbalancer1 --vip-subnet-id public-subnet
