# Coordinated Operations & Response Engine (CORE)

The Coordinated Operations & Response Engine (CORE) is a flexible and scalable incident response log ingestion and management platform built on OpenSearch. It provides a centralized logging infrastructure for security operations, incident response, and threat hunting.

## 🏗️ Architecture

CORE consists of the following components:

- **OpenSearch Cluster**: 3-node cluster for scalable log storage and search
- **OpenSearch Dashboards**: Web interface for data visualization and exploration
- **Fluentd**: Log aggregation and processing pipeline
- **Security Layer**: Certificate-based authentication and encrypted communications

## 🚀 Quick Start

### Prerequisites

- Docker and Docker Compose
- At least 4GB RAM available
- Ports 5601 (Dashboards), 9200 (OpenSearch), 5044 (Fluentd) available

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd core
   ```

2. **Configure environment** (optional)
   Edit `docker-compose.env` to customize:
   - Admin passwords
   - Certificate details
   - Component versions

3. **Start the platform**
   ```bash
   # Initialize certificates and security
   docker-compose up setup

   # Start all services
   docker-compose up -d
   ```

4. **Access the interfaces**
   - **OpenSearch Dashboards**: https://localhost:5601
   - **OpenSearch API**: https://localhost:9200
   - **Username**: `admin`
   - **Password**: `admin` (or your configured `GLOBAL_ADMIN_PASS`)

## 📊 Data Ingestion

CORE supports multiple data sources through Fluentd:

### Elastic Beats Integration

Send data from any Elastic Beat:

```yaml
# beats.yml configuration
output.logstash:
  hosts: ["localhost:5044"]
```

**Supported Beats:**
- **Filebeat**: Log file shipping
- **Metricbeat**: System and service metrics
- **Packetbeat**: Network traffic monitoring
- **Heartbeat**: Uptime monitoring
- **Winlogbeat**: Windows event logs
- **Auditbeat**: Audit data

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENSEARCH_VERSION` | `latest` | OpenSearch version |
| `FLUENTD_VERSION` | `latest` | Fluentd version |
| `GLOBAL_ADMIN_PASS` | `admin` | Admin password for all services |
| `OPENSEARCH_HOST` | `os01` | OpenSearch cluster host |
| `CERT_DN` | `OpenSearch-Cluster.localhost` | Certificate domain name |

### Index Patterns

Data is automatically indexed with date-based patterns:
- `fluentd-filebeat`
- `fluentd-metricbeat`
- `fluentd-packetbeat`
- `fluentd-`

## 🔒 Security Features

- **Certificate-based authentication** between components
- **TLS encryption** for all communications
- **Role-based access control** in OpenSearch
- **Secure defaults** with configurable certificates

## 🛠️ Development

### Adding Custom Fluentd Plugins

1. Edit `config/fluentd/Dockerfile`
2. Add plugin installation: `RUN gem install plugin-name`
3. Rebuild: `docker-compose build fluentd`

### Custom OpenSearch Configuration

Modify files in `config/opensearch/config/` and `config/opensearch-dashboards/config/`

### Scaling the Cluster

Add more OpenSearch nodes by copying the `os01` service configuration and updating node names.

## 📈 Monitoring

Monitor cluster health:
```bash
curl -k -u admin:admin https://localhost:9200/_cluster/health
```

View Fluentd metrics:
```bash
docker-compose logs fluentd
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `docker-compose up`
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🆘 Troubleshooting

### Common Issues

**Port conflicts**: Ensure ports 5601, 9200, 5044 are available
**Memory issues**: Increase Docker memory allocation to 4GB+
**Certificate errors**: Run `docker-compose up setup` first

**Logs location**: `docker-compose logs <service-name>`

### Reset Everything

```bash
docker-compose down -v
docker system prune -a
docker-compose up setup
```