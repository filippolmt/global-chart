# Global Helm Chart

A versatile Helm chart designed for flexible Kubernetes deployments, supporting customizable services, ConfigMaps, volumes, deployments, ingress, hooks, and cronjobs for comprehensive application management.

## Features

- Configurable deployments with support for multiple replicas
- Service configuration with various types (ClusterIP, NodePort, LoadBalancer)
- Ingress support with TLS and custom annotations
- ConfigMaps and Secrets management
- Volume and volume mounts configuration
- Horizontal Pod Autoscaling
- Liveness and Readiness probes
- Resource requests and limits
- Node selector, tolerations, and affinity settings
- Lifecycle hooks (post-install, pre-upgrade, post-upgrade)
- CronJob support
- Custom DNS configuration
- Environment variables from ConfigMaps and Secrets
- Support for extra containers and init containers
- Pod recreation policies

## Prerequisites

- Kubernetes 1.19+
- Helm 3.x

## Installation

```bash
# Add the repository
helm repo add global-chart https://filippolmt.github.io/global-chart
helm repo update

# Install the chart
helm install my-release global-chart/global-chart
```
