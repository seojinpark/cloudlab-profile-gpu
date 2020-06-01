#!/bin/bash

# Log output of this script to syslog.
# https://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Variables
echo $* | grep -q "mlnx-dpdk" && MLNX_DPDK=yes || MLNX_DPDK=no
HOSTNAME=$(hostname -f | cut -d"." -f1)
HW_TYPE=$(geni-get manifest | grep $HOSTNAME | grep -oP 'hardware_type="\K[^"]*')
SHARED_HOME="/shome"
USERS="root `ls /users`"
RC_NODE=`hostname --short`

# Test if startup service has run before.
# TODO: why?
if [ -f /local/startup_service_done ]; then
    date >> /local/startup_service_exec_times.txt
    exit 0
fi

# Skip any interactive post-install configuration step:
# https://serverfault.com/q/227190
export DEBIAN_FRONTEND=noninteractive

# Install packages
echo "Installing common utilities"
apt-get update
apt-get -yq install ccache htop mosh vim tmux pdsh tree axel

echo "Installing NFS"
apt-get -yq install nfs-kernel-server nfs-common

echo "Installing performance tools"
kernel_release=`uname -r`
apt-get -yq install linux-tools-common linux-tools-${kernel_release} \
        hugepages cpuset msr-tools i7z numactl tuned

# Install crontab job to run the following script every time we reboot:
# https://superuser.com/questions/708149/how-to-use-reboot-in-etc-cron-d
echo "@reboot root /local/repository/boot-setup.sh" > /etc/cron.d/boot-setup

# Setup password-less ssh between nodes
for user in $USERS; do
    if [ "$user" = "root" ]; then
        ssh_dir=/root/.ssh
    else
        ssh_dir=/users/$user/.ssh
    fi
    pushd $ssh_dir
    /usr/bin/geni-get key > geni-key
    cp geni-key id_rsa
    chmod 600 id_rsa
    chown $user: id_rsa
    ssh-keygen -y -f id_rsa > id_rsa.pub
    cp id_rsa.pub authorized_keys2
    chmod 644 authorized_keys2
    cat >>config <<EOL
    Host *
         StrictHostKeyChecking no
EOL
    chmod 644 config
    popd
done

# Change user login shell to Bash
for user in `ls /users`; do
    chsh -s `which bash` $user
done

# Fix "rcmd: socket: Permission denied" when using pdsh
echo ssh > /etc/pdsh/rcmd_default

# Configure 4K 2MB huge pages permanently.
echo "vm.nr_hugepages=4096" >> /etc/sysctl.conf

if [ "$RC_NODE" = "rcnfs" ]; then
    # Setup nfs server following instructions from the links below:
    #   https://vitux.com/install-nfs-server-and-client-on-ubuntu/
    #   https://linuxconfig.org/how-to-configure-a-nfs-file-server-on-ubuntu-18-04-bionic-beaver
    # In `cloudlab-profile.py`, we already asked for a temporary file system
    # mounted at /shome.
    chmod 777 $SHARED_HOME
    echo "$SHARED_HOME *(rw,sync,no_root_squash)" >> /etc/exports

    # Enable nfs server at boot time.
    # https://www.shellhacks.com/ubuntu-centos-enable-disable-service-autostart-linux/
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server

    # Generate a list of machines in the cluster
    cd $SHARED_HOME
    > rc-hosts.txt
    let num_rcxx=$(geni-get manifest | grep -o "<node " | wc -l)-1
    for i in $(seq "$num_rcxx")
    do
        printf "rc%02d\n" $i >> rc-hosts.txt
    done
    printf "rcnfs\n" >> rc-hosts.txt
else
    # NFS clients setup: use the publicly-routable IP addresses for both the server
    # and the clients to avoid interference with the experiment.
    rcnfs_ip=`geni-get manifest | grep rcnfs | egrep -o "ipv4=.*" | cut -d'"' -f2`
    mkdir $SHARED_HOME
    echo "$rcnfs_ip:$SHARED_HOME $SHARED_HOME nfs4 rw,sync,hard,intr,addr=`hostname -i` 0 0" >> /etc/fstab
fi

echo "Install additional packages"
for installer in /local/repository/installers/*; do
    /bin/sh $installer
done

if [ "$HW_TYPE" = "c240g5" ]; then
    echo "Install machine learning stuffs.."
    sudo apt --yes install ubuntu-drivers-common
    # sudo ubuntu-drivers autoinstall
    sudo apt-get --yes install freeglut3 freeglut3-dev libxi-dev libxmu-dev
    sudo apt --yes install python3-pip
    curl -O https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    sh Miniconda3-latest-Linux-x86_64.sh -b
    source $HOME/miniconda3/bin/activate
    printf '\n# add path to conda\nexport PATH="$HOME/miniconda3/bin:$PATH"\n' >> ~/.bashrc
    conda install -y pytorch torchvision cudatoolkit=10.2 -c pytorch
    # Install CUDA.
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/cuda-ubuntu1804.pin
    sudo mv cuda-ubuntu1804.pin /etc/apt/preferences.d/cuda-repository-pin-600
    sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
    sudo add-apt-repository "deb http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/ /"
    sudo apt-get update
    sudo apt-get -y install cuda
    # Create a simlink to docker..
    mkdir /data/docker
    sudo ln -s /data/docker /var/lib/docker
fi

# Mark the startup service has finished
> /local/startup_service_done
echo "Startup service finished"

if [ "$HW_TYPE" = "c240g5" ]; then
    # Install Pipedream
    cd /data/pipedream/
    bash setup.sh
fi

# Reboot to let the configuration take effects; this task is launched as a
# background process and delayed 10s to allow the startup service finished.
# TODO: maybe we can now remove the redundant startup service check at the top?
sleep 10s && reboot &

