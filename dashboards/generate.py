"""Generates the FinCore Grafana dashboards (dashboards/json/*.json).

    python3 dashboards/generate.py dashboards/json

The JSON is committed; scripts/check.sh fails when it is out of date.
"""
import json, sys, os
OUT = sys.argv[1]
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

class D:
    def __init__(s, uid, title, desc, tags, variables=()):
        s.d = {"uid": uid, "title": title, "description": desc, "tags": ["fincore"] + tags,
               "editable": False, "schemaVersion": 39, "version": 1, "refresh": "10s",
               "time": {"from": "now-30m", "to": "now"}, "timezone": "utc",
               "templating": {"list": list(variables)}, "panels": [], "graphTooltip": 1}
        s.y = 0; s.x = 0; s.rowh = 0; s.id = 1
    def row(s, title):
        s.newline()
        s.d["panels"].append({"type": "row", "title": title, "id": s.id, "collapsed": False,
                              "gridPos": {"x": 0, "y": s.y, "w": 24, "h": 1}, "panels": []})
        s.id += 1; s.y += 1
    def newline(s):
        if s.x: s.y += s.rowh; s.x = 0; s.rowh = 0
    def add(s, p, w, h):
        if s.x + w > 24: s.newline()
        p["id"] = s.id; s.id += 1
        p["gridPos"] = {"x": s.x, "y": s.y, "w": w, "h": h}
        s.x += w; s.rowh = max(s.rowh, h)
        s.d["panels"].append(p)
    def stat(s, title, expr, unit="short", w=6, h=4, thresholds=None, desc="", decimals=None, mappings=None):
        steps = thresholds or [{"color": "blue", "value": None}]
        p = {"type": "stat", "title": title, "description": desc, "datasource": PROM,
             "targets": [{"refId": "A", "expr": expr, "datasource": PROM, "instant": True}],
             "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                         "colorMode": "background", "graphMode": "none", "textMode": "value"},
             "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}},
                             "overrides": []}}
        if decimals is not None: p["fieldConfig"]["defaults"]["decimals"] = decimals
        if mappings: p["fieldConfig"]["defaults"]["mappings"] = mappings
        s.add(p, w, h)
    def ts(s, title, targets, unit="short", w=12, h=8, desc="", stack=False, minv=None, maxv=None, lines=None):
        p = {"type": "timeseries", "title": title, "description": desc, "datasource": PROM,
             "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": PROM}
                         for i, (e, l) in enumerate(targets)],
             "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                         "tooltip": {"mode": "multi", "sort": "desc"}},
             "fieldConfig": {"defaults": {"unit": unit, "custom": {
                 "lineWidth": 1, "fillOpacity": 15 if stack else 5,
                 "stacking": {"mode": "normal" if stack else "none"}, "showPoints": "never"}},
                 "overrides": []}}
        if minv is not None: p["fieldConfig"]["defaults"]["min"] = minv
        if maxv is not None: p["fieldConfig"]["defaults"]["max"] = maxv
        if lines:  # dashed threshold lines, e.g. the burn rates that page
            p["fieldConfig"]["defaults"]["custom"]["thresholdsStyle"] = {"mode": "dashed"}
            p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps":
                [{"color": "transparent", "value": None}] + [{"color": c, "value": v} for v, c in lines]}
        s.add(p, w, h)
    def logs(s, title, expr, w=24, h=10, desc=""):
        s.add({"type": "logs", "title": title, "description": desc, "datasource": LOKI,
               "targets": [{"refId": "A", "expr": expr, "datasource": LOKI}],
               "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                           "enableLogDetails": True, "prettifyLogMessage": False}}, w, h)
    def write(s, name):
        s.newline()
        with open(os.path.join(OUT, name), "w") as f:
            json.dump(s.d, f, indent=1, sort_keys=False); f.write("\n")

GREEN0_RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
PAY = 'route="POST /v1/payments"'

# ------------------------------------------------------------------ business
b = D("fincore-business", "FinCore / Business",
      "Payments as the business sees them: volume, outcomes, money moved, and the ledger's invariant.",
      ["business"])
b.row("Now")
b.stat("Payments per second", 'sum(rate(payments_total[2m]))', "reqps", decimals=1)
b.stat("Capture rate (5m)", 'sum(rate(payments_total{status="captured"}[5m])) / sum(rate(payments_total[5m]))',
       "percentunit", decimals=1, desc="Captured / all payments. Declines are a business outcome, not an error.",
       thresholds=[{"color": "orange", "value": None}, {"color": "green", "value": 0.8}])
b.stat("Captured volume (USD/min)", 'sum(rate(payments_amount_minor_units_total{currency="USD"}[2m])) * 60 / 100',
       "currencyUSD", decimals=0)
b.stat("Ledger imbalance", 'max(abs(ledger_imbalance_minor_units)) or vector(0)', "short", thresholds=GREEN0_RED,
       desc="Sum of all debits minus credits, checked live by the ledger. Anything but 0 is a P1.")
b.row("Payments")
b.ts("Payments per second by outcome", [('sum by (status) (rate(payments_total[1m]))', "{{status}}")], "reqps", stack=True)
b.ts("Captured volume (USD per second)", [('sum by (currency) (rate(payments_amount_minor_units_total[1m])) / 100', "{{currency}}")], "currencyUSD")
b.ts("API answers by status code", [(f'sum by (code) (rate(http_requests_total{{app="payments-api",{PAY}}}[1m]))', "{{code}}")], "reqps", stack=True,
     desc="201 captured, 402 declined, 422 invalid, 5xx errors (count against the availability SLO).")
b.ts("Idempotent replays per second", [('sum(rate(payments_idempotent_replays_total[1m]))', "replays")], "reqps",
     desc="Retries with a known Idempotency-Key, answered from the stored result instead of charging twice.")
b.row("Ledger and events")
b.ts("Ledger transactions posted per second", [('sum(rate(ledger_transactions_posted_total[1m]))', "posted")], "reqps")
b.ts("Ledger imbalance (minor units)", [('max by (currency) (ledger_imbalance_minor_units)', "{{currency}}")], "short",
     desc="Must stay flat at 0.")
b.ts("Outbox backlog and publish errors", [('max(outbox_backlog_events)', "backlog (events)"),
                                          ('sum(rate(outbox_publish_errors_total[1m]))', "publish errors/s")], "short",
     desc="Events written in the payment's transaction and not yet on the queue.")
b.ts("Webhook deliveries by result", [('sum by (result) (rate(webhook_deliveries_total[1m]))', "{{result}}")], "reqps", stack=True,
     desc="retry_later and malformed messages go back to the queue and end in the DLQ after maxReceiveCount.")
b.write("business.json")

# ------------------------------------------------------------------ RED
svc = {"name": "service", "label": "Service", "type": "query", "datasource": PROM,
       "query": {"query": "label_values(http_requests_total, app)", "refId": "service"},
       "definition": "label_values(http_requests_total, app)", "refresh": 2, "current": {"text": "payments-api", "value": "payments-api"},
       "includeAll": False, "multi": False}
SEL = 'app="$service",route!~"GET /(healthz|readyz)"'
r = D("fincore-red", "FinCore / Service RED",
      "Rate, errors and duration per FinCore service and route, health probes excluded.", ["red"], [svc])
r.row("$service")
r.stat("Requests per second", f'sum(rate(http_requests_total{{{SEL}}}[2m]))', "reqps", decimals=1)
r.stat("5xx ratio (5m)", f'(sum(rate(http_requests_total{{{SEL},code=~"5.."}}[5m])) or vector(0)) / sum(rate(http_requests_total{{{SEL}}}[5m]))',
       "percentunit", decimals=2, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.001}, {"color": "red", "value": 0.01}])
