# Build an ARM64 Amphora image for Octavia
# We use Centos due to issues in building an Ubuntu AMR64 image
docker build ./amphora-image-centos-arm64-docker -t amphora-image-build-arm64

git clone https://opendev.org/openstack/octavia -b stable/ussuri
cd octavia
# diskimage-create.sh includes armhf but not arm64
git apply  ../0001-Add-arm64-in-diskimage-create.sh.patch
cd ..

docker run --privileged -v /dev:/dev -v $(pwd)/octavia/:/octavia -ti amphora-image-build-arm64

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