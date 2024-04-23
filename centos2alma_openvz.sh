#!/bin/bash

# Version 1.0b
# Usage: ./centos2alma_openvz.sh <CTID>

CTID=$1
AC_BIN=/root/almaconvert8-plesk

function install_almaconvert { 

    if rpm -q --quiet vzdeploy8 ; then 
        echo "Already have vzdeploy8. Skipping install..."
    else
        echo "Installing vzdeploy8 / almaconvert8 packages on local node..."
        yum install vzdeploy8 -y
        [ ! $? -eq 0 ] && echo "Unable to install vzdeploy8 / almaconvert8 packages. Exiting..." && exit 1
    fi

    # TODO: Do we still need to do this if we're removing Plesk packages prior to running almaconvert8 anyway?
    if [ ! -f "$AC_BIN" ]; then
        echo "Creating modified version of almaconvert8 to ignore Plesk blocker checks..."
        cp /usr/bin/almaconvert8 $AC_BIN
        sed -i -e "s/BLOCKER_PKGS = {'plesk': 'Plesk', 'cpanel': 'cPanel'}/BLOCKER_PKGS = {'cpanel': 'cPanel'}/g"  $AC_BIN
    fi

}

function ct_prepare {

    echo "Creating snapshot prior to any changes..."
    vzctl snapshot $CTID --name CentOS7PleskBeforeChanges
    
    echo "Updating all packages to CentOS 7.9"
    vzctl exec $CTID yum update -y

    echo "Creating database backup..."
    vzctl exec $CTID 'if [ -f /etc/psa/.psa.shadow ]; then mysqldump -uadmin -p$(cat /etc/psa/.psa.shadow) -f --events --max_allowed_packet=1G --opt --all-databases 2> /root/all_databases_error.log | gzip --rsyncable > /root/all_databases_dump.sql.gz && if [ -s /root/all_databases_error.log ]; then cat /root/all_databases_error.log | mail -s "mysqldump errors for $(hostname)" reports@websavers.ca; fi fi'; 

    vzctl exec $CTID systemctl stop mariadb

    echo "Removing packages that conflict with the almaconvert8 conversion process, including Plesk RPMs..."
    vzctl exec $CTID rpm -e btrfs-progs --nodeps
    vzctl exec $CTID rpm -e python3-pip --nodeps
    vzctl exec $CTID yum -y remove "plesk-*"
    vzctl exec $CTID rpm -e openssl11-libs --nodeps
    vzctl exec $CTID rpm -e MariaDB-server MariaDB-client MariaDB-shared MariaDB-common MariaDB-compat --nodeps
    vzctl exec $CTID rpm -e python36-PyYAML --nodeps

}

function ct_finish {

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
[ "$CTID" = "" ] && echo "The CTID paramter has NOT been provided. Exiting..." && exit 1
vzlist $CTID >/dev/null
[ ! $? -eq 0 ] && echo "CTID provided does not appear to be valid. Exiting..." && exit 1


# idiomatic parameter and option handling
while test $# -gt 0
do
    case "$1" in
        --finish) echo "Finish parameter provided. Running only post-conversion repairs..."
            ct_finish
            exit 0
            ;;
        --prepare) echo "Prepare parameter provided. Running only pre-conversion (destructive) changes..."
            ct_prepare
            exit 0
            ;;
        #--*) echo "bad option $1"
        #    ;;
        #*) echo "argument $1"
        #    ;;
    esac
    shift
done

# Install and modify necessary utilities
install_almaconvert

read -p "The following process will convert CTID $CTID to AlmaLinux 8 (destructive changes). Are you sure you're ready to proceed? (y/n) " -n 1 -r
echo
if ! [[ $REPLY =~ ^[Yy]$ ]] ; then
    exit
fi

echo "STAGE 1: Preparing container for conversion..."
ct_prepare

echo "STAGE 2: Conversion begins using almaconvert8. Do not interrupt unless failure reported."
$AC_BIN convert $CTID --log /root/almaconvert8-$CTID.log

echo "STAGE 3: Post-Conversion Repairs..."
ct_finish

echo "Conversion completed!"