r.stat("p99 latency (5m)", f'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{{{SEL}}}[5m])))',
       "s", decimals=3, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.3}, {"color": "red", "value": 1}])
r.stat("Versions running", 'count(count by (version) (fincore_build_info{app="$service"}))', "short",
       desc="2 during a canary.")
r.ts("Rate by route", [(f'sum by (route) (rate(http_requests_total{{{SEL}}}[1m]))', "{{route}}")], "reqps")
r.ts("Errors (5xx) by route", [(f'sum by (route, code) (rate(http_requests_total{{{SEL},code=~"5.."}}[1m]))', "{{route}} {{code}}")], "reqps")
r.ts("Latency p50 / p95 / p99", [
    (f'histogram_quantile({q}, sum by (le) (rate(http_request_duration_seconds_bucket{{{SEL}}}[1m])))', f"p{int(q*100)}")
    for q in (0.5, 0.95, 0.99)], "s")
r.ts("Requests by version (canary split)", [(f'sum by (version) (rate(http_requests_total{{{SEL}}}[1m]))', "{{version}}")], "reqps", stack=True)
r.ts("In-flight requests", [('sum by (pod) (http_requests_in_flight{app="$service"})', "{{pod}}")], "short")
r.ts("Memory per pod", [
    ('sum by (pod) (container_memory_working_set_bytes{namespace=~"fincore.*",pod=~"$service-.*",container!=""})', "{{pod}}")], "bytes")
r.logs("Errors and warnings", '{app="$service"} | json | level=~"ERROR|WARN"', h=9,
       desc="From Loki. Open a line to jump to its trace.")
r.write("red.json")

# ------------------------------------------------------------------ platform
p = D("fincore-platform", "FinCore / Platform",
      "The cluster under FinCore: nodes, namespaces, restarts, Vault, credentials and log shipping.", ["platform"])
