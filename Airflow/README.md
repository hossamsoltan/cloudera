# **Apache Airflow 3.1.3 Production Deployment (RHEL 9.4 + Python 3.11 + PostgreSQL + Systemd)**

This document provides a fully detailed, step-by-step guide to deploy **Apache Airflow 3.1.3** in **production mode** on:

* **OS:** Red Hat Enterprise Linux 9.4
* **Python:** 3.11
* **PostgreSQL Metadata DB:** `utility1.my.bigdata.local`
* **Airflow Server:** `airflow.my.bigdata.local`
* **Executor:** CeleryExcuter
* **DAG-Processor:** Standalone
* **Triggerer:** Enabled
* **Systemd Services:** Enabled
* **Cloudera Integration (TLS + Kerberos):** 

--- 




# **Prerequisites**


## Airflow®3.1.3 is tested with:

* **Python:** 3.9, 3.10, 3.11, 3.12

* **Databases:**

      PostgreSQL:* 13, 14, 15, 16, 17
      MySQL: 8.0, Innovation
      SQLite: 3.15.0+

* **Kubernetes:** 1.30, 1.31, 1.32, 1.33


## Airflow®3.0.3 is tested with:

* **Python:** 3.10, 3.11, 3.12, 3.13

* **Databases:**

      PostgreSQL: 12, 13, 14, 15, 16
      MySQL: 8.0, Innovation
      SQLite: 3.15.0+

* **Kubernetes:** 1.26, 1.27, 1.28, 1.29, 1.30

---



# **1. Prepare PostgreSQL Metadata Database (utility1.my.bigdata.local)**

Login as postgres:

```bash
sudo -i -u postgres
psql
```

Create Airflow DB + user:

```sql
CREATE USER airflow WITH PASSWORD 'airflow';
CREATE DATABASE airflow OWNER airflow;
ALTER USER airflow CREATEDB;   -- optional (not required in strict prod)
\l
\du
\q
```

> Use a **strong password** in production.
> Allowing `CREATEDB` is optional; recommended to disable later.

Ensure PostgreSQL allows Airflow host (edit `pg_hba.conf`):

```
host    airflow    airflow   airflow.my.bigdata.local/32   md5
```

---

# **2. Create Airflow User & Directory (airflow.my.bigdata.local)**

```bash
sudo mkdir -p /opt/airflow
sudo useradd -r -m -d /opt/airflow airflow
sudo chown -R airflow:airflow /opt/airflow
sudo chmod 755 /opt/airflow
```

Switch to airflow user:

```bash
sudo su - airflow
```

---

# **3. Install OS Dependencies (RHEL 9.4)**

```bash
sudo dnf install -y \
  gcc gcc-c++ make \
  python3-devel \
  krb5-devel krb5-libs krb5-workstation \
  openssl openssl-devel \
  openldap-devel openldap-clients \
  systemd-devel \
  libffi-devel \
 
```

These enable:

* Kerberos authentication
* TLS encryption
* DB drivers
* Python cryptography compilation
* C extensions used by Airflow

---

# **4. Install Python 3.11**
By Default python 3.9 is installed on Redhat 9.4 but regarding airflow 3 it support python 3.10+


```bash
sudo dnf install -y python3.11 python3.11-devel python3.11-pip
sudo alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
sudo alternatives --config python3
```

Verify:

```bash
python3 --version
# Python 3.11.x
```

---

# **5. Configure Airflow Environment Variables**

Edit `~/.bashrc`:

```bash
echo 'export AIRFLOW_HOME="/opt/airflow"' >> ~/.bashrc
echo 'export AIRFLOW_VERSION="3.1.3"' >> ~/.bashrc
echo 'export PYTHON_VERSION="3.11"' >> ~/.bashrc
echo 'export PATH="$AIRFLOW_HOME/airflow_venv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

# **6. Create Python Virtual Environment**

```bash
cd /opt/airflow
python3 -m venv airflow_venv
source airflow_venv/bin/activate

pip install --upgrade pip setuptools wheel
```

---

# **7. Install Apache Airflow 3.1.3 with Constraints**

Airflow constraints ensure a stable, reproducible installation.

```bash
export CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
```

Install:

```bash
pip install \
  "apache-airflow[jdbc,crypto,mssql,oracle,postgres,kerberos,ldap,redis,password,rabbitmq,ssh,hdfs,spark,celery]==${AIRFLOW_VERSION}" \
  --constraint "$CONSTRAINT_URL"
```

---

# **8. Generate Default airflow.cfg**

```bash
mkdir -p $AIRFLOW_HOME/{dags,logs,plugins,config}
airflow config list --defaults > $AIRFLOW_HOME/airflow.cfg
```

---

# **9. Configure PostgreSQL Connection**

Edit:

```bash
vim $AIRFLOW_HOME/airflow.cfg
```

Update:

```ini
[database]
sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@utility1.my.bigdata.local/airflow
# sql_alchemy_conn = postgresql+psycopg2://<user>:<password>@<host>/<db>

```

If password contains special characters:

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote('YourPassword!@#'))"
```

Use the encoded string in the URL.

