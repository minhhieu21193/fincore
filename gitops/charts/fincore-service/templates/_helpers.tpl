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
  {{- with .Values.podAnnotations }}
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
        {{- range $name, $value := .Values.env }}
        - name: {{ $name }}
          value: {{ $value | toString | quote }}
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
{{- end -}}
