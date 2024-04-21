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

If you use SolusVM, run these on your master to update the OS name. Be sure to replace HOSTNAME with the actual hostname of the container.
```
bash /root/solusvmdb.sh
update vservers set templatename="almalinux-8-x86_64-ez" where hostname="HOSTNAME";
```

# Troubleshooting
In the event of failure, there are two snapshots you can revert to:

1. The first is taken before any changes are made at all, and
2. The second is taken by the almaconvert8 utility *after* conflicting packages are removed, but before the actual conversion occurs.

To revert to one of these snapshots, run this to get their IDs:
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