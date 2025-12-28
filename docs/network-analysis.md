# 📘 Packetbeat Setup Guide  
Download, install, and configure Packetbeat to ship events to Logstash (or Fluentd Beats input)

---

## 📥 1. Download Packetbeat

### **Windows**
```powershell
Invoke-WebRequest -Uri https://artifacts.elastic.co/downloads/beats/packetbeat/packetbeat-8.15.0-windows-x86_64.zip -OutFile packetbeat.zip
Expand-Archive packetbeat.zip -DestinationPath .
cd packetbeat-8.15.0-windows-x86_64
```

## 2. Basic PacketBeat Configuration

```yaml
output.logstash:
  hosts: ["fluentd.core.localhost:5044"]

  ssl:
    certificate_authorities: ["/etc/packetbeat/certs/ca.pem"]
    certificate: "/etc/packetbeat/certs/client.pem"
    key: "/etc/packetbeat/certs/client.key"

```

## 3. Enable the protocols you want to monitor

```yaml
packetbeat.protocols:
  - type: http
    ports: [80, 8080]

  - type: dns
    ports: [53]

  - type: tls
    ports: [443]
```

## 4. Start Packetbeat

```powershell
.\packetbeat.exe -e
```