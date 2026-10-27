{{/* Pods (and, via autogen, their controllers) in enforced namespaces. */}}
{{- define "policies.matchEnforcedPods" -}}
matchConstraints:
  namespaceSelector:
    matchLabels:
      {{- toYaml .Values.enforcedNamespaceLabel | nindent 6 }}
  resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [pods]
{{- end }}

{{- define "policies.common" -}}
validationActions: [Deny]
failurePolicy: Fail
# Admission only (no background scans; see gitops/platform/kyverno/values.yaml).
evaluation:
  background:
    enabled: false
autogen:
  podControllers:
    controllers: {{ toJson .Values.autogenControllers }}
{{- end }}

{{/* Every container of a pod: regular, init and ephemeral. */}}
{{- define "policies.containersVariable" -}}
- name: containers
  expression: >-
    object.spec.containers +
    object.spec.?initContainers.orValue([]) +
    object.spec.?ephemeralContainers.orValue([])
{{- end }}

{{/* A list of strings as CEL string literals: 'a', 'b' */}}
{{- define "policies.quotedList" -}}
{{- $out := list -}}
{{- range . }}{{ $out = append $out (squote .) }}{{ end -}}
{{- join ", " $out -}}
{{- end }}
