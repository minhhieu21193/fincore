{{- define "svc.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "svc.name" . }}
app.kubernetes.io/part-of: fincore
{{- end -}}

{{- define "svc.labels" -}}
{{ include "svc.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end -}}

{{- define "svc.image" -}}
{{- if not .Values.image.repository -}}{{- fail "image.repository is required" -}}{{- end -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{- if not .Values.image.tag -}}{{- fail "image.tag or image.digest is required" -}}{{- end -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}

{{/* The pod template shared by the Deployment and the Rollout. */}}
{{- define "svc.podTemplate" -}}
metadata:
  labels:
    {{- include "svc.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/version: {{ .Values.image.tag | quote }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with include "svc.podAnnotations" . | fromYaml }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  serviceAccountName: {{ include "svc.name" . }}
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: {{ .Values.topologySpread.zoneWhenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "svc.selectorLabels" . | nindent 10 }}
      matchLabelKeys:
        - {{ if .Values.rollout.enabled }}rollouts-pod-template-hash{{ else }}pod-template-hash{{ end }}
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: {{ .Values.topologySpread.hostWhenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "svc.selectorLabels" . | nindent 10 }}
      matchLabelKeys:
        - {{ if .Values.rollout.enabled }}rollouts-pod-template-hash{{ else }}pod-template-hash{{ end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: app
      image: {{ include "svc.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      ports:
        - name: http
          containerPort: {{ .Values.ports.http }}
          protocol: TCP
        - name: metrics
          containerPort: {{ .Values.ports.metrics }}
          protocol: TCP
      env:
        - name: HTTP_ADDR
          value: ":{{ .Values.ports.http }}"
        - name: METRICS_ADDR
          value: ":{{ .Values.ports.metrics }}"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "k8s.pod.name=$(POD_NAME),k8s.namespace.name={{ .Release.Namespace }}"
        {{- with .Values.tracing.endpoint }}
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: {{ . | quote }}
        - name: OTEL_TRACES_SAMPLER
          value: parentbased_traceidratio
        - name: OTEL_TRACES_SAMPLER_ARG
          value: {{ $.Values.tracing.sampleRatio | quote }}
        {{- end }}
        {{- range $name, $value := .Values.env }}
        - name: {{ $name }}
          value: {{ $value | toString | quote }}
        {{- end }}
        {{- if .Values.vault.enabled }}
        - name: DB_CREDENTIALS_FILE
          value: /vault/secrets/db.json
        {{- end }}
        {{- range $name, $ref := .Values.secretEnv }}
        - name: {{ $name }}
          valueFrom:
            secretKeyRef:
              name: {{ $ref.secret }}
              key: {{ $ref.key }}
        {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      startupProbe:
        {{- toYaml .Values.probes.startup | nindent 8 }}
      livenessProbe:
        {{- toYaml .Values.probes.liveness | nindent 8 }}
      readinessProbe:
        {{- toYaml .Values.probes.readiness | nindent 8 }}
      lifecycle:
        preStop:
          sleep:
            seconds: {{ .Values.preStopSleepSeconds }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
  {{- if .Values.vault.enabled }}
  volumes:
    # Token for Vault's Kubernetes auth only (audience "vault"): the Kubernetes
    # API rejects it, and the pod has no API token at all.
    - name: vault-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: vault
              expirationSeconds: 3600
  {{- end }}
{{- end -}}

{{/* Pod annotations, plus the Vault Agent injector's when vault.enabled. */}}
{{- define "svc.podAnnotations" -}}
{{- $a := deepCopy (.Values.podAnnotations | default dict) -}}
{{- if .Values.vault.enabled -}}
{{- $v := .Values.vault -}}
{{- if not (and $v.role $v.databaseCredentialsPath) }}{{ fail "vault.role and vault.databaseCredentialsPath are required" }}{{ end -}}
{{- $tpl := printf "{{- with secret %q -}}{\"username\":{{ .Data.username | toJSON }},\"password\":{{ .Data.password | toJSON }}}{{- end }}" $v.databaseCredentialsPath -}}
{{- $_ := set $a "vault.hashicorp.com/agent-inject" "true" -}}
{{- $_ := set $a "vault.hashicorp.com/role" $v.role -}}
{{- $_ := set $a "vault.hashicorp.com/agent-inject-secret-db.json" $v.databaseCredentialsPath -}}
{{- $_ := set $a "vault.hashicorp.com/agent-inject-template-db.json" $tpl -}}
{{- $_ := set $a "vault.hashicorp.com/agent-service-account-token-volume-name" "vault-token" -}}
{{- $_ := set $a "vault.hashicorp.com/tls-secret" $v.caSecret -}}
{{- $_ := set $a "vault.hashicorp.com/ca-cert" "/vault/tls/ca.crt" -}}
{{- end -}}
{{- toYaml $a -}}
{{- end -}}
