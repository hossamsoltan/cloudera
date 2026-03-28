
kinit -kt $(ls -1dt /var/run/cloudera-scm-agent/process/*-hdfs-NAMENODE | head -n1)/hdfs.keytab hdfs/$(hostname -f)@BIGDATA.LOCAL
hdfs fsck /
hdfs fsck / | egrep -v '^\.+$' | grep -v eplica
hdfs fsck /path/to/corrupt/file -locations -blocks -files
hdfs dfsadmin -report
#This will list the corrupt HDFS blocks:
hdfs fsck -list-corruptfileblocks

#This will delete the corrupted HDFS blocks:
#hdfs fsck / -delete