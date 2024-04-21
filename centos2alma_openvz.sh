#!/bin/bash

# Version 1.0b
# Usage: bash centos2alma_openvz.sh [CTID]

CTID=$1

function install_almaconvert { 
    echo "Installing virtuozzo packages..."
    yum install vzdeploy8 -y
    [ ! $? -eq 0 ] && echo "Unable to install vzdeploy8 / almaconvert8 packages. Exiting..." && exit 1

    echo "Creating modified version of almaconvert8 to ignore Plesk..."
    cp /usr/bin/almaconvert8 /root/almaconvert8-plesk
    sed -i -e "s/BLOCKER_PKGS = {'plesk': 'Plesk', 'cpanel': 'cPanel'}/BLOCKER_PKGS = {'cpanel': 'cPanel'}/g"  /root/almaconvert8-plesk
}

function ct_database_backup {
    echo "Creating database backup..."
    vzctl exec $CTID 'if [ -f /etc/psa/.psa.shadow ]; then mysqldump -uadmin -p$(cat /etc/psa/.psa.shadow) -f --events --max_allowed_packet=1G --opt --all-databases 2> /root/all_databases_error.log | gzip --rsyncable > /root/all_databases_dump.sql.gz && if [ -s /root/all_databases_error.log ]; then cat /root/all_databases_error.log | mail -s "mysqldump errors for $(hostname)" reports@websavers.ca; fi fi'; 
}

function ct_prepare {

    echo "Creating snapshot prior to any changes..."
    vzctl snapshot $CTID --name CentOS7PleskBeforeChanges
    
    echo "Updating all packages to CentOS 7.9"
    vzctl exec $CTID yum update -y

    ct_database_backup

    vzctl exec $CTID systemctl stop mariadb

    echo "Removing conflicting packages, including Plesk packages..."
    vzctl exec $CTID rpm -e btrfs-progs --nodeps
    vzctl exec $CTID rpm -e python3-pip --nodeps
    vzctl exec $CTID yum -y remove "plesk-*"
    vzctl exec $CTID rpm -e openssl11-libs --nodeps
    vzctl exec $CTID rpm -e MariaDB-server MariaDB-client MariaDB-shared MariaDB-common MariaDB-compat --nodeps
    vzctl exec $CTID rpm -e python36-PyYAML --nodeps

}

function reinstall_mariadb {
    vzctl exec $CTID curl -LsS -O https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
    vzctl exec $CTID bash mariadb_repo_setup --mariadb-server-version=10.11
    vzctl exec $CTID yum -y install boost-program-options MariaDB-server MariaDB-client MariaDB-shared
    vzctl exec $CTID 'yum -y update MariaDB-server MariaDB-client MariaDB-shared MariaDB-*'
    # Restore original config
    vzctl exec $CTID mv /etc/my.cnf /etc/my.cnf.rpmnew
    vzctl exec $CTID mv /etc/my.cnf.rpmsave /etc/my.cnf
    vzctl exec $CTID systemctl restart mariadb
    vzctl exec $CTID mysql_upgrade
}

#### STANDARD PROCESSING BEGINS HERE ####

# Check OS
source /etc/os-release
[ "$NAME" != "Virtuozzo" ] && echo "This must be run on an OpenVZ node, not within the container. Exiting..." && exit 1

# Verify validity of CTID
[ "$CTID" = "" ] && echo "No CTID paramters has been provided. Exiting..." && exit 1
vzlist $CTID >/dev/null
[ ! $? -eq 0 ] && echo "CTID provided does not appear to be valid. Exiting..." && exit 1

read -p "This will convert CTID $CTID to AlmaLinux 8. Are you sure you're ready to proceed? (y/n) " -n 1 -r
echo
if ! [[ $REPLY =~ ^[Yy]$ ]] ; then
    exit
fi

echo "STAGE 1: Installing almaconvert8 utility"
if [ ! -f "/root/almaconvert8-plesk" ]; then
   install_almaconvert
fi

read -p "Stages 2 and 3 are destructive. Ready to proceed? (y/n) " -n 1 -r
echo
if ! [[ $REPLY =~ ^[Yy]$ ]] ; then
    exit
fi

echo "STAGE 2: Preparing container for conversion (destructive - removes packages)"
ct_prepare

echo "STAGE 3: Conversion now in progress using almaconvert8. Do not interrupt unless failure reported."
almaconvert8-plesk convert $CTID --log /root/almaconvert8-$CTID.log

echo "STAGE 4: Post-Conversion Repairs"
vzctl exec $CTID yum install python3
vzctl exec $CTID sed -i -e 's/CentOS-7/RedHat-el8/g' /etc/yum.repos.d/plesk*
vzctl exec $CTID yum update -y

reinstall_mariadb

# Reload Plesk DB from backup (not certain we need this)
# vzctl exec $CTID 'zcat /var/lib/psa/dumps/mysql.plesk.core.prerm.18.0.60.20240419-175324.dump.gz | MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql -uadmin'

echo "Reinstalling base Plesk packages..."

vzctl exec $CTID "echo '[PSA_18_0_60-base]
name=PLESK_18_0_60 base
baseurl=http://autoinstall.plesk.com/pool/PSA_18.0.60_14244/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1
' > /etc/yum.repos.d/plesk-base-tmp.repo"

vzctl exec $CTID yum install plesk-release plesk-engine plesk-completion psa-autoinstaller psa-libxml-proxy plesk-repair-kit plesk-config-troubleshooter psa-updates psa-phpmyadmin

echo "Running Plesk Repair..."
vzctl exec $CTID plesk repair installation

echo "Cleaning up..."
vzctl exec $CTID rm -f /etc/yum.repos.d/plesk-base-tmp.repo
vzctl exec $CTID yum remove firewalld

echo "Conversion completed!"