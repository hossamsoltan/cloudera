#!/usr/bin/env bash
set -euo pipefail

CM_HOST="utility1.my.bigdata.local"
CM_PORT="7180"
CM_USER="admin"
CM_PASS="admin"

curl -i  -u ${CM_USER}:${CM_PASS} -X POST --header 'Content-Type: application/json' --header 'Accept: application/json'  -d '{
  "location": "/opt/cloudera/AutoTLS",
  "customCA": true,
  "interpretAsFilenames": true,

  "cmHostCert": "/tmp/auto-tls/certs/utility1.my.bigdata.local.cer",
  "cmHostKey":  "/tmp/auto-tls/keys/utility1.my.bigdata.local.pem",
  "caCert":     "/tmp/auto-tls/ca-chain.pem",

  "keystorePasswd":    "/tmp/auto-tls/keys/key.pwd",
  "truststorePasswd":  "/tmp/auto-tls/keys/key.pwd",

  "trustedCaCerts": "/tmp/auto-tls/RootCA.cer",

  "hostCerts": [
    { "hostname": "utility1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/utility1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/utility1.my.bigdata.local.pem" },
    { "hostname": "utility2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/utility2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/utility2.my.bigdata.local.pem" },

    { "hostname": "worker1.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker1.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker1.my.bigdata.local.pem" },
    { "hostname": "worker2.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker2.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker2.my.bigdata.local.pem" },
    { "hostname": "worker3.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker3.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker3.my.bigdata.local.pem" },

    { "hostname": "master1.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master1.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master1.my.bigdata.local.pem" },
    { "hostname": "master2.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master2.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master2.my.bigdata.local.pem" },
    { "hostname": "master3.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master3.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master3.my.bigdata.local.pem" },

    { "hostname": "edge1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/edge1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/edge1.my.bigdata.local.pem" },
    { "hostname": "edge2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/edge2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/edge2.my.bigdata.local.pem" },

    { "hostname": "kms1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kms1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kms1.my.bigdata.local.pem" },
    { "hostname": "kms2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kms2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kms2.my.bigdata.local.pem" },

  ],

  "configureAllServices": true,
  "sshPort": 22,
  "userName": "hossam",
  "password": "Admin&P@ssw0rd"
}' "http://${CM_HOST}:${CM_PORT}/api/v45/cm/commands/generateCmca"