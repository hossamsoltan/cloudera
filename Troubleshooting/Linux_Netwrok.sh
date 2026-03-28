# Check for any services currently listening on port 8443
ss -tulnp | grep 8443

# Capture all incoming and outgoing traffic on port 8443 across all interfaces
sudo tcpdump -i any port 8443

# Capture traffic for a specific IP on port 8443, using numeric output to skip DNS lookups
sudo tcpdump -i any -nn host <source_ip> and port 8443

# Test if port 8443 is reachable on a remote server (Z = scan mode, v = verbose)
nc -zv <remote_ip> 8443

# Trace the path to a destination and discover the MTU (Maximum Transmission Unit)
tracepath -p 8443 <destination_ip>

# Monitor network events in real-time (like a log tail for the network)
nmcli monitor

# View interface statistics to see if packets are being dropped at the OS level
ip -s link

# Connect to a server to inspect its SSL/TLS certificate, chain of trust, and handshake details
openssl s_client -connect <IP>:<PORT>

# Specifically force the connection to use TLS 1.2 (useful for testing older systems or RHEL 9 crypto policies)
openssl s_client -connect <IP>:<PORT> -tls1_2

# Use SNI (Server Name Indication) to specify the hostname during the SSL/TLS handshake, which is important for servers hosting multiple domains
openssl s_client -connect <IP>:<PORT> -servername <source_hostname> -tls1_2
 