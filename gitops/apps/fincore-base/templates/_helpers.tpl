{{- /* NetworkPolicy peers: pods on kind, CIDRs on AWS (see networkpolicies.yaml). */ -}}
{{- define "fincore-base.peer" -}}
{{- /* dict: namespace, podLabels, cidrs */ -}}
{{- if .cidrs }}
{{- range .cidrs }}
- ipBlock:
    cidr: {{ . }}
{{- end }}
{{- else }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
  podSelector:
    matchLabels:
      {{- toYaml .podLabels | nindent 6 }}
{{- end }}
{{- end }}
{{- define "fincore-base.port" -}}
{{- /* dict: cidrs, port, cidrPort */ -}}
- protocol: TCP
  port: {{ if .cidrs }}{{ .cidrPort | default .port }}{{ else }}{{ .port }}{{ end }}
{{- end }}
