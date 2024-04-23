# Usage
`./centos2alma_openvz.sh <CTID>`

IMPORTANT: Once you have confirmed the conversion has been successul and you do not need to reset to the CentOS 7 snapshot, run these commands to delete the snapshots created by this process:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
# You probably need to do this part twice:
SNAP_ID=put_snapshot_id_here
vzctl snapshot-delete $CTID --id $SNAP_ID
```

## SolusVM
For those using SolusVM, run these on your master to update the OS name. Be sure to replace HOSTNAME with the actual hostname of the container.
```
bash /root/solusvmdb.sh
update vservers set templatename="almalinux-8-x86_64-ez" where hostname="HOSTNAME";
```

## WHMCS
For those using WHMCS, you will want to adjust the OS template configurable option there as well.

## Logging

Logs from almaconvert8 will be stored in /root/almaconvert8-$CTID.log

# Reverting to snapshot
In the event of failure, there are two snapshots you can revert to:

1. The first is taken before any changes are made at all, and
2. The second is taken by the almaconvert8 utility *after* conflicting packages are removed, but before the actual conversion occurs.

To revert to the first/earliest snapshot, simply run:
`./centos2alma_openvz.sh $CTID --revert`

To revert to the second one, run this to get their IDs:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
```

Run this to save the ID of the snapshot you want to restore to:
`SNAP_ID=put_snapshot_id_here`

Then switch to that snapshot and start the container:
```
vzctl snapshot-switch $CTID --id $SNAP_ID
vzctl start $CTID
```

Once you have confirmed the container is back to the original state, delete the snapshot:
`vzctl snapshot-delete $CTID --id $SNAP_ID`

# Troubleshooting

In the event Plesk still isn't working right after this script is complete, it's possbile running the official conversion utility's --finish option will help. I suspect doing so just duplicates the efforts of this script, but it's possible it has a couple extra tidbits in it to help. Here's how to do that:

```
mkdir /usr/local/psa/etc/awstats/
wget https://github.com/plesk/centos2alma/releases/download/v1.2.4/centos2alma-1.2.4.zip
unzip centos2alma-1.2.4.zip
chmod 755 centos2alma
./centos2alma --finish
```

Note: if Germany is blocked in firewall, the almalinux GPG key will fail to download.

# References

- almaconvert8: https://docs.virtuozzo.com/virtuozzo_hybrid_server_7_users_guide/advanced-tasks/converting-containers-with-almaconvert8.html
- Plesk Forum thread: https://talk.plesk.com/threads/upgrade-virtuozzo-container-from-centos-7.369729/