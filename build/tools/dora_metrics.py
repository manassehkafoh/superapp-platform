#!/usr/bin/env python3
"""
DORA Metrics Push Script
Calculates and pushes deployment frequency and lead time to Prometheus Pushgateway.
Called from GitHub Actions ci-cd.yml after successful production deploy.
"""
import subprocess, time, urllib.request, json, os, sys

def get_deployments_today():
    try:
        output = subprocess.check_output(
            ["git", "log", "--since=midnight", "--oneline", "origin/main"],
            text=True, stderr=subprocess.DEVNULL)
        lines = [l for l in output.strip().split('\n') if l]
        return max(len(lines), 1)
    except Exception:
        return 1

def get_lead_time_seconds():
    try:
        first = subprocess.check_output(
            ["git", "log", "--reverse", "--format=%ct", "origin/main"],
            text=True, stderr=subprocess.DEVNULL
        ).split('\n')[0].strip()
        return int(time.time()) - int(first) if first else 0
    except Exception:
        return 0

def main():
    env        = os.environ.get('ENVIRONMENT', 'prod')
    sha        = os.environ.get('GITHUB_SHA', 'unknown')[:8]
    service    = os.environ.get('SERVICE', 'all')
    gw_url     = os.environ.get('PROMETHEUS_PUSHGATEWAY_URL', 'http://localhost:9091')

    today      = get_deployments_today()
    lead_time  = get_lead_time_seconds()

    metrics = f"""# HELP superapp_deployments_today Deployment frequency (DORA metric)
# TYPE superapp_deployments_today gauge
superapp_deployments_today{{env="{env}",service="{service}"}} {today}
# HELP superapp_lead_time_seconds Lead time for changes in seconds (DORA metric)
# TYPE superapp_lead_time_seconds gauge
superapp_lead_time_seconds{{env="{env}"}} {lead_time}
# HELP superapp_deploy_success_total Deployment success counter
# TYPE superapp_deploy_success_total counter
superapp_deploy_success_total{{env="{env}",sha="{sha}"}} 1
"""
    print(metrics)
    try:
        req = urllib.request.Request(
            f"{gw_url}/metrics/job/github-actions/env/{env}",
            data=metrics.encode(), method='POST')
        req.add_header('Content-Type', 'text/plain')
        urllib.request.urlopen(req, timeout=5)
        print("DORA metrics pushed successfully")
    except Exception as e:
        print(f"Warning: could not push to Pushgateway: {e}", file=sys.stderr)
        sys.exit(0)  # Non-fatal

if __name__ == '__main__':
    main()
