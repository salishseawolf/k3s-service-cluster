{{/*
Common labels
*/}}
{{- define "common.labels" -}}
{{- $labels := dict "app.kubernetes.io/name" "step-ca" }}
{{- $labels = merge $labels .Values.common.labels }}
{{- toYaml $labels }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "common.annotations" -}}
{{- toYaml .Values.common.annotations }}
{{- end }}
