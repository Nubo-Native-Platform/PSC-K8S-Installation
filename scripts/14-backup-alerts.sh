#!/usr/bin/env bash
# 14 — Backup monitoring: scrape Velero metrics and alert (via Prometheus) when
# backups stop succeeding — so an outage doesn't silently leave you unprotected.
# Requires Prometheus (kube-prometheus-stack) already installed. Run from a master.
#
#   sudo ./scripts/14-backup-alerts.sh
#
# Config via env vars:
#   PROM_RELEASE_LABEL   default "prometheus" (must match the Prometheus
#                        ruleSelector/serviceMonitorSelector release label)
#   BACKUP_STALE_SECONDS default 129600 (36h)
set -euo pipefail
REL="${PROM_RELEASE_LABEL:-prometheus}"
STALE="${BACKUP_STALE_SECONDS:-129600}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
g='\033[0;32m'; y='\033[0;33m'; r='\033[0;31m'; n='\033[0m'
log(){ echo -e "${g}[+]${n} $*"; }; warn(){ echo -e "${y}[!]${n} $*"; }; die(){ echo -e "${r}[x]${n} $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found — run this on a master"
kubectl get ns velero >/dev/null 2>&1 || warn "velero namespace not found — Velero alerts won't have data"

log "creating Velero metrics Service + ServiceMonitor"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: velero-metrics
  namespace: velero
  labels: { app: velero-metrics }
spec:
  selector: { deploy: velero }
  ports: [{ name: metrics, port: 8085, targetPort: 8085 }]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: velero
  labels: { release: ${REL} }
spec:
  namespaceSelector: { matchNames: [velero] }
  selector: { matchLabels: { app: velero-metrics } }
  endpoints: [{ port: metrics, interval: 30s }]
EOF

log "creating PrometheusRule (backup alerts)"
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: backup-alerts
  namespace: monitoring
  labels: { release: ${REL} }
spec:
  groups:
    - name: backups
      rules:
        - alert: VeleroNoRecentSuccessfulBackup
          expr: (time() - max(velero_backup_last_successful_timestamp{schedule="daily-all"})) > ${STALE}
          for: 10m
          labels: { severity: critical }
          annotations:
            summary: "Velero has no successful backup in the last {{ \$value | humanizeDuration }}"
            description: "The daily-all Velero schedule has not produced a successful backup recently (cluster/backup outage?)."
        - alert: VeleroBackupFailing
          expr: increase(velero_backup_failure_total[2h]) > 0
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "Velero backups are failing"
        - alert: VeleroBackupMetricsMissing
          expr: absent(velero_backup_last_successful_timestamp)
          for: 1h
          labels: { severity: warning }
          annotations:
            summary: "Velero metrics are not being scraped"
        - alert: NFSBackupCronStale
          expr: (time() - max(kube_cronjob_status_last_successful_time{cronjob="nfs-s3-sync"})) > ${STALE}
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "NFS->S3 sync CronJob has not succeeded recently"
EOF

log "done. Verify:"
echo "  kubectl -n monitoring get prometheusrule backup-alerts servicemonitor -n velero velero"
echo "  # in Prometheus: Status > Rules (group 'backups'), Status > Targets (velero)"
