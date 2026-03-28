#https://<IP>:8443/gateway/knoxsso/knoxauth/login.html

# Use curl to test the SSL/TLS connection to the server, with verbose output and skipping certificate verification
curl -vk https://<IP>:8443/gateway/knoxsso/knoxauth/login.html

# Use curl to test the SSL/TLS connection with a specific TLS version (TLS 1.2)
curl -vk --tls-max 1.2 https://<IP>:8443/gateway/knoxsso/knoxauth/login.html

# Use curl to test the SSL/TLS connection with a specific certificate authority (CA) certificate
curl -v --cacert /path/to/certificate.crt https://<IP>:8443/gateway/knoxsso/knoxauth/login.html

# Use curl to test the SSL/TLS connection with a specific certificate authority (CA) certificate and TLS version
curl -vk --tls-max 1.2 https://<hostname>:8443 --resolve <hostname>:8443:<IP>

# Use curl to test the SSL/TLS connection with a specific certificate authority (CA) certificate, without specifying TLS version
curl -v --cacert /path/to/certificate.crt --tls-max 1.2 https://<hostname>:8443 --resolve <hostname>:8443:<IP>

# Use curl to test the SSL/TLS connection with a specific certificate authority (CA) certificate, without specifying TLS version
curl -v --cacert /path/to/certificate.crt  https://<hostname>:8443 --resolve <hostname>:8443:<IP>