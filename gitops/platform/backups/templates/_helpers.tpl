{{/*
Upload container: puts /backup/<file> to s3://<bucket>/<prefix>/<started>.<ext>, where
/backup/started is the UTC time the backup began (written by the backup container):
the key says how old the data is, which is what an RPO measures.
Arguments: dict "root" $ "file" "vault.snap" "prefix" "vault" "ext" "snap"
*/}}
{{- define "backups.uploader" -}}
{{- $v := .root.Values -}}
- name: upload
  {{- if eq $v.uploader "aws-cli" }}
  image: {{ $v.images.awsCli }}
  command: ["/bin/sh", "-ec"]
  args:
    - aws s3 cp --only-show-errors "/backup/{{ .file }}" "s3://{{ $v.bucket }}/{{ .prefix }}/$(cat /backup/started).{{ .ext }}"
  env:
    - { name: HOME, value: /tmp }
    - { name: AWS_REGION, value: {{ $v.region | quote }} }
  {{- else }}
  image: {{ $v.images.curl }}
  command: ["/bin/sh", "-ec"]
  args:
    - >-
      key="{{ .prefix }}/$(cat /backup/started).{{ .ext }}";
      curl -sSf --aws-sigv4 "aws:amz:{{ $v.region }}:s3" --user "$ACCESS_KEY:$SECRET_KEY"
      -T "/backup/{{ .file }}" "{{ $v.endpoint }}/{{ $v.bucket }}/$key";
      echo "uploaded $key ($(wc -c < /backup/{{ .file }}) bytes)"
  env:
    - name: ACCESS_KEY
      valueFrom: { secretKeyRef: { name: backup-s3, key: access_key } }
    - name: SECRET_KEY
      valueFrom: { secretKeyRef: { name: backup-s3, key: secret_key } }
  {{- end }}
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits: { memory: 128Mi }
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: { drop: [ALL] }
  volumeMounts:
    - { name: backup, mountPath: /backup, readOnly: true }
    - { name: tmp, mountPath: /tmp }
{{- end }}

{{- define "backups.podSecurity" -}}
runAsNonRoot: true
runAsUser: 100
runAsGroup: 1000
seccompProfile: { type: RuntimeDefault }
{{- end }}
