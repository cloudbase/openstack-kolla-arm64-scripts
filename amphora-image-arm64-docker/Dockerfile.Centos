FROM centos:8

RUN dnf -y install epel-release
RUN dnf -y install debootstrap python3 qemu-img sudo git yum-utils gdisk kpartx e4fsprogs dosfstools
RUN python3 -m pip install diskimage-builder

WORKDIR /octavia/diskimage-create

ENV DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack" 
CMD ./diskimage-create.sh -a arm64 -i centos-minimal -s 3
