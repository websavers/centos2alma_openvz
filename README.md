# Requirements

**PHP 7.1+**: This script will switch any sites using PHP earlier than 7.1 to PHP 7.1 (which is required for AlmaLinux 8), however the reliability of that switch hasn't been confirmed. 

It is *strongly* recommended that you manually switch all sites to PHP version 7.1 or newer prior to conversion so you can check to ensure the sites are compatible. If you're using 3rd party PHP versions of 7.0 or lower, you'll likely need to reinstall those after, then switch the sites back manually.

We also strongly recommend ensuring that php handlers are working smoothly prior to conversion with these commands:

```
plesk repair web -php-handlers
plesk repair web -php-fpm-configuration
```

If issues are encountered with PHP handlers in the --finish stage, it can supremely mess with plesk repairs.

**OpenVZ 7.0.21+**: We have tested and confirmed the conversion process works with:
- OpenVZ 7.0.21 (Virtuozzo Hybrid Server 7.5 Update 6 Hotfix 1 - Version 7.5.6-112)
- OpenVZ 7.0.22
- Plesk 17.0.60
- Plesk 17.0.65
- CentOS 7.9 stock
- CentOS 7.9 with Tuxcare Repos (Nov 2024, version 1.7) 

Any version of OpenVZ or Virtuozzo older than what's noted above is not likely to work. You should update all packages on both the node and the container prior to conversion. 

**TOMCAT NOTE**: if you use tomcat, it will be removed prior to conversion because it breaks the conversion process. You will need to manually re-install it after conversion and will probably need to restore its configuration files.

**DOCKER NOTE**: if you use docker-ce package, it will be removed prior to conversion. If you're using docker through Plesk, it should automatically re-install after conversion. If you were using this manually, you'll need to manually install it.

# Usage

Check to be sure the container is recognized as convertible by almaconvert8:

```
./centos2alma_openvz.sh $CTID --check
```

If all is well, begin conversion:

```
./centos2alma_openvz.sh $CTID
```

During the run of almaconvert8 you will probably see the following warnings. Ones about Plesk repos can be safely ignored:
> Warning! Unsupported repositories detected

The --convert stage using almaconvert8 *can appear to hang for several minutes at a time*. In particular after adjusting some packages it will say "Complete!" and look like it's doing nothing. Do not interrupt it. This is normal and will proceed typically after about 3-5 minutes, possibly longer.

Logs from almaconvert8 will be stored in /root/almaconvert8-$CTID.log

The process takes approximately 35-60 minutes, mostly depending on a the number of sites hosted.

## After Conversion

The following sections are actions you might wish to take after conversion.

### Re-enable IP Address Banning / Fail2ban?

If you had it enabled prior to conversion, you should re-enable it now: `systemctl restart fail2ban`

### Removing snapshots after successful conversion

IMPORTANT: Once you have confirmed the conversion has been successul and you do not need to reset to the CentOS 7 snapshot, run these commands to delete the snapshots created by this process:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
# You probably need to do this part twice:
SNAP_ID=put_snapshot_id_here
vzctl snapshot-delete $CTID --id $SNAP_ID
```

### TuxCare Licenses

We remove the TuxCare repos to ensure everything works smoothly after conversion, however you will likely want to ensure to cancel any
such licenses, whether through Plesk or TuxCare/CloudLinux directly. Note: in our testing, Plesk *appears* to automatically cancel any TuxCare licenses through them upon license refresh.

### Old Packages

You may also wish to remove old centos7 packages within the container. This is totally optional. If you don't remove them, everything could work fine still, or it could result in package update conflicts with future updates.

- You can run the following to see ones you have installed still: `rpm -qa | grep el7`
- The following will show you possible replacement packages in the AlmaLinux 8 repositories: `yum list <package_name> --showduplicates`
- You can then either remove it or install the precise version you want (from correct repo) with this: `yum install <package_name>-<version>`
- If you want to be certain a package can be removed because it has no dependencies, rum `rpm -e <package_name>` and it will remove it if nothing depends on it.

Here's an example of removal of some we found that had no dependencies for us, but might for you:
```
yum remove python-inotify python-dateutil pyxattr pyparsing alt-nghttp2 yum-metadata-parser python-gobject-base python-kitchen python-ply mozjs17 python-pycurl python-urlgrabber dbus-python python-iniparse python-enum34 python-decorator python-IPy pyliblzma pygpgme nginx-filesystem
```

### Using SolusVM?

For those using SolusVM, Install their DB helper script, then run these on your master to update the OS name. Be sure to replace HOSTNAME with the actual hostname of the container.
```
curl -o /root/solusvmdb.sh https://raw.githubusercontent.com/solusvm-support/helpers/master/solusvmdb.sh
bash /root/solusvmdb.sh
update vservers set templatename="almalinux-8-x86_64-ez" where hostname="HOSTNAME";
```

### Using WHMCS?

For those using WHMCS, you will want to adjust the OS template configurable option there as well.

# Conversion Failure? Revert to snapshot

In the event of failure, there are two snapshots you can revert to:

1. The first is taken before any changes are made at all, and
2. The second is taken by the almaconvert8 utility *after* conflicting packages are removed, but before the actual conversion occurs.

To revert to the first/earliest snapshot, simply run:
`./centos2alma_openvz.sh $CTID --revert`

***IMPORTANT: this will delete all snapshots after successful reversion.***

If you wish to avoid deletion of the snapshots, please use the steps below to manually switch to the snapshot of choice.
---

To revert to the second one, run this to get their IDs:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
```