Install driver:

```bash
pip install psycopg2-binary
```

Test DB:

```bash
python3 << 'EOF'
import psycopg2
try:
    conn = psycopg2.connect(
        host="utility1.my.bigdata.local",
        database="airflow",
        user="airflow",
        password="airflow"
    )
    print("Connection successful!")
except Exception as e:
    print(e)
EOF
```

---

# **10. Initialize / Migrate Metadata Database**

```bash
airflow db migrate
```

---

# **11. Airflow Component Architecture (Airflow 3)**

Airflow 3 runs 4 separate processes:

| Component         | Purpose                                        |
| ----------------- | ---------------------------------------------- |
| **api-server**    | Serves UI + REST API (FastAPI)                 |
| **scheduler**     | Decides when tasks run                         |
| **dag-processor** | Parses DAG files & serializes them to DB       |
| **triggerer**     | Runs deferrable operators (async sensors etc.) |

---

# **12. Modify Airflow 3  Settings in airflow.cfg if needed**



---

# **13. Run airflow services Manaully in background**

```bash
# API server (replaces legacy webserver role in 3.x)
airflow api-server \
  -D \
  --stdout /opt/airflow/logs/airflow_webserver.out \
  --stderr /opt/airflow/logs/airflow_webserver.err \
  -l /opt/airflow/logs/airflow_webserver.log

```

```bash
airflow scheduler \
  -D \
  --stdout /opt/airflow/logs/airflow_scheduler.out \
  --stderr /opt/airflow/logs/airflow_scheduler.err \
  -l /opt/airflow/logs/airflow_scheduler.log

```

```bash
airflow triggerer \
  -D \
  --stdout /opt/airflow/logs/airflow_triggerer.out \
  --stderr /opt/airflow/logs/airflow_triggerer.err \
  -l /opt/airflow/logs/airflow_triggerer.log
```

Airflow 3.x has a known bug:
`airflow dag-processor -D` crashes with:

```
OSError: [Errno 22] Invalid argument
```

Solution: run WITHOUT `-D`:

```bash
nohup airflow dag-processor \
  -l /opt/airflow/logs/airflow_dag_processor.log \
  > /opt/airflow/logs/airflow_dag_processor.nohup 2>&1 &
```



---

# **15. Create Production Systemd Services**

This replaces nohup / manual runs in step 13, you can kill running airflow processes and use systemd

## **15.1 API Server Service**

`/etc/systemd/system/airflow-api-server.service`

```ini
[Unit]
Description=Apache Airflow API Server
After=network.target

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
WorkingDirectory=/opt/airflow
ExecStart=/opt/airflow/airflow_venv/bin/airflow api-server \
    -l /opt/airflow/logs/airflow_api_server.log
Restart=always

[Install]
WantedBy=multi-user.target
```

## **15.2 Scheduler**

`/etc/systemd/system/airflow-scheduler.service`

```ini
[Unit]
Description=Apache Airflow Scheduler
After=network.target

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
WorkingDirectory=/opt/airflow
ExecStart=/opt/airflow/airflow_venv/bin/airflow scheduler \
    -l /opt/airflow/logs/airflow_scheduler.log
Restart=always

[Install]
WantedBy=multi-user.target
```

## **15.3 DAG Processor**

`/etc/systemd/system/airflow-dag-processor.service`

```ini
[Unit]
Description=Apache Airflow DAG Processor
After=network.target

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
WorkingDirectory=/opt/airflow
ExecStart=/opt/airflow/airflow_venv/bin/airflow dag-processor \
    -l /opt/airflow/logs/airflow_dag_processor.log
Restart=always

[Install]
WantedBy=multi-user.target
```

## **15.4 Triggerer**

`/etc/systemd/system/airflow-triggerer.service`

```ini
[Unit]
Description=Apache Airflow Triggerer
After=network.target

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
WorkingDirectory=/opt/airflow
ExecStart=/opt/airflow/airflow_venv/bin/airflow triggerer \
    -l /opt/airflow/logs/airflow_triggerer.log
Restart=always

[Install]
WantedBy=multi-user.target
```

---

# **16. Enable & Start All Services**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now airflow-api-server
sudo systemctl enable --now airflow-scheduler
sudo systemctl enable --now airflow-dag-processor
sudo systemctl enable --now airflow-triggerer
```

Check:

```bash
systemctl status airflow-*
```

Logs:

```bash
journalctl -u airflow-api-server -f
journalctl -u airflow-dag-processor -f
```

---

# **17. Verify Airflow Health**

Open:

```
http://airflow.my.bigdata.local:8080
```

All health check pills should be **Green**:

* API Server
* Scheduler
* Triggerer
* DAG Processor

Or check via API:

```bash
curl http://airflow.my.bigdata.local:8080/api/v2/monitor/health
```

---

# **Deployment Now Complete ✔**

You now have a **full production Airflow 3.1.3 cluster**:

* Stable
* Managed by systemd
* PostgreSQL backend
* Proper DAG parser
* Triggerer working
* Fully compatible with **Cloudera TLS + Kerberos** (next step)

---