p.row("Cluster")
p.stat("Nodes ready", 'sum(kube_node_status_condition{condition="Ready",status="true"})', "short")
p.stat("Pod restarts (1h)", 'sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)', "short", decimals=0,
       thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
p.stat("Vault nodes unsealed", 'sum(vault_core_unsealed) or vector(0)', "short",
       thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
       desc="Reported by the active node; 0 means Vault is down or sealed.")
p.stat("Vault Raft fault tolerance", 'max(vault_autopilot_failure_tolerance) or vector(0)', "short",
       thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
       desc="How many Vault nodes can be lost without losing quorum.")
p.ts("Node memory used", [('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}")], "percentunit", minv=0, maxv=1)
p.ts("Node CPU used", [('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m]))', "{{instance}}")], "percentunit", minv=0, maxv=1)
p.row("Workloads")
p.ts("Memory by namespace", [('sum by (namespace) (container_memory_working_set_bytes{container!=""})', "{{namespace}}")], "bytes", stack=True)
p.ts("CPU by namespace", [('sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[2m]))', "{{namespace}}")], "short", stack=True)
p.ts("Container restarts (15m)", [('sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[15m])) > 0', "{{namespace}}/{{pod}}")], "short")
p.ts("Pods not ready", [('sum by (namespace) (kube_pod_status_ready{condition="false"}) > 0', "{{namespace}}")], "short")
p.row("Security and pipelines")
p.ts("Database credential changes (Vault-issued users)", [('sum by (pod) (increase(fincore_db_credential_changes_total[5m]))', "{{pod}}")], "short",
     desc="Each step is a ledger pod switching to a fresh short-lived PostgreSQL user.")
p.ts("Vault requests per second", [('sum(rate(vault_core_handle_request_count[1m]))', "requests"),
                                   ('sum(rate(vault_core_handle_login_request_count[1m]))', "logins")], "reqps")
p.ts("Log shipping (Fluent Bit)", [('sum(rate(fluentbit_output_proc_records_total[1m]))', "records/s sent"),
                                   ('sum(rate(fluentbit_output_retries_total[1m]))', "retries/s"),
                                   ('sum(rate(fluentbit_output_dropped_records_total[1m]))', "dropped/s")], "short")
p.ts("Alerts firing", [('sum by (alertname, severity) (ALERTS{alertstate="firing"})', "{{alertname}} ({{severity}})")], "short")
p.write("platform.json")

# ------------------------------------------------------------------ SLOs
o = D("fincore-slo", "FinCore / SLOs",
      "Payments SLOs and their burn rates (gitops/platform/slo). Burn rate 1 = the budget lasts exactly 30 days; "
      "14.4 over 1 h and 5 m, or 6 over 6 h and 30 m, pages.", ["slo"])
AV = "fincore:payments_availability:error_ratio_rate"
LT = "fincore:payments_latency:slow_ratio_rate"
o.row("Over the selected time range")
o.stat("Availability (non-5xx)", '1 - (sum(increase(http_requests_total{app="payments-api",route="POST /v1/payments",code=~"5.."}[$__range])) or vector(0)) / sum(increase(http_requests_total{app="payments-api",route="POST /v1/payments"}[$__range]))',
       "percentunit", decimals=3, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 0.999}],
       desc="Objective: 99.9 %.")
o.stat("Under 300 ms", 'sum(increase(http_request_duration_seconds_bucket{app="payments-api",route="POST /v1/payments",le="0.3"}[$__range])) / sum(increase(http_request_duration_seconds_count{app="payments-api",route="POST /v1/payments"}[$__range]))',
       "percentunit", decimals=2, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 0.99}],
       desc="Objective: 99 %.")
o.stat("Availability burn rate (1h)", f'{AV}1h / 0.001', "short", decimals=1,
       thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 6}, {"color": "red", "value": 14.4}])
o.stat("Latency burn rate (1h)", f'{LT}1h / 0.01', "short", decimals=1,
       thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 6}, {"color": "red", "value": 14.4}])
o.row("Burn rates")
o.ts("Availability burn rate", [(f'{AV}{w} / 0.001', w) for w in ("5m", "30m", "1h", "6h")], "short",
     lines=[(6, "orange"), (14.4, "red")], desc="Error ratio divided by the 0.1 % budget. Dashed: page thresholds.")
o.ts("Latency burn rate", [(f'{LT}{w} / 0.01', w) for w in ("5m", "30m", "1h", "6h")], "short",
     lines=[(6, "orange"), (14.4, "red")], desc="Share slower than 300 ms divided by the 1 % budget.")
o.ts("Payments answered, by class", [
    ('sum(rate(http_requests_total{app="payments-api",route="POST /v1/payments",code=~"2.."}[1m]))', "2xx"),
    ('sum(rate(http_requests_total{app="payments-api",route="POST /v1/payments",code=~"4.."}[1m]))', "4xx (declines, invalid)"),
    ('sum(rate(http_requests_total{app="payments-api",route="POST /v1/payments",code=~"5.."}[1m]))', "5xx")], "reqps", stack=True)
o.ts("Instances reachable", [('sum by (job) (up{job=~"fincore-cde/.*"})', "{{job}}")], "short", minv=0,
     desc="A drop to 0 is a total outage the burn rates cannot see; PaymentsAPIUnavailable / LedgerUnavailable page on it.")
o.ts("Alerts firing", [('sum by (alertname, severity) (ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"})', "{{alertname}} ({{severity}})")],
     "short", w=24, h=6)
o.write("slo.json")