Run this to save the ID of the snapshot you want to restore to:
`SNAP_ID=put_snapshot_id_here`

Then switch to that snapshot and start the container:
```
vzctl snapshot-switch $CTID --id $SNAP_ID --skip-resume
vzctl start $CTID
```

Once you have confirmed the container is back to the original state, delete the snapshot:
`vzctl snapshot-delete $CTID --id $SNAP_ID`

# Troubleshooting Tips

### Distro-Sync failure

1. Look back in the output for the yum errors that prevented distro-sync from completing.
2. Fix yum reported issues (ex: remove conflicting packages) 
3. Re-run vzctl exec $CTID yum -y distro-sync --disablerepo=epel
4. Run the --finish stage manually

### Initial snapshot error and exit

Most snapshot errors can be resolved by restarting the container via vzctl.

### If the almalinux GPG key fails to download

Germany is likely blocked by your firewall rules.

### If almaconvert8 fails with an error like this: 

`Failed to get VM config: The virtual machine could not be found. The virtual machine is not registered in the virtual machine directory on this server. Contact your Virtuozzo administrator for assistance.`

This means the container does not use a newer UUID CTID *and* the NAME of the container does not match the CTID. When at least one of either the UUID (longer CTIDs) or the NAME (shorter CTIDs, often resulting from a conversion from OpenVZ 6) do not match up with the CTID you've provided, prlctl fails to work on the container, which makes almaconvert8 fail since it relies upon it. To fix it run this (setting $CTID to the CTID):

`vzctl set $CTID --name=$CTID --save`

### nginx refuses to start after conversion

Reinstall the nginx plesk component like this within the container:
```
plesk installer remove --components nginx
plesk installer add --components nginx
```
You may then also need to enable it with this: `plesk sbin nginxmng --enable`

### General Troubleshooting

You can run each stage of this separately, so if any one part fails, you can re-run just that stage or start from the next if you've fixed the issue manually. Here are the stages:

Check if the almaconvert8 utility says it can be converted:
```
./centos2alma_openvz.sh $CTID --check
```

Snapshot and remove conflicting packages like Plesk and MariaDB:
```
./centos2alma_openvz.sh $CTID --prepare
```

Run almaconvert8 (also creates a snapshot of its own):
```
./centos2alma_openvz.sh $CTID --convert
```

After conversion, reinstall MariaDB and Plesk packages and restore configurations:
```
./centos2alma_openvz.sh $CTID --finish
```

# References
- almaconvert8: https://docs.virtuozzo.com/virtuozzo_hybrid_server_7_users_guide/advanced-tasks/converting-containers-with-almaconvert8.html
- centos2alma Plesk repo issue: https://github.com/plesk/centos2alma/issues/87
- Plesk Forum thread: https://talk.plesk.com/threads/upgrade-virtuozzo-container-from-centos-7.369729/